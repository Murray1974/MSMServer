import Vapor
import Fluent

struct StudentBookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // student, session-protected or bearer-protected
        let student = routes
            .grouped("student")
            .grouped(
                SessionTokenAuthenticator(),
                BearerTokenAuthenticator(),
                User.guardMiddleware()
            )

        // /student/bookings
        let bookings = student.grouped("bookings")

        // POST /student/bookings
        bookings.post(use: createBooking)

        // GET /student/bookings
        bookings.get(use: myBookings)

        // /student/bookings/:bookingID/*
        let byID = bookings.grouped(":bookingID")

        // DELETE /student/bookings/:bookingID
        byID.delete(use: cancelBooking)

        // POST /student/bookings/:bookingID/cancel
        byID.post("cancel", use: cancelBooking)

        // POST /student/bookings/:bookingID/reschedule
        byID.post("reschedule", use: rescheduleBooking)

        // PATCH /student/bookings/:bookingID/duration  ← NEW ROUTE
        byID.patch("duration", use: updateDuration)

        // PATCH /student/bookings/:bookingID/pickup
        byID.patch("pickup", use: updatePickup)

        // POST /student/bookings/:bookingID/paid
        byID.post("paid", use: markPaid)

        // POST /student/bookings/:bookingID/pay  (mock payment gateway)
        byID.post("pay", use: simulatePay)
    }

    // MARK: INPUT STRUCTS

    struct CreateBookingInput: Content {
        let lessonID: UUID
        let durationMinutes: Int?
        let startOffsetMinutes: Int?
    }

    struct UpdateDurationInput: Content {
        let durationMinutes: Int
        let startOffsetMinutes: Int?
    }

    struct MarkPaidInput: Content {
        var method: String?
    }

    // MARK: CREATE BOOKING

    func createBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        req.logger.info("student.createBooking: userID=\(userID) username=\(user.username) displayName=\(user.displayName) lessonID_param=pending")

        let input = try req.content.decode(CreateBookingInput.self)
        req.logger.info("student.createBooking: requested lessonID=\(input.lessonID.uuidString) offset=\(input.startOffsetMinutes ?? 0) duration=\(input.durationMinutes ?? -1)")
        let offsetMinutes = input.startOffsetMinutes ?? 0

        guard let lesson = try await Lesson.find(input.lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        guard lesson.startsAt > Date() else {
            throw Abort(.unprocessableEntity, reason: "This lesson has already started and can no longer be booked")
        }

        // Prevent duplicates
        let alreadyBooked = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .first()

        if alreadyBooked != nil {
            throw Abort(.conflict, reason: "You have already booked this lesson")
        }

        // Capacity check
        let existingCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .count()

        let cap = lesson.capacity ?? 1
        if existingCount >= cap {
            throw Abort(.conflict, reason: "Lesson is full")
        }

        // Check duration+offset inside slot
        if let mins = input.durationMinutes {
            let slotMinutes = Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60)
            if offsetMinutes < 0 || offsetMinutes + mins > slotMinutes {
                throw Abort(.badRequest, reason: "Requested duration/offset exceeds lesson length (\(slotMinutes)m)")
            }
        }

        // Build the booking
        var actualEndsAt: Date? = nil
        if let mins = input.durationMinutes {
            let effectiveStart = lesson.startsAt.addingTimeInterval(Double(offsetMinutes) * 60)
            actualEndsAt = effectiveStart.addingTimeInterval(Double(mins) * 60)
        }

        // Default pickup from StudentProfile
        var defaultPickupSource: String? = nil
        var defaultPickupLocation: String? = nil

        if let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        {
            let home = profile.pickupHome?.trimmingCharacters(in: .whitespacesAndNewlines)
            let work = profile.pickupWork?.trimmingCharacters(in: .whitespacesAndNewlines)
            let college = profile.pickupCollege?.trimmingCharacters(in: .whitespacesAndNewlines)
            let school = profile.pickupSchool?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let a = home, !a.isEmpty { defaultPickupSource = "home"; defaultPickupLocation = a }
            else if let a = work, !a.isEmpty { defaultPickupSource = "work"; defaultPickupLocation = a }
            else if let a = college, !a.isEmpty { defaultPickupSource = "college"; defaultPickupLocation = a }
            else if let a = school, !a.isEmpty { defaultPickupSource = "school"; defaultPickupLocation = a }
        }

        let booking = Booking(
            userID: userID,
            lessonID: input.lessonID,
            durationMinutes: input.durationMinutes,
            actualEndsAt: actualEndsAt,
            paymentStatus: "pending"
        )
        booking.pickupSource = defaultPickupSource
        booking.pickupLocation = defaultPickupLocation

        try await booking.save(on: req.db)

        lesson.state = "booked"
        lesson.calendarName = "MSM Lessons"
        try await lesson.save(on: req.db)

        let bookedLesson = try await booking.$lesson.get(on: req.db)
        req.logger.info("student.createBooking: broadcasting booked lessonID=\((try? bookedLesson.requireID())?.uuidString ?? input.lessonID.uuidString) userID=\(userID) username=\(user.username) displayName=\(user.displayName)")
        try req.broadcastBooked(for: bookedLesson)

        return .created
    }

    // MARK: CANCEL BOOKING

    func cancelBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing booking ID")
        }

        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        // Idempotent: already cancelled — return success without repeating side-effects.
        if booking.deletedAt != nil {
            return .ok
        }

        let cancelLesson = try await booking.$lesson.get(on: req.db)
        let hoursUntilLesson = cancelLesson.startsAt.timeIntervalSinceNow / 3600
        let isLate = hoursUntilLesson >= 0 && hoursUntilLesson < 48

        if isLate {
            booking.cancellationType = "late_cancellation"
            // Persist cancellationType before soft-delete: Fluent's delete() only writes
            // deleted_at, so we must save() any extra field changes first.
            try await booking.save(on: req.db)

            // Load (or nil) the lesson finance record for this lesson.
            let lessonID = cancelLesson.id
            var lessonFinance: LessonFinance? = nil
            if let lid = lessonID {
                lessonFinance = try await LessonFinance.find(lid, on: req.db)
            }

            // Flag the finance record as fully billable.
            if let finance = lessonFinance {
                finance.fullChargeApplied = true
                try await finance.save(on: req.db)
            }

            // Auto-debit the student's ledger balance so the outstanding fee is immediately
            // visible in the Finance tab without the instructor needing to manually charge.
            let chargeAmount: Decimal
            if let snapshot = lessonFinance?.priceSnapshot {
                chargeAmount = snapshot
            } else {
                // No LessonFinance yet: estimate from lesson duration at default hourly rate.
                let mins = max(0, Int(cancelLesson.endsAt.timeIntervalSince(cancelLesson.startsAt) / 60))
                chargeAmount = (Decimal(45) * Decimal(mins)) / Decimal(60)
            }

            // Resolve the instructor ID: prefer from the existing finance record, then role lookup.
            let instructorIDFromFinance: UUID? = lessonFinance?.$instructor.id
            let instructorID: UUID?
            if let iid = instructorIDFromFinance {
                instructorID = iid
            } else {
                do {
                    instructorID = try await User.query(on: req.db)
                        .filter(\.$role == "instructor")
                        .first()?
                        .requireID()
                } catch {
                    req.logger.error("Failed to resolve instructorID for late cancellation charge: \(error)")
                    instructorID = nil
                }
            }

            if instructorID == nil {
                req.logger.warning("No instructor found — late cancellation LedgerEntry will have nil createdByUserID for studentID=\(userID)")
            }

            if let lid = lessonID, let instructorID {
                let chargeEntry = LedgerEntry(
                    studentID: userID,
                    instructorID: instructorID,
                    lessonID: lid,
                    type: "late_cancellation_charge",
                    amount: -chargeAmount,
                    note: "Late cancellation — full charge applies",
                    effectiveDate: Date(),
                    createdByUserID: instructorID
                )
                try await chargeEntry.save(on: req.db)

                // Best-effort push notification — never fails the cancellation.
                if let fcmToken = user.fcmToken, let fcm = FCMNotificationService(req: req) {
                    try? await fcm.send(
                        to: fcmToken,
                        title: "Lesson Update",
                        body: "A late cancellation fee has been applied to your account per our 48h policy."
                    )
                }
            }
        }

        try await booking.delete(on: req.db)

        let evt = BookingEvent(
            type: isLate ? "student.late_cancelled" : "student.cancelled",
            userID: try user.requireID(),
            lessonID: booking.$lesson.id,
            bookingID: try booking.requireID()
        )
        try await evt.save(on: req.db)

        let freedLesson = try await booking.$lesson.get(on: req.db)
        freedLesson.state = "available"
        freedLesson.calendarName = "MSM Available"
        try await freedLesson.save(on: req.db)

        // Release the reserved credit so it can cover other lessons.
        let studentID = try user.requireID()
        do {
            try await FinanceController().reevaluateCoverageForStudent(studentID, on: req.db)
        } catch {
            req.logger.error("reevaluateCoverage failed: \(error)")
        }

        try req.broadcastCancelled(for: freedLesson)
        req.application.broadcastRecoveryCandidate(for: freedLesson)
        return .ok
    }

    // MARK: RESCHEDULE

    struct RescheduleInput: Content {
        let newLessonID: UUID
    }

    func rescheduleBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        let body = try req.content.decode(RescheduleInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        guard let newLesson = try await Lesson.find(body.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson to move to not found")
        }

        guard newLesson.startsAt > Date() else {
            throw Abort(.unprocessableEntity, reason: "Cannot reschedule to a lesson that has already started")
        }

        let oldLesson = try await booking.$lesson.get(on: req.db)

        let hoursUntilOldLesson = oldLesson.startsAt.timeIntervalSinceNow / 3600
        if hoursUntilOldLesson < 48 {
            throw Abort(.forbidden, reason: "Cancellations must be made at least 48 hours in advance.")
        }

        booking.$lesson.id = try newLesson.requireID()
        booking.rescheduled = true

        if let mins = booking.durationMinutes {
            let newStart = newLesson.startsAt
            booking.actualEndsAt = newStart.addingTimeInterval(Double(mins) * 60)
        } else {
            booking.actualEndsAt = nil
        }

        try await booking.save(on: req.db)
        req.broadcastRescheduled(old: oldLesson, new: newLesson)

        return .ok
    }

    // MARK: UPDATE DURATION (NEW)

    func updateDuration(_ req: Request) async throws -> StudentBookingDTO {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)
        let input = try req.content.decode(UpdateDurationInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .with(\.$lesson)
            .first()
        else { throw Abort(.notFound) }

        guard booking.$user.id == user.id else {
            throw Abort(.forbidden, reason: "This booking does not belong to you")
        }

        guard let lesson = booking.$lesson.value else {
            throw Abort(.internalServerError, reason: "Booking missing lesson")
        }

        let slotMinutes = Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60)

        // Determine effective start
        let effectiveStart: Date
        if let offset = input.startOffsetMinutes {
            effectiveStart = lesson.startsAt.addingTimeInterval(Double(offset) * 60)
        } else if let mins = booking.durationMinutes,
                  let actualEnd = booking.actualEndsAt {
            effectiveStart = actualEnd.addingTimeInterval(Double(-mins) * 60)
        } else {
            effectiveStart = lesson.startsAt
        }

        let newOffsetMinutes = Int(effectiveStart.timeIntervalSince(lesson.startsAt) / 60)

        if newOffsetMinutes < 0 ||
            newOffsetMinutes + input.durationMinutes > slotMinutes
        {
            throw Abort(.badRequest, reason: "Requested duration/offset exceeds lesson slot.")
        }

        let newEndsAt = effectiveStart.addingTimeInterval(Double(input.durationMinutes) * 60)

        booking.durationMinutes = input.durationMinutes
        booking.actualEndsAt = newEndsAt

        try await booking.save(on: req.db)

        return StudentBookingDTO(
            id: booking.id,
            lessonID: booking.$lesson.id,
            lessonTitle: lesson.title,
            startsAt: effectiveStart,
            endsAt: newEndsAt,
            status: "active",
            deletedAt: nil,
            pickupLocation: booking.pickupLocation,
            pickupSource: booking.pickupSource,
            lessonStartsAt: lesson.startsAt,
            lessonEndsAt: lesson.endsAt,
            paymentStatus: booking.paymentStatus,
            fullChargeApplied: nil
        )
    }

    // MARK: MARK BOOKING AS PAID

    func markPaid(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)

        // Decode body if present (we only care about it for future use / logging)
        _ = try? req.content.decode(MarkPaidInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        // Persist the payment flag on the booking.
        booking.paymentStatus = "paid"
        try await booking.save(on: req.db)

        return .ok
    }

    // MARK: SIMULATE PAYMENT

    struct SimulatePayResponse: Content {
        var bookingID: UUID
        var paymentStatus: String
        var transactionID: String
        var message: String
    }

    func simulatePay(_ req: Request) async throws -> SimulatePayResponse {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        guard booking.paymentStatus != "confirmed" else {
            throw Abort(.conflict, reason: "Payment has already been confirmed for this booking")
        }

        let result = try await MockPaymentService.process(bookingID: bookingID)

        booking.paymentStatus = "confirmed"
        try await booking.save(on: req.db)

        return SimulatePayResponse(
            bookingID: bookingID,
            paymentStatus: "confirmed",
            transactionID: result.transactionID,
            message: result.message
        )
    }

    // MARK: GET MY BOOKINGS

    func myBookings(_ req: Request) async throws -> [StudentBookingDTO] {
        struct Query: Decodable {
            var scope: String?
            var limit: Int?
        }

        let q = try req.query.decode(Query.self)
        let user = try req.auth.require(User.self)

        let userID = try user.requireID()
        let now = Date()

        var query = Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$user.$id == userID)
            .with(\.$lesson)

        switch q.scope?.lowercased() {
        case "upcoming":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt >= now)
                .sort(Lesson.self, \.$startsAt, .ascending)

        case "past":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt < now)
                .sort(Lesson.self, \.$startsAt, .descending)

        case "cancelled":
            query = Booking.query(on: req.db)
                .withDeleted()
                .filter(\.$user.$id == userID)
                .filter(\.$deletedAt != nil)
                .with(\.$lesson)
                .sort(\.$deletedAt, .descending)

        default:
            query = query.sort(\.$createdAt, .descending)
        }

        if let limit = q.limit, limit > 0 {
            query = query.limit(limit)
        }

        let results = try await query.all()

        return results.map { booking in
            let lesson = booking.$lesson.value

            let baseEndsAt = booking.actualEndsAt ?? lesson?.endsAt
            let effectiveStart: Date?
            if let mins = booking.durationMinutes, let end = baseEndsAt {
                effectiveStart = end.addingTimeInterval(Double(-mins) * 60)
            } else {
                effectiveStart = lesson?.startsAt
            }

            let derivedStatus: String
            if booking.deletedAt == nil {
                derivedStatus = "active"
            } else if booking.cancellationType == "late_cancellation" {
                derivedStatus = "late_cancelled"
            } else {
                derivedStatus = "cancelled"
            }

            return StudentBookingDTO(
                id: booking.id,
                lessonID: booking.$lesson.id,
                lessonTitle: lesson?.title,
                startsAt: effectiveStart,
                endsAt: baseEndsAt,
                status: derivedStatus,
                deletedAt: booking.deletedAt,
                pickupLocation: booking.pickupLocation,
                pickupSource: booking.pickupSource,
                lessonStartsAt: lesson?.startsAt,
                lessonEndsAt: lesson?.endsAt,
                paymentStatus: booking.paymentStatus,
                fullChargeApplied: booking.cancellationType == "late_cancellation" ? true : nil
            )
        }
    }

    // MARK: DTO

    struct StudentBookingDTO: Content {
        var id: UUID?
        var lessonID: UUID?
        var lessonTitle: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
        var deletedAt: Date?
        var pickupLocation: String?
        var pickupSource: String?
        var lessonStartsAt: Date?
        var lessonEndsAt: Date?
        var paymentStatus: String?
        var fullChargeApplied: Bool?
    }

    // MARK: UPDATE PICKUP

    func updatePickup(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)
        let input = try req.content.decode(UpdatePickupInput.self)

        guard var booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard booking.$user.id == user.id else {
            throw Abort(.forbidden)
        }

        booking.pickupLocation = input.pickupLocation
        booking.pickupSource = input.pickupSource

        try await booking.save(on: req.db)
        return .ok
    }

    struct UpdatePickupInput: Content {
        var pickupLocation: String?
        var pickupSource: String?
    }
}
