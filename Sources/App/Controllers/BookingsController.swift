import Vapor
import Fluent
import Foundation

struct ManualBookingIn: Content {
    let studentName: String
    let startsAt: Date
    let endsAt: Date
}

struct WorkBookingIn: Content {
    let lessonID: UUID
    let studentName: String
}

struct WorkBookingsSyncIn: Content {
    let bookings: [WorkBookingIn]
}

struct WorkBookingsSyncOut: Content {
    let ok: Bool
    let upserted: Int
}

struct BookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // DEV unblock: manual booking creation is called from the Instructor app
        routes.grouped("bookings").post("manual", use: createManualBooking)
        // Agent: import/upsert bookings from the instructor's "work" calendar.
        routes.grouped("instructor", "sync").post("work-bookings", use: syncWorkBookings)
    }

    func createManualBooking(req: Request) async throws -> Response {
        let input = try req.content.decode(ManualBookingIn.self)

        // 1) Resolve or create a STUDENT user (manual / legacy)
        func slug(_ name: String) -> String {
            let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return lower
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        let username = slug(input.studentName)
        let user: User
        if let existing = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first() {
            user = existing
        } else {
            let u = User()
            u.username = username
            u.passwordHash = "manual"
            u.role = "student"
            try await u.save(on: req.db)
            user = u
        }

        // 2) Resolve the Lesson slot (calendar-synced)
        guard let lesson = try await Lesson.query(on: req.db)
            .filter(\.$startsAt == input.startsAt)
            .filter(\.$endsAt == input.endsAt)
            .first() else {
            throw Abort(.notFound, reason: "No lesson slot exists for this time window")
        }

        // 3) Create booking if it doesn't already exist
        let lessonID = try lesson.requireID()
        let userID = try user.requireID()

        let booking: Booking
        if let existing = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$user.$id == userID)
            .first() {
            booking = existing
        } else {
            let b = Booking()
            b.$user.id = userID
            b.$lesson.id = lessonID
            try await b.save(on: req.db)
            booking = b
        }

        let bookingID = try booking.requireID()

        // 4) Broadcast booking change so Instructor app refreshes
        let payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID.uuidString,
            "bookingID": bookingID.uuidString,
            "status": "booked"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            req.application.instructorHub.broadcast(text)
            req.application.studentHub.broadcast(text)
        }

        // 5) Return minimal success payload
        struct Out: Content {
            let ok: Bool
            let bookingID: UUID
            let lessonID: UUID
        }

        let out = Out(ok: true, bookingID: bookingID, lessonID: lessonID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(out)

        var res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }

    func syncWorkBookings(req: Request) async throws -> Response {
        let input = try req.content.decode(WorkBookingsSyncIn.self)

        func slug(_ name: String) -> String {
            let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return lower
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        var upserted = 0

        for item in input.bookings {
            // 1) Resolve lesson by ID
            guard let lesson = try await Lesson.find(item.lessonID, on: req.db) else {
                // Skip unknown lessons rather than failing the whole batch
                req.logger.warning("work-bookings: lesson not found: \(item.lessonID)")
                continue
            }

            // 2) Resolve or create a student user for this calendar title
            let username = slug(item.studentName)
            let user: User
            if let existing = try await User.query(on: req.db)
                .filter(\.$username == username)
                .first() {
                user = existing
            } else {
                let u = User()
                u.username = username
                u.passwordHash = "manual"
                u.role = "student"
                try await u.save(on: req.db)
                user = u
            }

            let lessonID = try lesson.requireID()
            let userID = try user.requireID()

            // 3) Upsert booking keyed by lessonID + userID
            let booking: Booking
            if let existing = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$user.$id == userID)
                .first() {
                booking = existing
            } else {
                let b = Booking()
                b.$user.id = userID
                b.$lesson.id = lessonID
                try await b.save(on: req.db)
                booking = b
                upserted += 1
            }

            // 4) Broadcast booking change so apps refresh
            let bookingID = (try? booking.requireID())
            let payload: [String: Any] = [
                "type": "booking_changed",
                "lessonID": lessonID.uuidString,
                "bookingID": bookingID?.uuidString ?? "",
                "status": "booked"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let text = String(data: data, encoding: .utf8) {
                req.application.instructorHub.broadcast(text)
                req.application.studentHub.broadcast(text)
            }
        }

        let out = WorkBookingsSyncOut(ok: true, upserted: upserted)
        let data = try JSONEncoder().encode(out)
        var res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }
}

// MARK: - WebSocket broadcast helpers (used by StudentBookingsController)
extension Request {
    /// Broadcast that a lesson has been booked.
    func broadcastBooked(for lesson: Lesson) throws {
        let lessonID = try lesson.requireID().uuidString
        let payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "booked"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            application.studentHub.broadcast(text)
        }
    }

    /// Broadcast that a booking has been cancelled / slot freed.
    func broadcastCancelled(for lesson: Lesson) {
        let lessonID = (try? lesson.requireID().uuidString) ?? ""
        let payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "cancelled"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            application.studentHub.broadcast(text)
        }
    }

    /// Broadcast that a booking has been rescheduled to a new lesson.
    func broadcastRescheduled(old oldLesson: Lesson, new newLesson: Lesson) {
        let oldID = (try? oldLesson.requireID().uuidString) ?? ""
        let newID = (try? newLesson.requireID().uuidString) ?? ""
        let payload: [String: Any] = [
            "type": "booking_changed",
            "oldLessonID": oldID,
            "newLessonID": newID,
            "status": "rescheduled"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            application.studentHub.broadcast(text)
        }
    }
}
