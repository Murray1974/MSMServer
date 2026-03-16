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
        // Instructor app: cancel all bookings for a lesson (free the slot)
        // NOTE: Do not register another wildcard under /instructor/bookings with a different param name,
        // because RoutingKit disallows colliding wildcards. Use /instructor/lessons/:lessonID/... instead.
        routes.grouped("instructor", "lessons").post(":lessonID", "cancel-bookings", use: cancelLessonBookings)
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

        let rawStudentName = input.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = slug(rawStudentName)

        // Never create bookings from placeholder/blank titles.
        if username.isEmpty || username == "slot" {
            throw Abort(.badRequest, reason: "Invalid student name")
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first()
        else {
            throw Abort(.badRequest, reason: "Student user not found: \(username)")
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

        // 4) Broadcast booking change (single canonical path)
        try req.broadcastBooked(for: lesson)

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

        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        var mutable = res
        mutable.body = .init(data: data)
        return mutable
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
            let rawStudentName = item.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = slug(rawStudentName)

            // Skip placeholder/blank titles so we never create bookings owned by `slot`.
            if username.isEmpty || username == "slot" {
                req.logger.info("work-bookings: skipping placeholder title for lessonID=\(item.lessonID)")
                continue
            }

            guard let user = try await User.query(on: req.db)
                .filter(\.$username == username)
                .first()
            else {
                req.logger.warning("work-bookings: user not found for title=\(rawStudentName) (slug=\(username)); skipping lessonID=\(item.lessonID)")
                continue
            }

            let lessonID = try lesson.requireID()
            let userID = try user.requireID()

            // 3) Upsert booking keyed by lessonID + userID,
            // but do NOT recreate a booking if this lesson has any booking history.
            let anyBookingEver = try await Booking.query(on: req.db)
                .withDeleted()
                .filter(\.$lesson.$id == lessonID)
                .first()

            if anyBookingEver != nil {
                // Do not recreate bookings from work sync.
                // Bookings must come from student / instructor booking flow only.
                req.logger.info("work-bookings: skip recreate (lesson already has booking history) lessonID=\(lessonID)")
            } else {
                let b = Booking()
                b.$user.id = userID
                b.$lesson.id = lessonID
                try await b.save(on: req.db)
                upserted += 1

                // 4) Broadcast booking change only when something actually changed
                try req.broadcastBooked(for: lesson)
            }
        }

        let out = WorkBookingsSyncOut(ok: true, upserted: upserted)
        let data = try JSONEncoder().encode(out)
        var res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }

    func cancelLessonBookings(req: Request) async throws -> Response {
        guard let lessonIDParam = req.parameters.get("lessonID"),
              let lessonID = UUID(uuidString: lessonIDParam) else {
            throw Abort(.badRequest, reason: "Invalid lessonID")
        }

        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Find ALL non-deleted bookings for this lesson and soft-delete them.
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .all()

        var cancelledCount = 0
        var cancelledStudentIDs: [UUID] = []

        for b in bookings {
            cancelledStudentIDs.append(b.$user.id)
            try await b.delete(on: req.db) // soft delete
            cancelledCount += 1
        }

        // Broadcast booking cancellation only to the affected student sockets,
        // then publish one canonical availability update for the freed slot.
        for sid in cancelledStudentIDs {
            try req.broadcastCancelled(for: lesson, studentID: sid)
            req.broadcastBookingCleared(for: lesson, studentID: sid)
        }
        req.broadcastBookingCleared(for: lesson)

        struct Out: Content {
            let ok: Bool
            let lessonID: UUID
            let cancelled: Int
        }

        let out = Out(ok: true, lessonID: lessonID, cancelled: cancelledCount)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(out)

        var res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        res.body = .init(data: data)
        return res
    }
}

// Helper for broadcasting to studentHub.
// For now this still broadcasts to all student sockets, but it now accepts
// an optional studentID so we have a clean seam for per-student routing next.
extension Application {
    func broadcastStudent(_ text: String, studentID: UUID? = nil) {
        if let studentID,
           let socket = self.msmStudentSockets[studentID] {

            self.logger.debug(
                "Student targeted broadcast → \(studentID.uuidString)"
            )

            socket.send(text)

        } else {

            if let studentID {
                self.logger.debug(
                    "Student socket not found, falling back to broadcast → \(studentID.uuidString)"
                )
            }

            self.studentHub.broadcast(text)
        }
    }
}

// MARK: - WebSocket broadcast helpers (used by StudentBookingsController)
extension Request {
    /// Broadcast that a lesson has been booked.
    func broadcastBooked(for lesson: Lesson) throws {
        let lessonID = try lesson.requireID().uuidString
        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "booked"
        ]
        if let user = self.auth.get(User.self) {
            payload["studentID"] = (try? user.requireID().uuidString)
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            let sid = self.auth.get(User.self).flatMap { try? $0.requireID() }
            application.broadcastStudent(text, studentID: sid)
        }
    }

    /// Broadcast that a booking has been cancelled / slot freed.
    func broadcastCancelled(for lesson: Lesson, studentID: UUID? = nil) throws {
        let lessonID = try lesson.requireID().uuidString
        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "cancelled"
        ]
        if let user = self.auth.get(User.self) {
            payload["studentID"] = (try? user.requireID().uuidString)
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            let sid = studentID ?? self.auth.get(User.self).flatMap { try? $0.requireID() }
            application.broadcastStudent(text, studentID: sid)
        }
    }

    /// Broadcast that a booking has been rescheduled to a new lesson.
    func broadcastRescheduled(old oldLesson: Lesson, new newLesson: Lesson) {
        let oldID = (try? oldLesson.requireID().uuidString) ?? ""
        let newID = (try? newLesson.requireID().uuidString) ?? ""
        var payload: [String: Any] = [
            "type": "booking_changed",
            "oldLessonID": oldID,
            "newLessonID": newID,
            "status": "rescheduled"
        ]
        if let user = self.auth.get(User.self) {
            payload["studentID"] = (try? user.requireID().uuidString)
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            application.instructorHub.broadcast(text)
            let sid = self.auth.get(User.self).flatMap { try? $0.requireID() }
            application.broadcastStudent(text, studentID: sid)
        }
    }

    /// Broadcast that a booking association has been cleared and the slot is available again.
    func broadcastBookingCleared(for lesson: Lesson, studentID: UUID? = nil) {
        guard let lessonID = try? lesson.requireID() else { return }
        let update = AvailabilityUpdate.bookingCleared(lessonID: lessonID)
        application.availabilityHub.broadcast(update)

        // Mirror the availability change onto the student websocket channel so
        // student clients connected on /ws/student can immediately repopulate
        // the Book tab after a cancellation.
        if let data = try? JSONEncoder().encode(update),
           let text = String(data: data, encoding: .utf8) {
            application.broadcastStudent(text, studentID: studentID)
        }
    }
}
