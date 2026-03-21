import Vapor
import Fluent
import Foundation

private struct SlotLink: Content {
    let externalID: String
    let lessonID: UUID
}

private struct SyncResult: Content {
    let upserted: Int
    let pruned: Int
    let links: [SlotLink]
}

public func routes(_ app: Application) throws {
    // Parse ISO8601 date strings with or without fractional seconds.
    @Sendable func parseISO8601(_ s: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: s) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    @Sendable func webSocketToken(from req: Request) -> String? {
        if let bearer = req.headers.bearerAuthorization?.token, bearer.isEmpty == false {
            return bearer
        }
        if let token = try? req.query.get(String.self, at: "token"), token.isEmpty == false {
            return token
        }
        return nil
    }

    @Sendable func authenticateWebSocket(
        _ req: Request,
        _ ws: WebSocket,
        label: String,
        onAuthenticated: @escaping @Sendable (User) -> Void
    ) {
        guard let token = webSocketToken(from: req) else {
            ws.eventLoop.execute {
                req.logger.warning("WS auth (\(label)): missing token")
                ws.close(promise: nil)
            }
            return
        }

        Task {
            do {
                let tokenHash = SessionToken.hash(token)

                guard let sessionToken = try await SessionToken.query(on: req.db)
                    .filter(\SessionToken.$tokenHash == tokenHash)
                    .first()
                else {
                    ws.eventLoop.execute {
                        req.logger.warning("WS auth (\(label)): invalid token")
                        ws.close(promise: nil)
                    }
                    return
                }

                let user = try await sessionToken.$user.get(on: req.db)

                ws.eventLoop.execute {
                    req.auth.login(user)
                    req.logger.info("WS authenticated (\(label)) user=\(user.username)")
                    onAuthenticated(user)
                }
            } catch {
                ws.eventLoop.execute {
                    req.logger.error("WS auth (\(label)) failed: \(error.localizedDescription)")
                    ws.close(promise: nil)
                }
            }
        }
    }
    // MARK: - Basic diagnostics
    // Used by mobile clients / Settings screens to verify the server is reachable.
    app.get("health") { req -> Response in
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        res.body = .init(string: "ok")
        return res
    }

    // Convenience root route so hitting http://HOST:PORT/ in a browser isn't a 404.
    app.get { req -> Response in
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        res.body = .init(string: "MSMServer running")
        return res
    }
    // MARK: - Realtime Availability WebSocket (session cookie presence)
    // This version compiles without requiring User: SessionAuthenticatable.
    // It simply checks for a Vapor session cookie or active session and closes if missing.
    let instructorWSHandler: @Sendable (Request, WebSocket) -> Void = { req, ws in
        authenticateWebSocket(req, ws, label: "instructor") { _ in
            // Register socket ONLY in the instructor hub (avoid duplicates)
            app.instructorHub.add(ws)

            // Send a small hello so clients can confirm connection visually
            ws.send(#"{"type":"hello","message":"connected"}"#)

            // Echo back any text (handy during early testing)
            ws.onText { ws, text in
                req.logger.info("WS(instructor) <- \(text)")
                ws.send(#"{"type":"echo","text":\#(String(reflecting: text))}"#)
            }

            ws.onPing { ws, data in
                req.logger.debug("WS(instructor) ping")
            }

            ws.onPong { ws, data in
                req.logger.debug("WS(instructor) pong")
            }

            ws.onClose.whenComplete { _ in
                req.logger.info("WS closed (instructor)")
                app.instructorHub.remove(ws)
            }
        }
    }

    let availabilityWSHandler: @Sendable (Request, WebSocket) -> Void = { req, ws in
        authenticateWebSocket(req, ws, label: "availability") { _ in
            // Register socket ONLY in the availability hub (avoid duplicates)
            app.availabilityHub.add(ws)

            // Send a small hello so clients can confirm connection visually
            ws.send(#"{"type":"hello","message":"connected"}"#)

            // Echo back any text (handy during early testing)
            ws.onText { ws, text in
                req.logger.info("WS(availability) <- \(text)")
                ws.send(#"{"type":"echo","text":\#(String(reflecting: text))}"#)
            }

            ws.onPing { ws, data in
                req.logger.debug("WS(availability) ping")
            }

            ws.onPong { ws, data in
                req.logger.debug("WS(availability) pong")
            }

            ws.onClose.whenComplete { _ in
                req.logger.info("WS closed (availability)")
                app.availabilityHub.remove(ws)
            }
        }
    }

    // Instructor app WebSocket
    app.webSocket("ws", "instructor") { req, ws in
        instructorWSHandler(req, ws)
    }

    // Fallback for malformed absolute-form websocket paths
    app.webSocket("ws:", "**") { req, ws in
        req.logger.warning("WS fallback route hit: \(req.url.path)")
        instructorWSHandler(req, ws)
    }

    // Agent / legacy availability WebSocket
    app.webSocket("ws", "availability") { req, ws in
        availabilityWSHandler(req, ws)
    }
    // Student WebSocket (Phase 2)
    app.webSocket("ws", "student") { req, ws in
        studentWSHandler(req, ws)
    }
    
    // Student hub handler: mirrors instructor but registers into studentHub and msmStudentSockets
    @Sendable func studentWSHandler(_ req: Request, _ ws: WebSocket) {
        authenticateWebSocket(req, ws, label: "student") { user in
            // Register this socket in the student hub so broadcasts reach student clients
            req.application.studentHub.add(ws)

            // Also register the socket by authenticated studentID for future targeted delivery.
            if let studentID = try? user.requireID() {
                var sockets = req.application.msmStudentSockets
                sockets[studentID] = ws
                req.application.msmStudentSockets = sockets
                req.logger.info("WS(student) mapped socket for user=\(user.username) id=\(studentID.uuidString)")
            }

            // Send a hello so student clients can confirm connection
            ws.send(#"{"type":"hello","message":"connected"}"#)

            ws.onText { ws, text in
                req.logger.info("WS(student) <- \(text)")
                ws.send(#"{"type":"echo","text":\#(String(reflecting: text))}"#)
            }

            ws.onClose.whenComplete { _ in
                req.logger.info("WS closed (student)")
                req.application.studentHub.remove(ws)

                if let studentID = try? user.requireID() {
                    var sockets = req.application.msmStudentSockets
                    if let mapped = sockets[studentID], mapped === ws {
                        sockets.removeValue(forKey: studentID)
                        req.application.msmStudentSockets = sockets
                    }
                }
            }
        }
    }

    // Helper: broadcast plain text to student clients.
    // For now this still broadcasts to all student sockets, but it now accepts
    // an optional studentID so we have a clean seam for per-student routing next.
    let broadcastStudentText: @Sendable (String, Application, UUID?) -> Void = { text, app, studentID in
        if let studentID {
            app.logger.debug("Student broadcast prepared for targeted delivery: \(studentID.uuidString)")
        }
        app.studentHub.broadcast(text)
    }

    // Helper: broadcast AvailabilityUpdate to all relevant hubs
    let broadcastAvailability: @Sendable (AvailabilityUpdate, Application) -> Void = { update, app in
        // Send typed update to availability hub (Agent / calendar bridge)
        app.availabilityHub.broadcast(update)

        // Encode once for text hubs
        if let data = try? JSONEncoder().encode(update),
           let text = String(data: data, encoding: .utf8) {

            // Instructor app gets full updates
            app.instructorHub.broadcast(text)

            // Student app only needs slot updates
            broadcastStudentText(text, app, nil)

            // Instructor UI refresh trigger only for instructor hub
            let slotsUpdatedJson = #"{"type":"slots_updated"}"#
            app.instructorHub.broadcast(slotsUpdatedJson)
        }
    }
    // Route listing for diagnostics (DEBUG only)
    #if DEBUG
    app.get("_routes") { req in
        app.routes.description
    }
    #endif
    
    // MARK: - Realtime test helpers (DEBUG only)
    #if DEBUG
    app.post("availability", "test") { req async throws -> HTTPStatus in
        let now = Date()
        let msg = AvailabilityUpdate(
            action: AvailabilityAction.slotCreated,
            id: UUID(),
            title: "Demo Slot",
            startsAt: now,
            endsAt: now.addingTimeInterval(3600),
            capacity: 1
        )
        broadcastAvailability(msg, req.application)
        return .ok
    }
    app.get("availability", "test") { req async throws -> String in
        let now = Date()
        let msg = AvailabilityUpdate(
            action: AvailabilityAction.slotCreated,
            id: UUID(),
            title: "Demo Slot (GET)",
            startsAt: now,
            endsAt: now.addingTimeInterval(3600),
            capacity: 1
        )
        broadcastAvailability(msg, req.application)
        return "ok"
    }

    app.post("admin", "test-broadcast") { req async throws -> HTTPStatus in
        struct Params: Decodable {
            var type: String?
            var title: String?
            var message: String?      // accepted for future use
            var slotId: UUID?
            var start: String?        // ISO8601 date string
            var end: String?          // ISO8601 date string
            var capacity: Int?
        }
        let p = try req.query.decode(Params.self)

        let iso = ISO8601DateFormatter()
        let now = Date()
        let startsAt = p.start.flatMap { iso.date(from: $0) } ?? now
        let endsAt = p.end.flatMap { iso.date(from: $0) } ?? now.addingTimeInterval(3600)

        let msg = AvailabilityUpdate(
            action: p.type ?? AvailabilityAction.slotCreated,
            id: p.slotId ?? UUID(),
            title: p.title ?? "Demo Slot",
            startsAt: startsAt,
            endsAt: endsAt,
            capacity: p.capacity ?? 1
        )

        broadcastAvailability(msg, req.application)
        return .ok
    }
    #endif
    
    // MARK: - DEV seeding endpoint (creates a future lesson and broadcasts availability)
    #if DEBUG
    app.post("dev", "lessons", "seed") { req async throws -> AvailabilityUpdate in
        struct SeedIn: Content {
            var id: UUID?
            var title: String?
            var startsAt: String   // ISO8601 e.g. 2025-11-09T10:00:00Z
            var endsAt: String     // ISO8601
            var capacity: Int?
        }

        let input = try req.content.decode(SeedIn.self)

        let iso = ISO8601DateFormatter()
        guard let s = iso.date(from: input.startsAt),
              let e = iso.date(from: input.endsAt) else {
            throw Abort(.badRequest, reason: "Use ISO8601 dates, e.g. 2025-11-09T10:00:00Z")
        }

        // Create and save a Lesson (adjust property names if your model differs)
        let lesson = Lesson()
        lesson.id = input.id ?? UUID()
        lesson.title = input.title ?? "Unassigned"
        lesson.startsAt = s
        lesson.endsAt = e
        lesson.capacity = input.capacity ?? 1
        try await lesson.save(on: req.db)

        // Broadcast to all clients so the slot appears in real time
        let update = AvailabilityUpdate(
            action: AvailabilityAction.slotAvailable,
            id: try lesson.requireID(),
            title: lesson.title,
            startsAt: lesson.startsAt,
            endsAt: lesson.endsAt,
            capacity: lesson.capacity
        )
        broadcastAvailability(update, req.application)
        return update
    }
    #endif

    // MARK: - Instructor: sync available slots (EventKit bridge)
    // Accepts a list of available slots and upserts Lessons accordingly, broadcasting changes.
    // Example payload:
    // {
    //   "timezone":"Europe/London",
    //   "prune": true,
    //   "slots":[
    //     {"startsAt":"2025-11-12T10:00:00Z","endsAt":"2025-11-12T12:00:00Z","title":"Unassigned","capacity":1},
    //     {"startsAt":"2025-11-12T14:00:00Z","endsAt":"2025-11-12T16:00:00Z"}
    //   ]
    // }
    app.post("instructor", "sync", "available") { req async throws -> SyncResult in
        struct SlotIn: Content {
            var id: UUID?
            var externalID: String?
            var startsAt: String
            var endsAt: String
            var title: String?
            var capacity: Int?
            var calendarName: String?
        }
        struct SyncIn: Content {
            var timezone: String?
            var prune: Bool?
            var slots: [SlotIn]
        }

        let input = try req.content.decode(SyncIn.self)

        // Load all future lessons to optionally prune those not present in the payload
        let now = Date()
        let futureLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= now)
            .all()

        var keepIDs = Set<UUID>()
        var upsertedCount = 0
        var links: [SlotLink] = []

        for s in input.slots {

            // Only accept MSM calendars (strict)
            guard let cal = s.calendarName,
                  cal == "Untitled" || cal == "Mike work"
            else {
                continue
            }

            let syncedState = (cal == "Untitled") ? "available" : "booked"
            guard let start = parseISO8601(s.startsAt),
                  let end = parseISO8601(s.endsAt) else {
                throw Abort(.badRequest, reason: "Use ISO8601 dates for startsAt/endsAt")
            }

            // Try match by explicit id first, then by start/end window
            let lesson: Lesson
            if let lid = s.id, let existing = try await Lesson.find(lid, on: req.db) {
                lesson = existing
            } else if let existing = try await Lesson.query(on: req.db)
                        .filter(\.$startsAt == start)
                        .filter(\.$endsAt == end)
                        .first() {
                lesson = existing
            } else {
                let l = Lesson()
                l.id = s.id ?? UUID()
                l.startsAt = start
                l.endsAt = end
                l.title = s.title ?? "Unassigned"
                l.capacity = s.capacity ?? 1
                l.calendarName = cal
                l.state = syncedState
                try await l.save(on: req.db)
                lesson = l

                // Broadcast brand-new availability
                let update = AvailabilityUpdate(
                    action: AvailabilityAction.slotAvailable,
                    id: try lesson.requireID(),
                    title: lesson.title,
                    startsAt: lesson.startsAt,
                    endsAt: lesson.endsAt,
                    capacity: lesson.capacity
                )
                broadcastAvailability(update, req.application)
                upsertedCount += 1
            }

            // Update simple fields if they changed (title/capacity/calendarName)
            var changed = false
            if let t = s.title, t != lesson.title { lesson.title = t; changed = true }
            if let c = s.capacity, c != lesson.capacity { lesson.capacity = c; changed = true }
            if cal != lesson.calendarName {
                lesson.calendarName = cal
                changed = true
            }
            if lesson.state != syncedState {
                lesson.state = syncedState
                changed = true
            }
            if changed {
                try await lesson.save(on: req.db)

                // Decide whether this slot should be visible to students based on state.
                let isStudentVisible = (lesson.state == "available")
                let action = isStudentVisible ? AvailabilityAction.slotAvailable : AvailabilityAction.slotUnavailable

                let update = AvailabilityUpdate(
                    action: action,
                    id: try lesson.requireID(),
                    title: lesson.title,
                    startsAt: lesson.startsAt,
                    endsAt: lesson.endsAt,
                    capacity: lesson.capacity
                )
                broadcastAvailability(update, req.application)
            }

            if let externalID = s.externalID {
                let lessonID = try lesson.requireID()
                links.append(.init(externalID: externalID, lessonID: lessonID))
            }

            if let id = lesson.id { keepIDs.insert(id) }
        }

        var prunedCount = 0
        if input.prune == true {
            for l in futureLessons {
                if let id = l.id, !keepIDs.contains(id) {
                    try await l.delete(on: req.db)
                    prunedCount += 1
                    // Notify clients this slot is gone
                    let update = AvailabilityUpdate(
                        action: AvailabilityAction.slotUnavailable, // treat as no longer available
                        id: try l.requireID(),
                        title: l.title,
                        startsAt: l.startsAt,
                        endsAt: l.endsAt,
                        capacity: l.capacity
                    )
                    broadcastAvailability(update, req.application)
                }
            }
        }

        return SyncResult(upserted: upsertedCount, pruned: prunedCount, links: links)
    }

    let admin = app.grouped("admin")

    // GET /admin/booking-events?type=admin.cancelled&bookingID=...&userID=...
    admin.get("booking-events") { req async throws -> [BookingEvent] in
        struct Filter: Decodable {
            var type: String?
            var bookingID: UUID?
            var userID: UUID?
            var lessonID: UUID?
        }

        let f = try req.query.decode(Filter.self)

        var query = BookingEvent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(50)

        if let type = f.type {
            query = query.filter(\.$type == type)
        }
        if let bookingID = f.bookingID {
            query = query.filter(\.$bookingID == bookingID)
        }
        if let userID = f.userID {
            query = query.filter(\.$userID == userID)
        }
        if let lessonID = f.lessonID {
            query = query.filter(\.$lessonID == lessonID)
        }

        return try await query.all()
    }

    // MARK: - Student: mark booking as paid
    app.post("student", "bookings", ":bookingID", "payment") { req async throws -> HTTPStatus in
        struct PayIn: Content { let method: String }
        _ = try req.content.decode(PayIn.self)
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "bookingID missing or invalid")
        }

        // TODO: Replace this placeholder with real DB update logic.
        req.logger.info("(TEMP) Mark booking paid: \(bookingID)")

        return .ok
    }

    // controllers
    try app.register(collection: AuthController())
    try app.register(collection: LessonsController())
    try app.register(collection: UserBookingsController())
    try app.register(collection: BookingsController())
    try app.register(collection: LessonAdminController())
    try app.register(collection: StudentBookingsController())
    try app.register(collection: StudentLessonController())
    try app.register(collection: InstructorLessonController())
    try app.register(collection: ConfirmedLessonController())
    
    // GET /me/booking-events (session cookie presence required)
    app.get("me", "booking-events") { req async throws -> [BookingEvent] in
        let hasSessionCookie = req.cookies["vapor-session"] != nil
        let hasSessionObject = (req.session.id != nil)
        guard hasSessionCookie || hasSessionObject else {
            throw Abort(.unauthorized, reason: "User not authenticated (no session cookie).")
        }

        // TODO: resolve the current user's UUID from your session store if available.
        // For now, return an empty list to keep the server compiling and running.
        return []
    }
    
}
