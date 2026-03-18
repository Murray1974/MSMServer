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
    }

    struct InstructorLessonRow: Content {
        var id: UUID?
        var title: String?
        var startsAt: Date
        var endsAt: Date
        var capacity: Int
        var booked: Int
        var available: Int
    }

    struct BookingRangeRow: Content {
        var id: UUID
        var studentName: String
        var title: String?
        var startsAt: Date
        var endsAt: Date
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

        // 1) Available lessons on the Untitled calendar within the requested window
        let candidates = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .filter(\.$calendarName == "Untitled")
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
                    available: remaining
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

        // 2) For each lesson, fetch its active (non-deleted) bookings and
        //    emit a summary row per booking.
        for lesson in lessonsInRange {
            guard let lessonID = lesson.id else { continue }

            let bookings = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$deletedAt == nil)
                .all()

            for booking in bookings {
                guard let bookingID = booking.id else { continue }

                let student = try await booking.$user.get(on: req.db)
                let studentName = student.username

                rows.append(
                    BookingRangeRow(
                        id: bookingID,
                        studentName: studentName,
                        title: lesson.title,
                        startsAt: lesson.startsAt,
                        endsAt: lesson.endsAt
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

        // Mark as non-student-visible by moving off the Untitled calendar.
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

        // Student-visible calendar
        lesson.calendarName = "Untitled"
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
}
