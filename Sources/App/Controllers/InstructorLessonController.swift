import Vapor
import Fluent
import Foundation

struct InstructorLessonController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {

        let instructor = routes.grouped("instructor")

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

        // 1) Find lessons within the requested date range
        let lessonsInRange = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .all()

        var rows: [BookingRangeRow] = []

        // 2) For each lesson, fetch active bookings AND late-cancelled bookings
        //    (late cancellations are soft-deleted but the instructor still owes the fee).
        for lesson in lessonsInRange {
            guard let lessonID = lesson.id else { continue }

            // .withDeleted() bypasses Fluent's automatic deleted_at IS NULL filter so we
            // can then manually select active + late-cancelled rows together.
            let bookings = try await Booking.query(on: req.db)
                .withDeleted()
                .filter(\.$lesson.$id == lessonID)
                .group(.or) { g in
                    g.filter(\.$deletedAt == nil)
                    g.filter(\.$cancellationType == "late_cancellation")
                }
                .all()

            for booking in bookings {
                guard let bookingID = booking.id else { continue }

                let student = try await booking.$user.get(on: req.db)
                let studentName = student.username

                let isLate = booking.cancellationType == "late_cancellation"

                var financeStatus: String? = nil
                if let lessonFinance = try await LessonFinance.find(lessonID, on: req.db) {
                    try await FinanceController().evaluateCoverage(for: lessonFinance, on: req.db)
                    financeStatus = lessonFinance.financeStatus
                }

                rows.append(
                    BookingRangeRow(
                        id: bookingID,
                        lessonID: lessonID,
                        userID: booking.$user.id,
                        studentName: studentName,
                        studentDisplayName: student.displayName,
                        title: lesson.title,
                        startsAt: lesson.startsAt,
                        endsAt: lesson.endsAt,
                        financeStatus: financeStatus,
                        status: isLate ? "late_cancelled" : "active",
                        cancellationType: booking.cancellationType,
                        dropoffLocation: booking.dropoffLocation
                    )
                )
            }
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
            try await booking.delete(on: req.db)
            let sid = booking.$user.id
            try req.broadcastCancelled(for: lesson, studentID: sid)
            req.broadcastBookingCleared(for: lesson, studentID: sid)
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
}
