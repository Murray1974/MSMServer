import Vapor
import Fluent
import Foundation

struct InstructorLessonController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {

        let instructor = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware()).grouped("instructor")

        // Mirrors /student/lessons/available but for instructors
        instructor.get("lessons", "available", use: availableLessons)

        // Lightweight booking summaries for a given date range (used by instructor calendar overlays)
        instructor.get("bookings", "range", use: bookingsInRange)

        // Mark a lesson as personal/unavailable (moves it off the student-visible calendar)
        instructor.post("lessons", ":lessonID", "personal", use: markLessonPersonal)

        // Restore a lesson back to available (moves it back onto the student-visible calendar)
        instructor.post("lessons", ":lessonID", "available", use: markLessonAvailable)

        // Instructor-side reschedule: moves a booking to a different lesson (no ownership/48h checks)
        instructor.post("bookings", ":bookingID", "reschedule", use: instructorReschedule)

        // Instructor-side swap: exchanges lesson slots between two bookings, notifying both students
        instructor.post("bookings", ":bookingID", "swap", use: instructorSwap)

        // Set or clear an alternate drop-off location on a booking
        instructor.patch("bookings", ":bookingID", "dropoff", use: setDropoffLocation)

        // Instructor creates a booking on behalf of a student (no 48h / capacity guards)
        instructor.post("students", ":studentID", "bookings", use: createBookingForStudent)

        // Instructor cancels any booking without late-cancel charges
        instructor.delete("bookings", ":bookingID", use: instructorCancelBooking)

        // Full lesson history for a student (past + upcoming) with finance status
        // Uses :userID to match TestAppointmentController's param name at this path position
        instructor.get("students", ":userID", "lesson-history", use: studentLessons)
    }

    struct InstructorLessonRow: Content {
        var id: UUID?
        var title: String?
        var startsAt: Date
        var endsAt: Date
        var capacity: Int
        var booked: Int
        var available: Int
        var state: String
    }

    struct BookingRangeRow: Content {
        var id: UUID
        var lessonID: UUID
        var userID: UUID
        var studentName: String
        var studentDisplayName: String?
        var title: String?
        var startsAt: Date
        var endsAt: Date
        var financeStatus: String?
        var status: String?           // "active" | "late_cancelled"
        var cancellationType: String? // "late_cancellation" | nil
        var dropoffLocation: String?
        var rescheduled: Bool?
    }

    func availableLessons(_ req: Request) async throws -> [InstructorLessonRow] {
        struct RangeQuery: Decodable {
            var from: String?
            var to: String?
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)

        let q = (try? req.query.decode(RangeQuery.self)) ?? RangeQuery(from: nil, to: nil)

        let fromDate = q.from.flatMap { iso.date(from: $0) } ?? now
        let toDate = q.to.flatMap { iso.date(from: $0) }
            ?? Calendar.current.date(byAdding: .day, value: 56, to: fromDate)!

        // 1) Available lessons on the MSM Available calendar within the requested window
        let candidates = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .filter(\.$calendarName == "MSM Available")
            .all()

        // 2) For each lesson, count active bookings and only return those
        //    that still have remaining capacity.
        var rows: [InstructorLessonRow] = []

        for lesson in candidates {
            guard let lessonID = lesson.id else { continue }

            let existingCount = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$deletedAt == nil)
                .count()

            let capacity = lesson.capacity
            let remaining = max(0, capacity - existingCount)

            // Skip full lessons
            if remaining <= 0 { continue }

            rows.append(
                InstructorLessonRow(
                    id: lessonID,
                    title: lesson.title,
                    startsAt: lesson.startsAt,
                    endsAt: lesson.endsAt,
                    capacity: capacity,
                    booked: existingCount,
                    available: remaining,
                    state: lesson.state
                )
            )
        }

        // Sort by start time ascending
        rows.sort { $0.startsAt < $1.startsAt }
        return rows
    }

    // MARK: - GET /instructor/bookings/range
    //
    // Returns lightweight booking summaries for lessons within a date range.
    // This is used by the instructor app calendar to overlay booking IDs on top
    // of EventKit events.
    func bookingsInRange(_ req: Request) async throws -> [BookingRangeRow] {
        struct Filter: Decodable {
            var from: String
            var to: String
        }

        let filter = try req.query.decode(Filter.self)
        let iso = ISO8601DateFormatter()

        guard let fromDate = iso.date(from: filter.from),
              let toDate = iso.date(from: filter.to) else {
            throw Abort(.badRequest, reason: "Invalid or missing from/to query parameters")
        }

        // 1) Fetch all lessons in range — one query.
        let lessonsInRange = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .all()

        guard !lessonsInRange.isEmpty else { return [] }

        let lessonIDs = lessonsInRange.compactMap(\.id)
        let lessonByID = Dictionary(uniqueKeysWithValues: lessonsInRange.compactMap { l -> (UUID, Lesson)? in
            guard let id = l.id else { return nil }
            return (id, l)
        })

        // 2) Batch fetch active + late-cancelled bookings for all lessons — one query.
        let allBookings = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$lesson.$id ~~ lessonIDs)
            .group(.or) { g in
                g.filter(\.$deletedAt == nil)
                g.filter(\.$cancellationType == "late_cancellation")
            }
            .all()

        // 3) Batch fetch all referenced students — one query.
        let studentIDs = Array(Set(allBookings.map { $0.$user.id }))
        let students = try await User.query(on: req.db)
            .filter(\.$id ~~ studentIDs)
            .all()
        let studentByID = Dictionary(uniqueKeysWithValues: students.compactMap { u -> (UUID, User)? in
            guard let id = u.id else { return nil }
            return (id, u)
        })

        // 4) Batch fetch lesson finance records — one query. Read-only; no side-effect mutation.
        // LessonFinance uses the lesson UUID as its own @ID, so filter by id directly.
        let finances = try await LessonFinance.query(on: req.db)
            .filter(\.$id ~~ lessonIDs)
            .all()
        let financeByLessonID = Dictionary(uniqueKeysWithValues: finances.compactMap { f -> (UUID, LessonFinance)? in
            guard let lid = f.id else { return nil }
            return (lid, f)
        })

        var rows: [BookingRangeRow] = []
        rows.reserveCapacity(allBookings.count)

        for booking in allBookings {
            guard let bookingID = booking.id,
                  let lesson = lessonByID[booking.$lesson.id],
                  let student = studentByID[booking.$user.id] else { continue }

            let isLate = booking.cancellationType == "late_cancellation"
            let financeStatus = financeByLessonID[booking.$lesson.id]?.financeStatus

            rows.append(
                BookingRangeRow(
                    id: bookingID,
                    lessonID: booking.$lesson.id,
                    userID: booking.$user.id,
                    studentName: student.username,
                    studentDisplayName: student.displayName,
                    title: lesson.title,
                    startsAt: lesson.startsAt,
                    endsAt: lesson.endsAt,
                    financeStatus: financeStatus,
                    status: isLate ? "late_cancelled" : "active",
                    cancellationType: booking.cancellationType,
                    dropoffLocation: booking.dropoffLocation,
                    rescheduled: booking.rescheduled
                )
            )
        }

        // Sort by start time ascending
        rows.sort { $0.startsAt < $1.startsAt }
        return rows
    }

    // MARK: - POST /instructor/lessons/:lessonId/personal
    // Body: { "reason": "...", "title": "Optional title override" }
    func markLessonPersonal(_ req: Request) async throws -> HTTPStatus {
        struct Body: Content {
            var reason: String?
            var title: String?
        }

        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "lessonID missing or invalid")
        }

        let body = (try? req.content.decode(Body.self)) ?? Body(reason: nil, title: nil)

        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Mark as non-student-visible. Save BEFORE cancelling bookings so
        // that any student HTTP refresh triggered by the cancellation broadcast
        // already finds this lesson as "personal" (excluded from available list).
        lesson.calendarName = "Mike personal"
        lesson.state = "personal"

        // Optional: prefix title to keep a visible clue in calendar UI.
        if let r = body.reason, r.isEmpty == false {
            let current = lesson.title
            let prefix = "Personal — \(r)"
            lesson.title = current.isEmpty ? prefix : prefix + " (" + current + ")"
        } else if let t = body.title {
            lesson.title = t
        }

        try await lesson.save(on: req.db)

        // Cancel any active student bookings now that the lesson is personal.
        // The instructor is reclaiming this slot — the student is not at fault,
        // so no late cancellation charge applies regardless of timing.
        let activeBookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .all()

        for booking in activeBookings {
            let sid = booking.$user.id
            let student = try? await User.find(sid, on: req.db)
            booking.cancellationSource = "instructor_personal"
            try await booking.save(on: req.db)
            try await booking.delete(on: req.db)

            let evt = BookingEvent(
                type: "instructor.personal",
                userID: sid,
                lessonID: lessonID,
                bookingID: try? booking.requireID()
            )
            try? await evt.save(on: req.db)

            try req.broadcastCancelled(for: lesson, student: student, studentID: sid)
            req.broadcastBookingCleared(for: lesson, studentID: sid)
        }

        // Remove any lesson_finance record — the instructor is reclaiming the slot,
        // the student owes nothing and the record should not affect their coverage.
        if let finance = try await LessonFinance.find(lessonID, on: req.db),
           finance.chargeStatus != "charged", finance.financeStatus != "charged" {
            try await finance.delete(force: true, on: req.db)
        }

        // Broadcast rich event so agent can move the EKEvent (by stamped MSM_LESSON_ID).
        req.application.broadcastLessonEvent(
            type: "slot.unavailable",
            title: "Slot unavailable",
            message: "Lesson marked personal",
            lessonID: lessonID,
            bookingID: nil,
            status: "unavailable",
            reason: body.reason
        )

        return .ok
    }

    // MARK: - POST /instructor/lessons/:lessonId/available
    // Body: { "title": "Optional title" }
    func markLessonAvailable(_ req: Request) async throws -> HTTPStatus {
        struct Body: Content {
            var title: String?
        }

        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "lessonID missing or invalid")
        }

        let body = (try? req.content.decode(Body.self)) ?? Body(title: nil)

        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Cancel any active bookings before freeing the slot so a subsequent
        // syncWorkBookings call sees no zombie booking and can re-broadcast.
        _ = try await req.cancelActiveBookings(for: lesson)

        // Student-visible calendar
        lesson.calendarName = "MSM Available"
        lesson.state = "available"
        if let t = body.title {
            lesson.title = t
        }

        try await lesson.save(on: req.db)

        req.application.broadcastLessonEvent(
            type: "slot.available",
            title: "Slot available",
            message: "Lesson restored to available",
            lessonID: lessonID,
            bookingID: nil,
            status: "available",
            reason: nil
        )

        return .ok
    }

    // MARK: - POST /instructor/bookings/:bookingID/swap
    //
    // Exchanges the lesson slots of two active bookings. Both students are
    // notified via the existing "booking_changed / rescheduled" WebSocket broadcast.
    // No ownership or 48-hour checks — instructor-only operation.

    func instructorSwap(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        struct SwapInput: Content { let targetBookingID: UUID }
        let body = try req.content.decode(SwapInput.self)

        guard bookingID != body.targetBookingID else {
            throw Abort(.badRequest, reason: "Cannot swap a booking with itself")
        }

        guard let bookingA = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound, reason: "Source booking not found")
        }

        guard let bookingB = try await Booking.query(on: req.db)
            .filter(\.$id == body.targetBookingID)
            .filter(\.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound, reason: "Target booking not found")
        }

        let lessonA  = try await bookingA.$lesson.get(on: req.db)
        let lessonB  = try await bookingB.$lesson.get(on: req.db)
        let studentA = try await bookingA.$user.get(on: req.db)
        let studentB = try await bookingB.$user.get(on: req.db)

        guard lessonA.startsAt > Date(), lessonB.startsAt > Date() else {
            throw Abort(.unprocessableEntity, reason: "Cannot swap a lesson that has already started")
        }

        let lessonAID = try lessonA.requireID()
        let lessonBID = try lessonB.requireID()

        // Swap lesson assignments
        bookingA.$lesson.id = lessonBID
        bookingB.$lesson.id = lessonAID

        // Carry each booking's duration to the new slot's start time
        if let mins = bookingA.durationMinutes {
            bookingA.actualEndsAt = lessonB.startsAt.addingTimeInterval(Double(mins) * 60)
        } else {
            bookingA.actualEndsAt = nil
        }
        if let mins = bookingB.durationMinutes {
            bookingB.actualEndsAt = lessonA.startsAt.addingTimeInterval(Double(mins) * 60)
        } else {
            bookingB.actualEndsAt = nil
        }

        try await bookingA.save(on: req.db)
        try await bookingB.save(on: req.db)

        // Broadcast to both students — each sees their own slot move as a reschedule
        req.broadcastRescheduled(old: lessonA, new: lessonB, explicitStudent: studentA)
        req.broadcastRescheduled(old: lessonB, new: lessonA, explicitStudent: studentB)

        return .ok
    }

    // MARK: - POST /instructor/bookings/:bookingID/reschedule

    func instructorReschedule(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        struct RescheduleInput: Content { let newLessonID: UUID }
        let body = try req.content.decode(RescheduleInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        guard let newLesson = try await Lesson.find(body.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        guard newLesson.startsAt > Date() else {
            throw Abort(.unprocessableEntity, reason: "Cannot reschedule to a lesson that has already started")
        }

        let oldLesson = try await booking.$lesson.get(on: req.db)
        let student   = try await booking.$user.get(on: req.db)

        booking.$lesson.id = try newLesson.requireID()

        if let mins = booking.durationMinutes {
            booking.actualEndsAt = newLesson.startsAt.addingTimeInterval(Double(mins) * 60)
        } else {
            booking.actualEndsAt = nil
        }

        try await booking.save(on: req.db)
        req.broadcastRescheduled(old: oldLesson, new: newLesson, explicitStudent: student)

        return .ok
    }

    // MARK: - PATCH /instructor/bookings/:bookingID/dropoff
    func setDropoffLocation(_ req: Request) async throws -> HTTPStatus {
        struct Body: Content {
            var dropoffLocation: String?
        }

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "bookingID missing or invalid")
        }

        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        let body = (try? req.content.decode(Body.self)) ?? Body(dropoffLocation: nil)
        let raw = body.dropoffLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        booking.dropoffLocation = raw.isEmpty ? nil : raw
        try await booking.save(on: req.db)
        return .ok
    }

    // MARK: - POST /instructor/students/:studentID/bookings

    struct InstructorCreateBookingInput: Content {
        let lessonID: UUID
        let pickupLocation: String?
    }

    struct InstructorCreateBookingResponse: Content {
        let bookingID: UUID
    }

    func createBookingForStudent(_ req: Request) async throws -> InstructorCreateBookingResponse {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "studentID missing or invalid")
        }
        guard let student = try await User.find(studentID, on: req.db) else {
            throw Abort(.notFound, reason: "Student not found")
        }
        guard student.role == "student" else {
            throw Abort(.badRequest, reason: "User is not a student")
        }

        let input = try req.content.decode(InstructorCreateBookingInput.self)

        guard let lesson = try await Lesson.find(input.lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Prevent duplicate active booking for the same student+lesson
        let existing = try await Booking.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .first()

        if existing != nil {
            // Idempotent: return the existing booking ID rather than erroring
            return InstructorCreateBookingResponse(bookingID: try existing!.requireID())
        }

        let booking = Booking(
            userID: studentID,
            lessonID: input.lessonID,
            durationMinutes: nil,
            actualEndsAt: nil,
            paymentStatus: "pending"
        )
        booking.pickupLocation = input.pickupLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
        booking.pickupSource = booking.pickupLocation != nil ? "instructor" : nil
        try await booking.save(on: req.db)

        let bookingID = try booking.requireID()
        req.logger.info("instructor.createBookingForStudent: created bookingID=\(bookingID) for studentID=\(studentID) lessonID=\(lesson.id?.uuidString ?? "?")")

        // Create or reassign a LessonFinance record so coverage/charge status works.
        let lessonID = input.lessonID
        if let existingFinance = try await LessonFinance.find(lessonID, on: req.db) {
            if existingFinance.$student.id != studentID {
                existingFinance.$student.id = studentID
                existingFinance.financeStatus = "not_covered"
                existingFinance.reservedAmount = nil
                existingFinance.coveredAt = nil
                try await existingFinance.save(on: req.db)
            }
        } else {
            let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            let defaultHourlyRate = Decimal(45)
            let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)
            let instructorID = try await User.query(on: req.db)
                .filter(\.$role == "instructor")
                .first()?.requireID()
            if let instructorID {
                let newFinance = LessonFinance(
                    lessonID: lessonID,
                    studentID: studentID,
                    instructorID: instructorID,
                    durationMinutes: durationMinutes,
                    hourlyRateSnapshot: defaultHourlyRate,
                    priceSnapshot: priceSnapshot,
                    chargeStatus: "not_charged",
                    chargedLedgerEntryID: nil,
                    financeStatus: "not_covered",
                    coveredAt: nil,
                    reservedAmount: nil
                )
                try await newFinance.save(on: req.db)
            }
        }
        try await FinanceController().reevaluateCoverageForStudent(studentID, on: req.db)

        return InstructorCreateBookingResponse(bookingID: bookingID)
    }

    // MARK: - DELETE /instructor/bookings/:bookingID

    func instructorCancelBooking(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == bookingID)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        if booking.deletedAt != nil { return .ok }

        let studentID = booking.$user.id
        booking.cancellationSource = "instructor"
        try await booking.save(on: req.db)
        try await booking.delete(on: req.db)

        let evt = BookingEvent(
            type: "instructor.cancelled",
            userID: studentID,
            lessonID: booking.$lesson.id,
            bookingID: bookingID
        )
        try await evt.save(on: req.db)

        let freedLesson = try await booking.$lesson.get(on: req.db)
        freedLesson.state = "available"
        freedLesson.calendarName = "MSM Available"
        try await freedLesson.save(on: req.db)

        do {
            try await FinanceController().reevaluateCoverageForStudent(studentID, on: req.db)
        } catch {
            req.logger.error("reevaluateCoverage failed after instructor cancel: \(error)")
        }

        try req.broadcastCancelled(for: freedLesson)
        req.application.broadcastRecoveryCandidate(for: freedLesson)
        return .ok
    }

    // MARK: - Student lesson history

    struct StudentLessonRow: Content {
        let lessonID: UUID
        let bookingID: UUID
        let startsAt: Date
        let endsAt: Date
        let durationMinutes: Int
        let financeStatus: String?   // not_covered | covered | charge_pending | charged | nil
        let chargeStatus: String?    // not_charged | charged | nil
        let isConfirmed: Bool
        let attendanceStatus: String? // attended | no_show | nil
        let cancellationType: String? // late_cancellation | nil (soft-deleted bookings only)
        let deletedAt: Date?
    }

    func studentLessons(_ req: Request) async throws -> [StudentLessonRow] {
        guard let studentID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing userID")
        }

        let bookings = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$user.$id == studentID)
            .with(\.$lesson)
            .all()

        let lessonIDs = bookings.compactMap { $0.$lesson.id }
        let finances = try await LessonFinance.query(on: req.db)
            .filter(\.$id ~~ lessonIDs)
            .all()
        let financeByLesson: [UUID: LessonFinance] = finances.reduce(into: [:]) { dict, f in
            if let id = f.id { dict[id] = f }
        }

        let bookingIDs = bookings.compactMap { $0.id }
        let confirmed = try await ConfirmedLesson.query(on: req.db)
            .filter(\.$booking.$id ~~ bookingIDs)
            .all()
        let confirmedByBooking: [UUID: ConfirmedLesson] = confirmed.reduce(into: [:]) { dict, c in
            dict[c.$booking.id] = c
        }

        return bookings.compactMap { booking -> StudentLessonRow? in
            guard let bookingID = booking.id else { return nil }
            let lesson = booking.lesson
            guard let lessonID = lesson.id else { return nil }
            let finance = financeByLesson[lessonID]
            let conf = confirmedByBooking[bookingID]
            let durationMins = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            return StudentLessonRow(
                lessonID: lessonID,
                bookingID: bookingID,
                startsAt: lesson.startsAt,
                endsAt: lesson.endsAt,
                durationMinutes: durationMins,
                financeStatus: finance?.financeStatus,
                chargeStatus: finance?.chargeStatus,
                isConfirmed: conf != nil,
                attendanceStatus: conf?.status,
                cancellationType: booking.cancellationType,
                deletedAt: booking.deletedAt
            )
        }
        .sorted { $0.startsAt > $1.startsAt }
    }
}
