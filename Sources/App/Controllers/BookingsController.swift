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
        req.logger.info("manual-booking: incoming studentName=\(rawStudentName) slug=\(username) startsAt=\(input.startsAt) endsAt=\(input.endsAt)")

        // Never create bookings from placeholder/blank titles.
        if username.isEmpty || username == "slot" {
            throw Abort(.badRequest, reason: "Invalid student name")
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first()
        else {
            req.logger.warning("manual-booking: user not found for studentName=\(rawStudentName) slug=\(username)")
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
        req.logger.info("manual-booking: resolved user id=\(userID) username=\(user.username) displayName=\(user.displayName)")

        let booking: Booking
        if let existing = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$user.$id == userID)
            .first() {
            booking = existing
            req.logger.info("manual-booking: reusing existing booking for lessonID=\(lessonID) userID=\(userID)")
        } else {
            let b = Booking()
            b.$user.id = userID
            b.$lesson.id = lessonID
            try await b.save(on: req.db)
            booking = b
            req.logger.info("manual-booking: created booking for lessonID=\(lessonID) userID=\(userID)")
        }

        // Ensure the lesson reflects that it is now booked.
        if lesson.state != "booked" || lesson.calendarName != "Mike work" {
            lesson.state = "booked"
            lesson.calendarName = "Mike work"
            try await lesson.save(on: req.db)
        }

        let bookingID = try booking.requireID()
        req.logger.info("manual-booking: broadcasting booked for lessonID=\(lessonID) bookingID=\(bookingID) userID=\(userID)")

        // 4) Broadcast booking change (single canonical path)
        try req.broadcastBooked(for: lesson, student: user)

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
            req.logger.info("work-bookings: incoming lessonID=\(item.lessonID) studentName=\(item.studentName)")

            // 2) Resolve or create a student user for this calendar title
            let rawStudentName = item.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = slug(rawStudentName)
            req.logger.info("work-bookings: normalized title=\(rawStudentName) slug=\(username) lessonID=\(item.lessonID)")

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
            req.logger.info("work-bookings: resolved user id=\(userID) username=\(user.username) displayName=\(user.displayName) lessonID=\(lessonID)")

            // Check for an active booking for this lesson+user instead of any history
            let existingActive = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$user.$id == userID)
                .filter(\.$deletedAt == nil)
                .first()

            if existingActive != nil {
                req.logger.info("work-bookings: active booking already exists lessonID=\(lessonID) userID=\(userID)")

                if lesson.state != "booked" || lesson.calendarName != "Mike work" {
                    lesson.state = "booked"
                    lesson.calendarName = "Mike work"
                    try await lesson.save(on: req.db)
                }
            } else {
                let b = Booking()
                b.$user.id = userID
                b.$lesson.id = lessonID
                try await b.save(on: req.db)
                req.logger.info("work-bookings: created booking for lessonID=\(lessonID) userID=\(userID)")

                if lesson.state != "booked" || lesson.calendarName != "Mike work" {
                    lesson.state = "booked"
                    lesson.calendarName = "Mike work"
                    try await lesson.save(on: req.db)
                }

                upserted += 1

                req.logger.info("work-bookings: broadcasting booked for lessonID=\(lessonID) userID=\(userID)")
                // 4) Broadcast booking change only when something actually changed
                try req.broadcastBooked(for: lesson, student: user)
            }
        }

        let out = WorkBookingsSyncOut(ok: true, upserted: upserted)
        let data = try JSONEncoder().encode(out)
        let res = Response(status: .ok)
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

        let cancelledCount = try await req.cancelActiveBookings(for: lesson)

        struct Out: Content {
            let ok: Bool
            let lessonID: UUID
            let cancelled: Int
        }

        let out = Out(ok: true, lessonID: lessonID, cancelled: cancelledCount)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(out)

        let res = Response(status: .ok)
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
    /// Soft-delete all active bookings for a lesson, notify affected student sockets,
    /// and publish the canonical availability update once the slot is freed.
    @discardableResult
    func cancelActiveBookings(for lesson: Lesson) async throws -> Int {
        let lessonID = try lesson.requireID()

        let bookings = try await Booking.query(on: self.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .all()

        var cancelledStudentIDs: [UUID] = []
        cancelledStudentIDs.reserveCapacity(bookings.count)

        for booking in bookings {
            cancelledStudentIDs.append(booking.$user.id)
            try await booking.delete(on: self.db) // soft delete
        }

        for sid in cancelledStudentIDs {
            try self.broadcastCancelled(for: lesson, studentID: sid)
            self.broadcastBookingCleared(for: lesson, studentID: sid)
        }
        self.broadcastBookingCleared(for: lesson)

        return cancelledStudentIDs.count
    }

    private func sendBookingPayload(_ payload: [String: Any], studentID: UUID?) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {

            application.instructorHub.broadcast(text)
            application.broadcastStudent(text, studentID: studentID)
        }
    }

    /// Broadcast that a lesson has been booked.
    func broadcastBooked(for lesson: Lesson, student: User? = nil) throws {
        let lessonID = try lesson.requireID().uuidString

        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "booked"
        ]

        let resolvedUser = student ?? self.auth.get(User.self)
        let sid = resolvedUser.flatMap { try? $0.requireID() }

        if let user = resolvedUser {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }

        sendBookingPayload(payload, studentID: sid)
    }

    /// Broadcast that a booking has been cancelled / slot freed.
    func broadcastCancelled(for lesson: Lesson, studentID: UUID? = nil) throws {
        let lessonID = try lesson.requireID().uuidString

        var payload: [String: Any] = [
            "type": "booking_changed",
            "lessonID": lessonID,
            "status": "cancelled"
        ]

        let sid = studentID ?? self.auth.get(User.self).flatMap { try? $0.requireID() }

        if let user = self.auth.get(User.self) {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }

        sendBookingPayload(payload, studentID: sid)
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

        let sid = self.auth.get(User.self).flatMap { try? $0.requireID() }

        if let user = self.auth.get(User.self) {
            payload["studentID"] = sid?.uuidString
            payload["studentName"] = user.username
            payload["studentDisplayName"] = user.displayName
        }

        sendBookingPayload(payload, studentID: sid)
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
