import Vapor
import Fluent
import Foundation

private struct SyncResult: Content { let upserted: Int; let pruned: Int }

public func routes(_ app: Application) throws {
    // MARK: - Realtime Availability WebSocket (session cookie presence)
    // This version compiles without requiring User: SessionAuthenticatable.
    // It simply checks for a Vapor session cookie or active session and closes if missing.
    let instructorWSHandler: (Request, WebSocket) -> Void = { req, ws in
        let hasSessionCookie = req.cookies["vapor-session"] != nil
        let hasSessionObject = (req.session.id != nil)
        guard hasSessionCookie || hasSessionObject else {
            req.logger.debug("WS denied: no session cookie present")
            _ = ws.close(code: .policyViolation)
            return
        }

        req.logger.info("WS connected (session ok)")

        // Register socket in the availability hub so broadcasts reach the agent
        app.availabilityHub.add(ws)

        // Send a small hello so clients can confirm connection visually
        ws.send(#"{"type":"hello","message":"connected"}"#)

        // Echo back any text (handy during early testing)
        ws.onText { ws, text in
            req.logger.info("WS <- \(text)")
            ws.send(#"{"type":"echo","text":\#(String(reflecting: text))}"#)
        }

        ws.onClose.whenComplete { _ in
            req.logger.info("WS closed (session ok)")
        }
    }

    // Primary route used by MSM Agent
    app.webSocket("ws", "instructor") { req, ws in instructorWSHandler(req, ws) }
    // Alias kept for backwards-compatibility
    app.webSocket("ws", "availability") { req, ws in instructorWSHandler(req, ws) }
    
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
            action: "slot.created",
            id: UUID(),
            title: "Demo Slot",
            startsAt: now,
            endsAt: now.addingTimeInterval(3600),
            capacity: 1
        )
        req.application.availabilityHub.broadcast(msg)
        return .ok
    }

    app.get("availability", "test") { req async throws -> String in
        let now = Date()
        let msg = AvailabilityUpdate(
            action: "slot.created",
            id: UUID(),
            title: "Demo Slot (GET)",
            startsAt: now,
            endsAt: now.addingTimeInterval(3600),
            capacity: 1
        )
        req.application.availabilityHub.broadcast(msg)
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
            action: p.type ?? "slot.created",
            id: p.slotId ?? UUID(),
            title: p.title ?? "Demo Slot",
            startsAt: startsAt,
            endsAt: endsAt,
            capacity: p.capacity ?? 1
        )

        req.application.availabilityHub.broadcast(msg)
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
            action: "slot.available",
            id: try lesson.requireID(),
            title: lesson.title ?? "Unassigned",
            startsAt: lesson.startsAt,
            endsAt: lesson.endsAt,
            capacity: lesson.capacity ?? 1
        )
        req.application.availabilityHub.broadcast(update)
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
            var startsAt: String
            var endsAt: String
            var title: String?
            var capacity: Int?
        }
        struct SyncIn: Content {
            var timezone: String?
            var prune: Bool?
            var slots: [SlotIn]
        }

        let input = try req.content.decode(SyncIn.self)
        let iso = ISO8601DateFormatter()

        // Load all future lessons to optionally prune those not present in the payload
        let now = Date()
        let futureLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= now)
            .all()

        var keepIDs = Set<UUID>()
        var upsertedCount = 0

        for s in input.slots {
            guard let start = iso.date(from: s.startsAt),
                  let end = iso.date(from: s.endsAt) else {
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
                try await l.save(on: req.db)
                lesson = l

                // Broadcast brand-new availability
                let update = AvailabilityUpdate(
                    action: "slot.available",
                    id: try lesson.requireID(),
                    title: lesson.title ?? "Unassigned",
                    startsAt: lesson.startsAt,
                    endsAt: lesson.endsAt,
                    capacity: lesson.capacity ?? 1
                )
                req.application.availabilityHub.broadcast(update)
                upsertedCount += 1
            }

            // Update simple fields if they changed (title/capacity)
            var changed = false
            if let t = s.title, t != lesson.title { lesson.title = t; changed = true }
            if let c = s.capacity, c != lesson.capacity { lesson.capacity = c; changed = true }
            if changed { try await lesson.save(on: req.db) }

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
                        action: "slot.booked", // treat as no longer available
                        id: try l.requireID(),
                        title: l.title ?? "Unassigned",
                        startsAt: l.startsAt,
                        endsAt: l.endsAt,
                        capacity: l.capacity ?? 1
                    )
                    req.application.availabilityHub.broadcast(update)
                }
            }
        }

        return SyncResult(upserted: upsertedCount, pruned: prunedCount)
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

    // controllers
    try app.register(collection: AuthController())
    try app.register(collection: LessonsController())
    try app.register(collection: UserBookingsController())
    try app.register(collection: BookingsController())
    try app.register(collection: LessonAdminController())
    try app.register(collection: StudentBookingsController())
    try app.register(collection: StudentLessonController())
    
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
