import Vapor
import Fluent
import FluentSQL
import Foundation

private struct SlotLink: Content {
    let externalID: String
    let lessonID: UUID
}

/// Extracts the stable lesson ID MSMAgent stamps onto an EKEvent's notes
/// ("MSM_LESSON_ID=<uuid>"), when present. Used by `/instructor/sync/available`
/// so a slot is matched by its stamped lesson regardless of start/end time —
/// without this, resizing an already-booked lesson's calendar event (to show a
/// student's shortened/repositioned duration) looked like a brand-new slot to
/// that sync, creating a phantom duplicate lesson + booking. Reproduced in
/// production 2026-10-24.
func extractStampedLessonID(from notes: String?) -> UUID? {
    guard let notes else { return nil }
    for line in notes.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("MSM_LESSON_ID=") else { continue }
        let idString = trimmed.dropFirst("MSM_LESSON_ID=".count)
        if let uuid = UUID(uuidString: String(idString)) {
            return uuid
        }
    }
    return nil
}

private struct SyncResult: Content {
    let upserted: Int
    let pruned: Int
    let withdrawn: Int
    let links: [SlotLink]
}

private struct InstructorSettingsView: Content {
    let currentHourlyRatePence: Int
    let contactPhone: String?
    let vehicleRegistration: String?
    let vehicleMake: String?
    let vehicleModel: String?
    let vehicleColour: String?

    init(_ settings: InstructorSettings) {
        self.currentHourlyRatePence = settings.currentHourlyRatePence
        self.contactPhone = settings.contactPhone
        self.vehicleRegistration = settings.vehicleRegistration
        self.vehicleMake = settings.vehicleMake
        self.vehicleModel = settings.vehicleModel
        self.vehicleColour = settings.vehicleColour
    }
}

/// Student-facing subset of InstructorSettings, for the "Your instructor" screen.
/// Deliberately excludes currentHourlyRatePence (that's an instructor-internal pricing
/// default, not something a student should see here).
private struct InstructorContactView: Content {
    let instructorName: String
    let contactPhone: String?
    let vehicleRegistration: String?
    let vehicleMake: String?
    let vehicleModel: String?
    let vehicleColour: String?
}

private struct InstructorTrackingView: Content {
    let bookingID: UUID
    let studentName: String
    let startedAt: Date
    let endsAt: Date
    // Carried here for JourneyTrackingManager's scenePhase-active fallback poll — the
    // push-arrival fast path gets the same four fields via the FCM data payload instead
    // (see TrackingService.swift's activate()).
    let pickupLatitude: Double?
    let pickupLongitude: Double?
    let dropoffLatitude: Double?
    let dropoffLongitude: Double?
}

private struct StudentTrackingView: Content {
    let bookingID: UUID
    let startedAt: Date
    let endsAt: Date
    let pickupLatitude: Double?
    let pickupLongitude: Double?
    let latitude: Double?
    let longitude: Double?
    let updatedAt: Date?
}

private struct LessonDiscountView: Content {
    let lessonID: UUID
    let priceSnapshot: Decimal
    let discountAmount: Decimal?
    let discountReason: String?
}

private struct AdminUserCheckResult: Content {
    let email: String
    let accountExists: Bool
    let hasProfile: Bool
    let approvalStatus: String?
}

private struct AdminUserListRow: Content {
    let id: UUID
    let email: String
    let firstName: String?
    let lastName: String?
    let role: String
    let approvalStatus: String?
}

private struct RecoveryNotificationRequest: Content {
    let clients: [String]
    let message: String
    let lessonID: UUID?
    let stage: String?
}

private struct RecoveryNotificationView: Content {
    let id: UUID?
    let clients: [String]
    let message: String
    let createdAt: Date?
    let seenAt: Date?
}

private struct MarkRecoveryNotificationsSeenRequest: Content {
    let ids: [UUID]
}

private struct RecoveryEventView: Content {
    let id: UUID?
    let lessonID: UUID
    let stage: String
    let result: String
    let clientCount: Int
    let createdAt: Date?
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

    @Sendable func normalizedStudentUsername(from raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: "-")
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
                    .filter(\SessionToken.$revoked == false)
                    .first()
                else {
                    ws.eventLoop.execute {
                        req.logger.warning("WS auth (\(label)): invalid or revoked token")
                        ws.send(#"{"type":"auth_error","reason":"invalid_token"}"#)
                        ws.close(promise: nil)
                    }
                    return
                }

                if let exp = sessionToken.expiresAt, exp < Date() {
                    sessionToken.revoked = true
                    try await sessionToken.update(on: req.db)
                    ws.eventLoop.execute {
                        req.logger.warning("WS auth (\(label)): expired token")
                        ws.send(#"{"type":"auth_error","reason":"expired_token"}"#)
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

    // POST /stripe/webhook — unauthenticated (Stripe uses HMAC-SHA256 signatures, not Bearer tokens).
    // body: .collect ensures the raw bytes are buffered before the handler runs; required for
    // signature verification, which must see the exact bytes Stripe sent.
    let webhookController = PaymentController()
    app.on(.POST, "stripe", "webhook", body: .collect(maxSize: "256kb")) { req async throws -> HTTPStatus in
        try await webhookController.handleWebhook(req)
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
            app.studentHub.broadcast(#"{"type":"instructor_presence","isOnline":true}"#)

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
                app.instructorHub.recordPong(ws)
            }

            ws.onClose.whenComplete { _ in
                req.logger.info("WS closed (instructor)")
                app.instructorHub.remove(ws)
                if !app.instructorHub.hasClients {
                    app.instructorLastSeenAt = Date()
                    app.studentHub.broadcast(#"{"type":"instructor_presence","isOnline":false}"#)
                }
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
        req.logger.info("WS route hit: /ws/instructor authHeaderPresent=\(!req.headers[.authorization].isEmpty)")
        instructorWSHandler(req, ws)
    }

    // Fallback for malformed absolute-form websocket paths
    app.webSocket("ws:", "**") { req, ws in
        req.logger.warning("WS fallback route hit: \(req.url.path) authHeaderPresent=\(!req.headers[.authorization].isEmpty)")
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

            // Register socket for targeted delivery — append so multiple tabs don't evict each other.
            if let studentID = try? user.requireID() {
                var sockets = req.application.msmStudentSockets
                var list = sockets[studentID] ?? []
                list.append(ws)
                sockets[studentID] = list
                req.application.msmStudentSockets = sockets
                req.logger.info("WS(student) mapped socket for user=\(user.username) id=\(studentID.uuidString) total=\(list.count)")
            }

            // Send a hello so student clients can confirm connection
            ws.send(#"{"type":"hello","message":"connected"}"#)

            ws.onText { ws, text in
                req.logger.info("WS(student) <- \(text)")
                ws.send(#"{"type":"echo","text":\#(String(reflecting: text))}"#)
            }

            ws.onPong { ws, data in
                req.application.studentHub.recordPong(ws)
            }

            ws.onClose.whenComplete { _ in
                req.logger.info("WS closed (student)")
                req.application.studentHub.remove(ws)

                if let studentID = try? user.requireID() {
                    var sockets = req.application.msmStudentSockets
                    sockets[studentID]?.removeAll(where: { $0 === ws })
                    if sockets[studentID]?.isEmpty == true { sockets.removeValue(forKey: studentID) }
                    req.application.msmStudentSockets = sockets
                    if (req.application.msmStudentSockets[studentID] ?? []).isEmpty {
                        var lastSeen = req.application.studentLastSeen
                        lastSeen[studentID] = Date()
                        req.application.studentLastSeen = lastSeen
                    }
                }
            }
        }
    }

    // Helper: send plain text to student clients.
    // If a studentID is provided, send only to that mapped student socket and
    // return whether a live socket existed. Otherwise broadcast to all student sockets.
    let broadcastStudentText: @Sendable (String, Application, UUID?) -> Bool = { text, app, studentID in
        if let studentID {
            let all = app.msmStudentSockets[studentID] ?? []
            let live = all.filter { !$0.isClosed }
            if live.count != all.count {
                var mutable = app.msmStudentSockets
                if live.isEmpty { mutable.removeValue(forKey: studentID) } else { mutable[studentID] = live }
                app.msmStudentSockets = mutable
            }
            guard !live.isEmpty else {
                app.logger.debug("Student targeted send skipped: no socket for \(studentID.uuidString)")
                return false
            }
            for ws in live { ws.send(text) }
            return true
        } else {
            app.studentHub.broadcast(text)
            return true
        }
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
            _ = broadcastStudentText(text, app, nil)

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
    // Auth added 28 Oct 2026: this was registered directly on `app` with no auth group at
    // all (unlike every other /instructor/* route, which goes through SessionTokenAuthenticator
    // via InstructorLessonController's RouteCollection) — anyone who could reach the server
    // could POST arbitrary lesson availability with no credentials. Found via audit.
    app.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        .post("instructor", "sync", "available") { req async throws -> SyncResult in
        struct SlotIn: Content {
            var id: UUID?
            var externalID: String?
            var startsAt: String
            var endsAt: String
            var title: String?
            var capacity: Int?
            var calendarName: String?
            var notes: String?
        }
        struct SyncIn: Content {
            var timezone: String?
            var prune: Bool?
            var slots: [SlotIn]
        }

        req.logger.notice("[SYNC] ▶ handler entered — body=\(req.body.data?.readableBytes ?? -1) bytes")
        let t0 = Date()
        let input = try req.content.decode(SyncIn.self)
        let t1 = Date()
        req.logger.notice("[SYNC] decoded \(input.slots.count) slots in \(String(format: "%.3f", t1.timeIntervalSince(t0)))s")

        // Load all future lessons once — used for in-memory lookups to avoid N+1 DB queries.
        // Use endsAt >= now so currently-in-progress lessons are included in the dedup map;
        // without this, syncing while a lesson is active creates a duplicate record.
        let now = Date()
        let futureLessons = try await Lesson.query(on: req.db)
            .filter(\.$endsAt >= now)
            .all()
        let t2 = Date()
        req.logger.notice("[SYNC] loaded \(futureLessons.count) future lessons in \(String(format: "%.3f", t2.timeIntervalSince(t1)))s")

        // Build lookup maps so each slot can be matched in O(1) without extra DB queries.
        var futureByID: [UUID: Lesson] = [:]
        var futureByTime: [String: Lesson] = [:]
        for l in futureLessons {
            if let id = l.id { futureByID[id] = l }
            let key = "\(l.startsAt.timeIntervalSince1970)_\(l.endsAt.timeIntervalSince1970)"
            futureByTime[key] = l
        }

        var keepIDs = Set<UUID>()
        var upsertedCount = 0
        var links: [SlotLink] = []

        for s in input.slots {

            // Only accept MSM calendars (strict)
            guard let cal = s.calendarName,
                  cal == "MSM Available" || cal == "MSM Lessons"
            else {
                continue
            }

            let syncedState = (cal == "MSM Available") ? "available" : "booked"
            guard let start = parseISO8601(s.startsAt),
                  let end = parseISO8601(s.endsAt) else {
                throw Abort(.badRequest, reason: "Use ISO8601 dates for startsAt/endsAt")
            }

            // Match by explicit id first, then by the stamped MSM_LESSON_ID in notes
            // (so a resized/moved calendar event still resolves to its real lesson
            // instead of looking like a new slot), then by start/end time (in-memory).
            // No per-slot DB queries — all lookups use the futureLessons fetch above.
            let timeKey = "\(start.timeIntervalSince1970)_\(end.timeIntervalSince1970)"
            let stampedID = extractStampedLessonID(from: s.notes)
            let lesson: Lesson
            if let lid = s.id, let existing = futureByID[lid] {
                lesson = existing
            } else if let sid = stampedID, let existing = futureByID[sid] {
                lesson = existing
            } else if let existing = futureByTime[timeKey] {
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

                // Register the new lesson in both lookup maps immediately — otherwise a second
                // slot later in this same batch at the identical start/end time won't find it
                // and will create its own duplicate lesson instead of reusing this one.
                futureByID[try lesson.requireID()] = lesson
                futureByTime[timeKey] = lesson

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

            // Only save when state changes (available ↔ booked). Title/calendarName drift
            // is cosmetic and not worth a DB write on every sync — avoid N+1 saves.
            var stateChanged = lesson.state != syncedState
            // Block available→booked via sync when no active booking exists: prevents a
            // stale MSMAgent calendar event from reverting a student's cancellation.
            if stateChanged && lesson.state == "available" && syncedState == "booked" {
                let hasBooking = (try? await Booking.query(on: req.db)
                    .filter(\.$lesson.$id == lesson.requireID())
                    .filter(\.$deletedAt == nil)
                    .count()) ?? 0
                if hasBooking == 0 { stateChanged = false }
            }

            // A slot matched by id/stamped-id (not brand new) that's still "available" on both
            // sides can have genuinely different start/end than what's stored — the instructor
            // resized the calendar event. Nothing above ever reconciled that: a matched lesson's
            // startsAt/endsAt was only ever set at creation. A resize whose new window didn't
            // happen to collide with another lesson's id/stamp/time silently kept showing the
            // OLD window to students forever — this is what produced the overlapping "duplicate"
            // available slots found in production 2026-10-25/26, not true duplication. Booked
            // lessons are deliberately excluded: their time is owned by the instructor app's
            // dedicated duration/reschedule flow, which sends its own student-facing
            // notification — a raw calendar resize must never silently retime a booked lesson.
            let timesChanged = lesson.state == "available" && syncedState == "available"
                && (lesson.startsAt != start || lesson.endsAt != end)

            if stateChanged {
                if let t = s.title { lesson.title = t }
                if let c = s.capacity { lesson.capacity = c }
                lesson.calendarName = cal
                lesson.state = syncedState
            }
            if timesChanged {
                lesson.startsAt = start
                lesson.endsAt = end
                if let c = s.capacity { lesson.capacity = c }
            }
            let changed = stateChanged || timesChanged
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

        let t3 = Date()
        req.logger.notice("[SYNC] processed slots in \(String(format: "%.3f", t3.timeIntervalSince(t2)))s — upserted=\(upsertedCount)")

        var prunedCount = 0
        var withdrawnCount = 0
        if input.prune == true {
            let toPrune = futureLessons.filter { l in
                guard let id = l.id else { return false }
                // Only prune available lessons. Booked, personal, confirmed, and other
                // non-available lessons are managed by their own endpoints and must never
                // be deleted by a calendar sync — doing so would re-expose personal slots
                // to students and delete lesson history.
                guard l.state == "available" else { return false }
                return !keepIDs.contains(id)
            }
            if !toPrune.isEmpty {
                let pruneIDs = toPrune.compactMap { $0.id }
                // Exclude lessons that have any booking history (including soft-deleted
                // cancellations) — deleting them would break finance/audit records.
                let withHistoryIDs = Set(
                    try await Booking.query(on: req.db)
                        .withDeleted()
                        .filter(\.$lesson.$id ~~ pruneIDs)
                        .all()
                        .compactMap { $0.$lesson.id }
                )
                let safeIDs = pruneIDs.filter { !withHistoryIDs.contains($0) }
                let safeIDSet = Set(safeIDs)
                let toActuallyPrune = toPrune.filter { $0.id.map { safeIDSet.contains($0) } ?? false }
                if !safeIDs.isEmpty {
                    try await Lesson.query(on: req.db)
                        .filter(\.$id ~~ safeIDs)
                        .delete()
                    prunedCount = safeIDs.count
                    for l in toActuallyPrune {
                        let update = AvailabilityUpdate(
                            action: AvailabilityAction.slotUnavailable,
                            id: try l.requireID(),
                            title: l.title,
                            startsAt: l.startsAt,
                            endsAt: l.endsAt,
                            capacity: l.capacity
                        )
                        broadcastAvailability(update, req.application)
                    }
                }

                // Lessons with booking history can't be deleted (audit/finance records would
                // break), but leaving them untouched meant a slot that fell out of the live
                // calendar (resized/deleted) stayed "available" and fully bookable forever,
                // invisibly, since nothing ever re-checks it once it's protected from deletion.
                // Withdraw instead: keeps the row and its booking/finance history intact, but
                // flips it out of "available" so every student/instructor query (all of which
                // filter strictly on state == "available") stops surfacing it. Reproduced in
                // production 2026-10-25 — see [[project_duplicate_lesson_bug]].
                let withdrawIDs = Array(withHistoryIDs)
                if !withdrawIDs.isEmpty {
                    try await Lesson.query(on: req.db)
                        .filter(\.$id ~~ withdrawIDs)
                        .set(\.$state, to: "withdrawn")
                        .update()
                    withdrawnCount = withdrawIDs.count
                    let withdrawnSet = Set(withdrawIDs)
                    for l in toPrune where l.id.map({ withdrawnSet.contains($0) }) ?? false {
                        let update = AvailabilityUpdate(
                            action: AvailabilityAction.slotUnavailable,
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
        }

        let t4 = Date()
        req.logger.notice("[SYNC] prune done in \(String(format: "%.3f", t4.timeIntervalSince(t3)))s — pruned=\(prunedCount) withdrawn=\(withdrawnCount) total=\(String(format: "%.3f", t4.timeIntervalSince(t0)))s")
        return SyncResult(upserted: upsertedCount, pruned: prunedCount, withdrawn: withdrawnCount, links: links)
    }

    let admin = app.grouped("admin")
    let adminProtected = admin.grouped(SessionTokenAuthenticator(), User.guardMiddleware())

    // POST /admin/backfill-lesson-finance
    // One-time fix: creates missing LessonFinance records for all active bookings that
    // were created via the instructor path (which previously skipped LessonFinance creation).
    adminProtected.post("backfill-lesson-finance") { req async throws -> Response in
        struct BackfillResult: Content {
            var created: Int
            var skipped: Int
            var studentCount: Int
        }

        let bookings = try await Booking.query(on: req.db)
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .all()

        let instructorID = try await User.query(on: req.db)
            .filter(\.$role == "instructor")
            .first()?.requireID()
        guard let instructorID else {
            throw Abort(.internalServerError, reason: "No instructor found")
        }

        var created = 0
        var skipped = 0
        var affectedStudentIDs = Set<UUID>()

        for booking in bookings {
            let lessonID = booking.$lesson.id
            let studentID = booking.$user.id

            if try await LessonFinance.find(lessonID, on: req.db) != nil {
                skipped += 1
                continue
            }

            let lesson = booking.lesson
            let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            let studentProfile = try await StudentProfile.query(on: req.db)
                .filter(\.$user.$id == studentID)
                .first()
            let hourlyRate = studentProfile?.hourlyRate ?? 45
            let priceSnapshot = LessonFinance.calculatedPrice(durationMinutes: durationMinutes, hourlyRate: hourlyRate)

            let finance = LessonFinance(
                lessonID: lessonID,
                studentID: studentID,
                instructorID: instructorID,
                durationMinutes: durationMinutes,
                hourlyRateSnapshot: hourlyRate,
                priceSnapshot: priceSnapshot,
                chargeStatus: "not_charged",
                chargedLedgerEntryID: nil,
                financeStatus: "not_covered",
                coveredAt: nil,
                reservedAmount: nil
            )
            try await finance.save(on: req.db)
            created += 1
            affectedStudentIDs.insert(studentID)
        }

        for studentID in affectedStudentIDs {
            try await FinanceController().reevaluateCoverageForStudent(studentID, on: req.db)
        }

        req.logger.notice("[backfill] LessonFinance: created=\(created) skipped=\(skipped) students=\(affectedStudentIDs.count)")
        return try await BackfillResult(created: created, skipped: skipped, studentCount: affectedStudentIDs.count)
            .encodeResponse(status: .ok, for: req)
    }

    // POST /admin/backfill-inactivity-fields
    // One-time fix: the 14/21/28-day inactivity auto-archive system only stamps
    // StudentProfile.firstLessonConfirmedAt / lastAttendedLessonAt going forward, from new
    // ConfirmedLesson confirms. Existing students with lesson history that predates that change
    // would otherwise never enter the inactivity system at all. This derives both fields from
    // each student's existing "attended" ConfirmedLesson records. Idempotent — safe to re-run;
    // skips any profile that already has firstLessonConfirmedAt set.
    adminProtected.post("backfill-inactivity-fields") { req async throws -> Response in
        struct NoHistoryStudent: Content {
            var studentID: UUID
            var name: String
            var accountStatus: String
        }
        struct BackfillResult: Content {
            var updated: Int
            var skippedAlreadySet: Int
            var skippedNoAttendedLesson: Int
            var noAttendedLessonStudents: [NoHistoryStudent]
        }

        let attended = try await ConfirmedLesson.query(on: req.db)
            .filter(\.$status == ConfirmedLesson.Status.attended.rawValue)
            .all()

        var firstByStudent: [UUID: Date] = [:]
        var lastByStudent: [UUID: Date] = [:]
        for record in attended {
            guard let confirmedAt = record.confirmedAt else { continue }
            let studentID = record.$user.id
            firstByStudent[studentID] = min(firstByStudent[studentID] ?? confirmedAt, confirmedAt)
            lastByStudent[studentID] = max(lastByStudent[studentID] ?? confirmedAt, confirmedAt)
        }

        var updated = 0
        var skippedAlreadySet = 0
        var skippedNoAttendedLesson = 0
        var noAttendedLessonStudents: [NoHistoryStudent] = []

        let profiles = try await StudentProfile.query(on: req.db).all()
        for profile in profiles {
            let studentID = profile.$user.id
            guard profile.firstLessonConfirmedAt == nil else {
                skippedAlreadySet += 1
                continue
            }
            guard let first = firstByStudent[studentID], let last = lastByStudent[studentID] else {
                skippedNoAttendedLesson += 1
                let name = [profile.firstName, profile.lastName].compactMap { $0 }.joined(separator: " ")
                noAttendedLessonStudents.append(NoHistoryStudent(
                    studentID: studentID,
                    name: name.isEmpty ? (profile.email ?? "Unknown") : name,
                    accountStatus: profile.accountStatus
                ))
                continue
            }
            profile.firstLessonConfirmedAt = first
            profile.lastAttendedLessonAt = last
            try await profile.save(on: req.db)
            updated += 1
        }

        req.logger.notice("[backfill] inactivity fields: updated=\(updated) alreadySet=\(skippedAlreadySet) noAttendedLesson=\(skippedNoAttendedLesson)")
        return try await BackfillResult(
            updated: updated,
            skippedAlreadySet: skippedAlreadySet,
            skippedNoAttendedLesson: skippedNoAttendedLesson,
            noAttendedLessonStudents: noAttendedLessonStudents
        ).encodeResponse(status: .ok, for: req)
    }

    // GET /admin/inactivity-preview
    // Read-only. Mirrors InactivityEnforcementService.process()'s exact logic without mutating
    // anything, so we can see what the next scheduled cycle would do before it does it —
    // specifically useful right after backfilling lastAttendedLessonAt from historical data, since
    // that can put students who were never evaluated before straight past the 14/21/28-day marks.
    adminProtected.get("inactivity-preview") { req async throws -> Response in
        struct PreviewRow: Content {
            var studentID: UUID
            var name: String
            var lastAttendedLessonAt: Date
            var daysSinceLastLesson: Int
            var hasFutureLesson: Bool
            var wouldTrigger: String
        }
        struct PreviewResult: Content {
            var evaluated: Int
            var rows: [PreviewRow]
        }

        let profiles = try await StudentProfile.query(on: req.db)
            .filter(\.$accountStatus == "active")
            .filter(\.$firstLessonConfirmedAt != nil)
            .all()

        var rows: [PreviewRow] = []
        for profile in profiles {
            guard let lastLesson = profile.lastAttendedLessonAt else { continue }
            let studentID = profile.$user.id

            let now = Date()
            let bookings = try await Booking.query(on: req.db)
                .filter(\.$user.$id == studentID)
                .filter(\.$deletedAt == .null)
                .with(\.$lesson)
                .all()
            let hasFuture = bookings.contains { $0.lesson.startsAt > now }

            let days = Calendar.current.dateComponents([.day], from: lastLesson, to: now).day ?? 0

            var wouldTrigger = "none"
            if !hasFuture {
                if days >= 28 && profile.inactivityAutoDeactivatedAt == nil {
                    wouldTrigger = "AUTO-DEACTIVATE"
                } else if days >= 21 && profile.inactivityStage21SentAt == nil {
                    wouldTrigger = "stage21_push"
                } else if days >= 14 && profile.inactivityStage14SentAt == nil {
                    wouldTrigger = "stage14_push"
                }
            }

            let name = [profile.firstName, profile.lastName].compactMap { $0 }.joined(separator: " ")
            rows.append(PreviewRow(
                studentID: studentID,
                name: name.isEmpty ? (profile.email ?? "Unknown") : name,
                lastAttendedLessonAt: lastLesson,
                daysSinceLastLesson: days,
                hasFutureLesson: hasFuture,
                wouldTrigger: wouldTrigger
            ))
        }

        return try await PreviewResult(evaluated: profiles.count, rows: rows)
            .encodeResponse(status: .ok, for: req)
    }

    // GET /admin/booking-events?type=admin.cancelled&bookingID=...&userID=...
    adminProtected.get("booking-events") { req async throws -> [BookingEvent] in
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

    // GET /admin/recovery-events?lessonID=...&limit=50
    // GET /admin/lesson-stats — lesson table health check (counts by state/calendar)
    adminProtected.get("lesson-stats") { req async throws -> Response in
        struct LessonStats: Content {
            var totalFuture: Int
            var byState: [String: Int]
            var byCalendar: [String: Int]
            var duplicateTimeslots: Int
        }
        let now = Date()
        let all = try await Lesson.query(on: req.db).filter(\.$startsAt >= now).all()
        var byState: [String: Int] = [:]
        var byCalendar: [String: Int] = [:]
        var seenTimes = Set<String>()
        var dupes = 0
        for l in all {
            byState[l.state, default: 0] += 1
            byCalendar[l.calendarName ?? "nil", default: 0] += 1
            let key = "\(l.startsAt.timeIntervalSince1970)_\(l.endsAt.timeIntervalSince1970)"
            if !seenTimes.insert(key).inserted { dupes += 1 }
        }
        let stats = LessonStats(totalFuture: all.count, byState: byState, byCalendar: byCalendar, duplicateTimeslots: dupes)
        return try await stats.encodeResponse(for: req)
    }

    // POST /admin/prune-duplicate-lessons — removes duplicate available lessons (same startsAt/endsAt, no bookings)
    adminProtected.post("prune-duplicate-lessons") { req async throws -> Response in
        struct PruneResult: Content { var deleted: Int }
        let now = Date()
        let all = try await Lesson.query(on: req.db).filter(\.$startsAt >= now).filter(\.$state == "available").all()
        var seen: [String: UUID] = [:]
        var toDelete: [UUID] = []
        for l in all {
            guard let id = l.id else { continue }
            let key = "\(l.startsAt.timeIntervalSince1970)_\(l.endsAt.timeIntervalSince1970)"
            if let firstID = seen[key] {
                let _ = firstID
                toDelete.append(id)
            } else {
                seen[key] = id
            }
        }
        if !toDelete.isEmpty {
            // Exclude any lesson with booking history (including soft-deleted cancellations).
            let withHistoryIDs = Set(
                try await Booking.query(on: req.db)
                    .withDeleted()
                    .filter(\.$lesson.$id ~~ toDelete)
                    .all()
                    .compactMap { $0.$lesson.id }
            )
            let safeToDelete = toDelete.filter { !withHistoryIDs.contains($0) }
            if !safeToDelete.isEmpty {
                try await Lesson.query(on: req.db).filter(\.$id ~~ safeToDelete).delete()
            }
            return try await PruneResult(deleted: safeToDelete.count).encodeResponse(for: req)
        }
        return try await PruneResult(deleted: 0).encodeResponse(for: req)
    }

    // GET /admin/chat/orphaned — read-only preview of chat_messages whose non-instructor
    // party no longer has a matching User (leftover from deleted test accounts on old
    // iPhone 12/16 test builds). Check this before calling clear-orphaned.
    adminProtected.get("chat", "orphaned") { req async throws -> Response in
        struct OrphanedConversation: Content {
            var partyID: UUID
            var messageCount: Int
            var lastMessage: String
            var lastMessageAt: Date?
        }
        struct OrphanedResult: Content { var conversations: [OrphanedConversation] }

        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        let instructorID = try instructor.requireID()

        let allMessages = try await ChatMessage.query(on: req.db)
            .group(.or) { g in
                g.filter(\.$senderID == instructorID)
                g.filter(\.$receiverID == instructorID)
            }
            .sort(\.$createdAt, .descending)
            .all()

        var seen = Set<UUID>()
        var results: [OrphanedConversation] = []
        for msg in allMessages {
            let partyID = msg.senderID == instructorID ? msg.receiverID : msg.senderID
            guard !seen.contains(partyID) else { continue }
            seen.insert(partyID)

            let exists = try await User.query(on: req.db).filter(\.$id == partyID).first() != nil
            guard !exists else { continue }

            let messageCount = allMessages.filter { $0.senderID == partyID || $0.receiverID == partyID }.count
            results.append(OrphanedConversation(
                partyID: partyID,
                messageCount: messageCount,
                lastMessage: msg.content,
                lastMessageAt: msg.createdAt
            ))
        }
        return try await OrphanedResult(conversations: results).encodeResponse(for: req)
    }

    // POST /admin/chat/clear-orphaned — deletes chat_messages whose non-instructor party no
    // longer has a matching User. Only ever touches rows already identified as orphaned by
    // GET /admin/chat/orphaned above — never touches a conversation where the other party's
    // User account still exists, so a real student's chat history can't be wiped by this.
    adminProtected.post("chat", "clear-orphaned") { req async throws -> Response in
        struct ClearResult: Content { var deletedMessages: Int; var conversationsCleared: Int }

        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        let instructorID = try instructor.requireID()

        let allMessages = try await ChatMessage.query(on: req.db)
            .group(.or) { g in
                g.filter(\.$senderID == instructorID)
                g.filter(\.$receiverID == instructorID)
            }
            .all()

        var partyIDs = Set<UUID>()
        for msg in allMessages {
            partyIDs.insert(msg.senderID == instructorID ? msg.receiverID : msg.senderID)
        }

        var orphanedIDs: [UUID] = []
        for partyID in partyIDs {
            let exists = try await User.query(on: req.db).filter(\.$id == partyID).first() != nil
            if !exists { orphanedIDs.append(partyID) }
        }

        guard !orphanedIDs.isEmpty else {
            return try await ClearResult(deletedMessages: 0, conversationsCleared: 0).encodeResponse(for: req)
        }

        let toDelete = allMessages.filter { orphanedIDs.contains($0.senderID) || orphanedIDs.contains($0.receiverID) }
        let idsToDelete = toDelete.compactMap { $0.id }
        try await ChatMessage.query(on: req.db).filter(\.$id ~~ idsToDelete).delete()

        req.logger.notice("[Admin] Cleared \(idsToDelete.count) orphaned chat messages across \(orphanedIDs.count) conversations, by \(instructor.username)")
        return try await ClearResult(deletedMessages: idsToDelete.count, conversationsCleared: orphanedIDs.count).encodeResponse(for: req)
    }

    adminProtected.get("recovery-events") { req async throws -> [RecoveryEventView] in
        struct Filter: Decodable {
            var lessonID: UUID?
            var limit: Int?
        }

        let f = try req.query.decode(Filter.self)

        var query = RecoveryEvent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(min(max(f.limit ?? 50, 1), 200))

        if let lessonID = f.lessonID {
            query = query.filter(\.$lessonID == lessonID)
        }

        let events = try await query.all()

        return events.map {
            RecoveryEventView(
                id: $0.id,
                lessonID: $0.lessonID,
                stage: $0.stage,
                result: $0.result,
                clientCount: $0.clientCount,
                createdAt: $0.createdAt
            )
        }
    }

    let studentProtected = app.grouped(SessionTokenAuthenticator(), BearerTokenAuthenticator(), User.guardMiddleware()).grouped("student")

    // GET /student/balance — student's own balance, late-cancel fees, and transaction history
    studentProtected.get("balance") { req async throws -> StudentSelfBalanceView in
        let userID = try req.auth.require(User.self).requireID()

        let entries = try await LedgerEntry.query(on: req.db)
            .filter(\.$student.$id == userID)
            .with(\.$lesson)
            .sort(\.$effectiveDate, .descending)
            .all()

        let activeEntries = entries.filter { $0.voidedAt == nil }
        let balance = activeEntries.reduce(Decimal.zero) { $0 + $1.amount }
        let lateCancelEntries = activeEntries.filter { $0.type == "late_cancellation_charge" }
        let lateCancelFeesCount = lateCancelEntries.count
        let lateCancelFeesTotal = lateCancelEntries.reduce(Decimal.zero) { $0 + abs($1.amount) }

        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()

        // Batch-fetch discount info for any lesson these transactions reference, so a
        // discounted lesson-charge entry can show the discount that produced its amount.
        let entryLessonIDs = Array(Set(activeEntries.compactMap { $0.$lesson.id }))
        let financeByLessonID = try await LessonFinance.query(on: req.db)
            .filter(\.$id ~~ entryLessonIDs)
            .all()
            .reduce(into: [UUID: LessonFinance]()) { $0[$1.id!] = $1 }

        let transactions = activeEntries.compactMap { entry -> StudentTransactionView? in
            guard let id = entry.id else { return nil }
            let finance = entry.$lesson.id.flatMap { financeByLessonID[$0] }
            return StudentTransactionView(
                id: id,
                lessonID: entry.$lesson.id,
                lessonStartsAt: entry.lesson?.startsAt,
                type: entry.type,
                amount: entry.amount,
                paymentMethod: entry.paymentMethod,
                note: entry.note,
                effectiveDate: entry.effectiveDate,
                createdAt: entry.createdAt,
                voidedAt: nil,
                voidReason: nil,
                discountAmount: finance?.discountAmount,
                discountReason: finance?.discountReason
            )
        }

        // ── Pending payment booking (48h enforcement window) ─────────────────
        // Find the soonest active booking within the next 50h that isn't covered.
        let iso = ISO8601DateFormatter()
        let now = Date()
        let windowEnd = now.addingTimeInterval(50 * 3_600)

        let upcomingLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt > now)
            .filter(\.$startsAt <= windowEnd)
            .all()
        let upcomingLessonIDs = upcomingLessons.compactMap { $0.id }

        var pendingPaymentBooking: PendingPaymentView? = nil

        if !upcomingLessonIDs.isEmpty {
            let upcomingBookings = try await Booking.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$lesson.$id ~~ upcomingLessonIDs)
                .filter(\.$deletedAt == .null)
                .with(\.$lesson)
                .sort(\.$createdAt, .ascending)
                .all()

            for booking in upcomingBookings {
                guard let bookingID = booking.id else { continue }
                // Only enforce Stripe payment bookings — cash/bank students are managed manually.
                guard booking.paymentStatus == "requires_immediate_payment" else { continue }
                let bLessonID = booking.$lesson.id
                let bLesson = booking.lesson
                let threshold = bLesson.startsAt.addingTimeInterval(-48 * 3_600)
                // Only show modal once inside 48h window.
                guard now >= threshold else { continue }

                let lf = try? await LessonFinance.find(bLessonID, on: req.db)
                if lf?.financeStatus == "covered" { continue }

                // Calculate amount due.
                let amountDue: Decimal
                if let snapshot = lf?.priceSnapshot, snapshot > 0 {
                    amountDue = snapshot
                } else {
                    let mins = max(0, Int(bLesson.endsAt.timeIntervalSince(bLesson.startsAt) / 60))
                    let studentProfile = try await StudentProfile.query(on: req.db)
                        .filter(\.$user.$id == userID)
                        .first()
                    amountDue = LessonFinance.calculatedPrice(durationMinutes: mins, hourlyRate: studentProfile?.hourlyRate ?? 45)
                }

                pendingPaymentBooking = PendingPaymentView(
                    bookingID: bookingID.uuidString,
                    lessonID: bLessonID.uuidString,
                    startsAt: iso.string(from: bLesson.startsAt),
                    endsAt: iso.string(from: bLesson.endsAt),
                    amountDue: amountDue,
                    discountAmount: lf?.discountAmount,
                    discountReason: lf?.discountReason
                )
                break  // surface the soonest only
            }
        }

        // ── Default-tab signal (My Lessons vs Book) ──────────────────────────
        let hasUpcomingLessons = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deletedAt == .null)
            .with(\.$lesson)
            .all()
            .contains { $0.lesson.startsAt > now }

        // ── Hold recovery info ────────────────────────────────────────────────
        var holdLessonID: String? = nil
        var holdLessonStartsAt: String? = nil
        var holdLessonAvailable = false

        if profile?.accountHold == true {
            // Find the most recent system auto-cancel for this student.
            if let cancelledBooking = try? await Booking.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$cancellationSource == "system_auto_cancel")
                .withDeleted()
                .sort(\.$deletedAt, .descending)
                .with(\.$lesson)
                .first() {

                let cancelledLesson = cancelledBooking.lesson
                holdLessonID = cancelledLesson.id?.uuidString
                holdLessonStartsAt = iso.string(from: cancelledLesson.startsAt)
                holdLessonAvailable = (cancelledLesson.state == "available" && cancelledLesson.startsAt > now)
            }
        }

        return StudentSelfBalanceView(
            currentBalance: balance,
            lateCancelFeesCount: lateCancelFeesCount,
            lateCancelFeesTotal: lateCancelFeesTotal,
            transactions: transactions,
            accountHold: profile?.accountHold ?? false,
            accountHoldReason: profile?.accountHoldReason,
            accountStatus: profile?.accountStatus ?? "active",
            pendingPaymentBooking: pendingPaymentBooking,
            holdLessonID: holdLessonID,
            holdLessonStartsAt: holdLessonStartsAt,
            holdLessonAvailable: holdLessonAvailable,
            hasUpcomingLessons: hasUpcomingLessons,
            hourlyRatePence: profile?.hourlyRatePence ?? 4500,
            theoryTestPassed: profile?.theoryTestPassed ?? false
        )
    }

    // POST /student/payment-intent  (+ /create-payment-intent alias)
    let paymentController = PaymentController()
    studentProtected.post("payment-intent",        use: paymentController.createPaymentIntent)
    studentProtected.post("create-payment-intent", use: paymentController.createPaymentIntent)

    // GET /student/progress
    let progressController = ProgressController()
    studentProtected.get("progress", use: progressController.studentProgress)

    // GET /student/safety-questions
    let safetyController = SafetyQuestionsController()
    studentProtected.get("safety-questions", use: safetyController.studentGetQuestions)

    // GET /student/notes
    let noteController = LessonNoteController()
    studentProtected.get("notes", use: noteController.studentNotes)

    // PATCH /student/documents            — update theory test fields
    // POST  /student/documents/photo      — upload licence photo (multipart)
    // GET   /student/documents/photo      — view own licence photo
    let documentController = DocumentController()
    studentProtected.patch("documents", use: documentController.updateDocuments)
    studentProtected.on(.POST, "documents", "photo", body: .collect(maxSize: "10mb"), use: documentController.uploadPhoto)
    studentProtected.get("documents", "photo", use: documentController.getOwnPhoto)

    // POST /student/profile/photo         — upload profile photo (multipart)
    // GET  /student/profile/photo         — view own profile photo
    studentProtected.on(.POST, "profile", "photo", body: .collect(maxSize: "10mb"), use: documentController.uploadProfilePhoto)
    studentProtected.get("profile", "photo", use: documentController.getOwnProfilePhoto)

    // PUT /student/profile/avatar-emoji — sets an emoji as an alternative to a photo avatar
    studentProtected.put("profile", "avatar-emoji", use: documentController.setAvatarEmoji)
    // DELETE /student/profile/avatar — clears any saved photo/emoji, reverting to initials
    studentProtected.delete("profile", "avatar", use: documentController.removeAvatar)

    // POST /student/register-fcm-token — stores the device push token for later use
    studentProtected.post("register-fcm-token") { req async throws -> HTTPStatus in
        struct FCMTokenBody: Content { let fcmToken: String }
        let student = try req.auth.require(User.self)
        let body    = try req.content.decode(FCMTokenBody.self)
        student.fcmToken = body.fcmToken
        try await student.save(on: req.db)
        return .ok
    }

    studentProtected.get("recovery-notifications") { req async throws -> [RecoveryNotificationView] in
        let user = try req.auth.require(User.self)
        let username = user.username

        let all = try await RecoveryNotification.query(on: req.db)
            .filter(\.$seenAt == nil)
            .sort(\.$createdAt, .descending)
            .limit(50)
            .all()

        return all
            .filter { notification in
                notification.clients.contains { normalizedStudentUsername(from: $0) == username }
            }
            .map {
                RecoveryNotificationView(
                    id: $0.id,
                    clients: $0.clients,
                    message: $0.message,
                    createdAt: $0.createdAt,
                    seenAt: $0.seenAt
                )
            }
    }

    studentProtected.post("recovery-notifications", "seen") { req async throws -> HTTPStatus in
        let user = try req.auth.require(User.self)
        let username = user.username
        let payload = try req.content.decode(MarkRecoveryNotificationsSeenRequest.self)

        guard payload.ids.isEmpty == false else { return .ok }

        let notifications = try await RecoveryNotification.query(on: req.db)
            .filter(\.$id ~~ payload.ids)
            .filter(\.$seenAt == nil)
            .all()

        for notification in notifications {
            let matchesUser = notification.clients.contains {
                normalizedStudentUsername(from: $0) == username
            }
            guard matchesUser else { continue }

            notification.seenAt = Date()
            try await notification.update(on: req.db)
        }

        return .ok
    }

    let finance = FinanceController()
    let financeProtected = app.grouped(SessionTokenAuthenticator(), User.guardMiddleware())

    // POST /instructor/register-fcm-token — stores the instructor's FCM device token
    financeProtected.post("instructor", "register-fcm-token") { req async throws -> HTTPStatus in
        struct FCMTokenBody: Content { let fcmToken: String }
        let instructor = try req.auth.require(User.self)
        let body       = try req.content.decode(FCMTokenBody.self)
        instructor.fcmToken = body.fcmToken
        try await instructor.save(on: req.db)
        return .ok
    }

    // GET  /instructor/settings/test-rules
    // PATCH /instructor/settings/test-rules
    struct TestRulesDTO: Content {
        var autoRejectClash: Bool
        var minWeeksEnabled: Bool
        var minWeeks: Int
    }
    financeProtected.get("instructor", "settings", "test-rules") { req async throws -> TestRulesDTO in
        let instructor = try req.auth.require(User.self)
        return TestRulesDTO(
            autoRejectClash: instructor.testAutoRejectClash,
            minWeeksEnabled: instructor.testMinWeeksEnabled,
            minWeeks:        instructor.testMinWeeks
        )
    }
    financeProtected.patch("instructor", "settings", "test-rules") { req async throws -> TestRulesDTO in
        struct Input: Content { var autoRejectClash: Bool?; var minWeeksEnabled: Bool?; var minWeeks: Int? }
        let instructor = try req.auth.require(User.self)
        let body = try req.content.decode(Input.self)
        if let v = body.autoRejectClash { instructor.testAutoRejectClash = v }
        if let v = body.minWeeksEnabled { instructor.testMinWeeksEnabled = v }
        if let v = body.minWeeks, v >= 1  { instructor.testMinWeeks = v }
        try await instructor.save(on: req.db)
        return TestRulesDTO(
            autoRejectClash: instructor.testAutoRejectClash,
            minWeeksEnabled: instructor.testMinWeeksEnabled,
            minWeeks:        instructor.testMinWeeks
        )
    }

    financeProtected.post("notifications", "recovery") { req async throws -> [String: Int] in
        let payload = try req.content.decode(RecoveryNotificationRequest.self)

        let record = RecoveryNotification(
            clients: payload.clients,
            message: payload.message
        )
        try await record.save(on: req.db)

        let lessonLabel = payload.lessonID?.uuidString ?? "none"
        let stageLabel = payload.stage ?? "unknown"
        req.logger.info("Recovery notification request lesson=\(lessonLabel) stage=\(stageLabel) requested=\(payload.clients.count) clients=\(payload.clients.joined(separator: ", "))")

        var body: [String: Any] = [
            "id": record.id?.uuidString as Any,
            "type": "recovery_notification",
            "message": payload.message,
            "clients": payload.clients,
            "stage": stageLabel
        ]

        if let lessonID = payload.lessonID {
            body["lessonID"] = lessonID.uuidString
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode recovery notification payload")
        }

        var delivered = 0
        let requested = payload.clients.count

        for raw in payload.clients {
            let normalized = normalizedStudentUsername(from: raw)
            var user = try await User.query(on: req.db)
                .filter(\.$username == normalized)
                .first()
            if user == nil {
                // Fall back to exact email match (for dev/test use)
                let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                user = try await User.query(on: req.db)
                    .filter(\.$username == email)
                    .first()
            }
            if let user, let studentID = try? user.requireID() {
                if broadcastStudentText(text, req.application, studentID) {
                    delivered += 1
                }
            } else {
                req.logger.warning("Recovery notification target not found for: \(raw) (normalized: \(normalized))")
            }
        }

        req.logger.info("Recovery notification delivered lesson=\(lessonLabel) stage=\(stageLabel) requested=\(requested) delivered=\(delivered)")

        if let lessonID = payload.lessonID {
            let event = RecoveryEvent(
                lessonID: lessonID,
                stage: payload.stage ?? "unknown",
                result: delivered > 0 ? "live_delivered" : "queued_no_live_delivery",
                clientCount: requested
            )
            try? await event.save(on: req.db)
        }

        return [
            "requested": requested,
            "delivered": delivered
        ]
    }

    // POST /admin/restore-booking/:bookingID — un-cancels a system_auto_cancel booking
    financeProtected.post("admin", "restore-booking", ":bookingID") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == bookingID)
            .with(\.$lesson)
            .first()
        else { throw Abort(.notFound, reason: "Booking not found") }

        let studentID = booking.$user.id
        let lessonID  = booking.$lesson.id

        // Un-soft-delete the booking.
        booking.deletedAt        = nil
        booking.cancellationType = nil
        booking.cancellationSource = nil
        booking.paymentStatus    = "pending"
        try await booking.restore(on: req.db)
        try await booking.save(on: req.db)

        // Restore lesson to booked state.
        let lesson = booking.lesson
        lesson.state = "booked"
        try await lesson.save(on: req.db)

        // Void any late_cancellation_charge entries for this lesson/student.
        let charges = try await LedgerEntry.query(on: req.db)
            .filter(\.$type == "late_cancellation_charge")
            .filter(\.$lesson.$id == lessonID)
            .all()
        for charge in charges {
            if charge.$student.id == studentID {
                charge.voidedAt    = Date()
                charge.voidReason  = "Restored by instructor — incorrect auto-cancel"
                try await charge.save(on: req.db)
            }
        }

        // Clear account hold if it was set by this cancellation.
        if let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first(), profile.accountHold == true {
            profile.accountHold       = false
            profile.accountHoldReason = nil
            try await profile.save(on: req.db)
        }

        req.logger.notice("[Admin] Booking \(bookingID) restored by \(instructor.username)")

        // Found via audit: this route never broadcast anything, yet both instructor
        // clients already had dead code expecting a "restored"/"booking_restored"
        // message. Reuses broadcastBooked's "booked" semantics since that's exactly
        // the lesson's resulting state.
        if let student = try await User.find(studentID, on: req.db) {
            try req.broadcastBooked(for: lesson, student: student)
        }
        return .ok
    }

    // POST /admin/clear-late-cancel/:bookingID — clears cancellationType on a soft-deleted duplicate
    // without un-deleting it. Use when a booking can't be fully restored due to a unique constraint
    // (e.g., a duplicate auto-cancel record that should just be scrubbed quietly).
    // Requires FluentSQL import so req.db as? SQLDatabase resolves the correct conformance.
    financeProtected.post("admin", "clear-late-cancel", ":bookingID") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        guard try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == bookingID)
            .count() > 0
        else { throw Abort(.notFound, reason: "Booking not found") }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "DB is not SQLDatabase")
        }
        try await sql.raw(
            "UPDATE bookings SET cancellation_type = NULL, cancellation_source = NULL WHERE id = \(bind: bookingID)"
        ).run()

        req.logger.notice("[Admin] Cleared late-cancel flag on booking \(bookingID) by \(instructor.username)")
        return .ok
    }

    // GET /instructor/settings — current pricing defaults + contact/vehicle details
    financeProtected.get("instructor", "settings") { req async throws -> InstructorSettingsView in
        let settings = try await InstructorSettings.current(on: req.db)
        return InstructorSettingsView(settings)
    }

    // PATCH /instructor/settings — updates the default hourly rate stamped onto new
    // students at registration. Never touches any existing StudentProfile.hourlyRatePence
    // — each student's rate is its own independent field, so changing this is exactly
    // "raise the price for new clients only" with existing clients kept on their legacy rate.
    // Also accepts the contact/vehicle fields surfaced on the student "Your instructor"
    // screen — all optional, a field omitted (nil) leaves the existing stored value
    // untouched rather than clearing it, so a partial save never wipes other fields.
    financeProtected.patch("instructor", "settings") { req async throws -> InstructorSettingsView in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable {
            let currentHourlyRatePence: Int?
            let contactPhone: String?
            let vehicleRegistration: String?
            let vehicleMake: String?
            let vehicleModel: String?
            let vehicleColour: String?
        }
        let input = try req.content.decode(Input.self)

        let settings = try await InstructorSettings.current(on: req.db)
        if let rate = input.currentHourlyRatePence {
            guard rate > 0 else {
                throw Abort(.badRequest, reason: "Hourly rate must be greater than zero")
            }
            settings.currentHourlyRatePence = rate
        }
        if let v = input.contactPhone { settings.contactPhone = v }
        if let v = input.vehicleRegistration { settings.vehicleRegistration = v }
        if let v = input.vehicleMake { settings.vehicleMake = v }
        if let v = input.vehicleModel { settings.vehicleModel = v }
        if let v = input.vehicleColour { settings.vehicleColour = v }
        try await settings.save(on: req.db)

        req.logger.notice("[Settings] Updated by \(instructor.username)")
        return InstructorSettingsView(settings)
    }

    // GET /student/instructor-info — "Your instructor" screen: name, phone, vehicle
    // details. All instructor-entered via PATCH /instructor/settings above.
    studentProtected.get("instructor-info") { req async throws -> InstructorContactView in
        let settings = try await InstructorSettings.current(on: req.db)
        let instructorUser = try await User.query(on: req.db)
            .filter(\.$role == "instructor")
            .first()
        return InstructorContactView(
            instructorName: instructorUser?.displayName ?? "Your instructor",
            contactPhone: settings.contactPhone,
            vehicleRegistration: settings.vehicleRegistration,
            vehicleMake: settings.vehicleMake,
            vehicleModel: settings.vehicleModel,
            vehicleColour: settings.vehicleColour
        )
    }

    // MARK: - Live instructor location tracking
    //
    // Single-instructor system, so these routes resolve "the active session" without
    // needing a session ID in the URL — same simplification used by InstructorSettings
    // as a singleton elsewhere in this file. TrackingSchedulerLifecycle (TrackingService.swift)
    // creates sessions automatically; these routes only handle pings, manual end, and reads.

    func currentActiveTrackingSession(on db: Database) async throws -> TrackingSession? {
        try await TrackingSession.query(on: db)
            .filter(\.$endedAt == .null)
            .sort(\.$startedAt, .descending)
            .first()
    }

    struct TrackingLocationInput: Decodable {
        let latitude: Double
        let longitude: Double
    }

    // POST /instructor/tracking/location — a location ping from the instructor's phone.
    financeProtected.post("instructor", "tracking", "location") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        let input = try req.content.decode(TrackingLocationInput.self)

        guard let session = try await currentActiveTrackingSession(on: req.db) else {
            return .noContent
        }
        session.lastLatitude = input.latitude
        session.lastLongitude = input.longitude
        session.lastUpdatedAt = Date()
        try await session.save(on: req.db)

        if let booking = try? await Booking.find(session.bookingID, on: req.db) {
            req.application.deliverLocationToStudent(
                studentID: booking.$user.id,
                latitude: input.latitude,
                longitude: input.longitude,
                updatedAt: session.lastUpdatedAt ?? Date()
            )
        }
        return .ok
    }

    // POST /instructor/tracking/end — instructor manually ends the active session early.
    financeProtected.post("instructor", "tracking", "end") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let session = try await currentActiveTrackingSession(on: req.db) else {
            return .noContent
        }
        session.endedAt = Date()
        session.endedReason = "manual"
        try await session.save(on: req.db)

        if let booking = try? await Booking.find(session.bookingID, on: req.db) {
            req.application.deliverTrackingEndedToStudent(studentID: booking.$user.id)
        }
        req.logger.notice("[Tracking] Session manually ended bookingID=\(session.bookingID) by \(instructor.username)")
        return .ok
    }

    // GET /instructor/tracking/active — for the instructor app's "Sharing with [name] · End" banner.
    // Returns 204 (no body) rather than null/an error when nothing's active — Vapor's
    // route-closure type inference doesn't play well with an Optional<Content> return type.
    financeProtected.get("instructor", "tracking", "active") { req async throws -> Response in
        guard let session = try await currentActiveTrackingSession(on: req.db),
              let booking = try await Booking.find(session.bookingID, on: req.db)
        else { return Response(status: .noContent) }
        let student = try await booking.$user.get(on: req.db)
        let view = InstructorTrackingView(
            bookingID: session.bookingID,
            studentName: student.displayName,
            startedAt: session.startedAt,
            endsAt: session.endsAt,
            pickupLatitude: booking.pickupLatitude,
            pickupLongitude: booking.pickupLongitude,
            dropoffLatitude: booking.dropoffLatitude,
            dropoffLongitude: booking.dropoffLongitude
        )
        return try await view.encodeResponse(for: req)
    }

    // GET /student/tracking/active — for the "Your instructor" tab's entry point and the
    // live map screen's initial load (before the first WS push arrives). The number of
    // concurrently-active sessions is tiny (single instructor), so this just loads each
    // active session's booking and matches on student rather than joining in SQL.
    studentProtected.get("tracking", "active") { req async throws -> Response in
        let user = try req.auth.require(User.self)
        let studentID = try user.requireID()

        let activeSessions = try await TrackingSession.query(on: req.db)
            .filter(\.$endedAt == .null)
            .sort(\.$startedAt, .descending)
            .all()

        for session in activeSessions {
            guard let booking = try await Booking.find(session.bookingID, on: req.db),
                  booking.$user.id == studentID
            else { continue }
            let view = StudentTrackingView(
                bookingID: session.bookingID,
                startedAt: session.startedAt,
                endsAt: session.endsAt,
                pickupLatitude: booking.pickupLatitude,
                pickupLongitude: booking.pickupLongitude,
                latitude: session.lastLatitude,
                longitude: session.lastLongitude,
                updatedAt: session.lastUpdatedAt
            )
            return try await view.encodeResponse(for: req)
        }
        return Response(status: .noContent)
    }

    // MARK: - Lesson journey tracking
    //
    // Separate from live-location above — this records the instructor's full GPS route
    // for an entire lesson (pickup to drop-off), for later map review. Unlike
    // TrackingSession, there's no server-side "in progress" state: the instructor app's
    // JourneyTrackingManager detects arrival/departure geofences and buffers points
    // entirely client-side, then uploads the whole finished route as one batch here.

    struct JourneyPointInput: Decodable {
        let latitude: Double
        let longitude: Double
        let timestamp: Date
        let speedMph: Double?
    }

    struct LessonJourneyUploadInput: Decodable {
        let bookingID: UUID
        let startedAt: Date
        let endedAt: Date
        let endedReason: String
        let points: [JourneyPointInput]
    }

    /// Great-circle distance in metres between two coordinates.
    func haversineMetres(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Sums consecutive point-to-point distance (not a straight line start-to-end).
    func routeDistanceMiles(_ points: [JourneyPointInput]) -> Double {
        guard points.count > 1 else { return 0 }
        var metres = 0.0
        for i in 1..<points.count {
            metres += haversineMetres(
                (points[i - 1].latitude, points[i - 1].longitude),
                (points[i].latitude, points[i].longitude)
            )
        }
        return metres / 1609.344
    }

    /// Detects runs of points that stay within ~30m of each other for 5+ minutes —
    /// purely informational, doesn't split the route. A simple single-pass clustering,
    /// not a precise stop detector; good enough for "where did we pause to talk."
    func detectStopMarkers(_ points: [JourneyPointInput]) -> [StopMarker] {
        guard points.count > 1 else { return [] }
        let stopRadiusMetres = 30.0
        let minStopDuration: TimeInterval = 5 * 60
        var markers: [StopMarker] = []
        var clusterStart = 0

        for i in 1..<points.count {
            let distanceFromClusterStart = haversineMetres(
                (points[clusterStart].latitude, points[clusterStart].longitude),
                (points[i].latitude, points[i].longitude)
            )
            if distanceFromClusterStart > stopRadiusMetres {
                let arrived = points[clusterStart].timestamp
                let departed = points[i - 1].timestamp
                if departed.timeIntervalSince(arrived) >= minStopDuration {
                    markers.append(StopMarker(
                        latitude: points[clusterStart].latitude,
                        longitude: points[clusterStart].longitude,
                        arrivedAt: arrived,
                        departedAt: departed,
                        durationMinutes: Int(departed.timeIntervalSince(arrived) / 60)
                    ))
                }
                clusterStart = i
            }
        }
        return markers
    }

    /// Highest valid GPS speed sample in the route, 0 if none were valid.
    func topSpeedMph(_ points: [JourneyPointInput]) -> Double {
        points.compactMap { $0.speedMph }.max() ?? 0
    }

    /// True trip average (distance / duration), not a mean of noisy instantaneous
    /// GPS samples — those are sampled unevenly (more often at speed, almost never
    /// while stationary) and would skew a simple average.
    func averageSpeedMph(distanceMiles: Double, durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return distanceMiles / (durationSeconds / 3600)
    }

    /// Detects sudden GPS speed changes between consecutive points — a GPS-only
    /// heuristic (not accelerometer-fused), so treat results as approximate; thresholds
    /// below are hand-picked starting points, not calibrated against real driving data.
    /// Skips pairs with no valid speed on either side, or whose timestamp gap is too
    /// small (noise) or too large (sparse samples, e.g. across a stop) to mean anything.
    func detectDrivingEvents(_ points: [JourneyPointInput]) -> [DrivingEvent] {
        guard points.count > 1 else { return [] }
        let hardBrakeThreshold = -6.0   // mph per second, deceleration
        let rapidAccelThreshold = 5.0   // mph per second, acceleration
        let minDt = 0.5
        let maxDt = 8.0

        var events: [DrivingEvent] = []
        for i in 1..<points.count {
            guard let fromSpeed = points[i - 1].speedMph, let toSpeed = points[i].speedMph else { continue }
            let dt = points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
            guard dt >= minDt, dt <= maxDt else { continue }

            let mphPerSecond = (toSpeed - fromSpeed) / dt
            let type: String?
            if mphPerSecond <= hardBrakeThreshold {
                type = "hardBrake"
            } else if mphPerSecond >= rapidAccelThreshold {
                type = "rapidAccel"
            } else {
                type = nil
            }
            if let type {
                events.append(DrivingEvent(
                    type: type,
                    latitude: points[i].latitude,
                    longitude: points[i].longitude,
                    timestamp: points[i].timestamp,
                    fromMph: fromSpeed,
                    toMph: toSpeed,
                    deltaMph: toSpeed - fromSpeed
                ))
            }
        }
        return events
    }

    // POST /instructor/tracking/journey — one-shot batch upload of a completed route,
    // sent once JourneyTrackingManager finalizes (geofence reached, manual end, or the
    // 45-minute overrun safety net — all decided client-side, see the instructor app).
    financeProtected.post("instructor", "tracking", "journey") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        let input = try req.content.decode(LessonJourneyUploadInput.self)

        let distanceMiles = routeDistanceMiles(input.points)
        let durationSeconds = input.endedAt.timeIntervalSince(input.startedAt)

        let journey = LessonJourney(
            bookingID: input.bookingID,
            startedAt: input.startedAt,
            endedAt: input.endedAt,
            endedReason: input.endedReason,
            points: input.points.map {
                RoutePoint(latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.timestamp, speedMph: $0.speedMph)
            },
            distanceMiles: distanceMiles,
            stopMarkers: detectStopMarkers(input.points),
            topSpeedMph: topSpeedMph(input.points),
            averageSpeedMph: averageSpeedMph(distanceMiles: distanceMiles, durationSeconds: durationSeconds),
            drivingEvents: detectDrivingEvents(input.points)
        )
        try await journey.save(on: req.db)
        req.logger.notice("[Journey] Saved bookingID=\(input.bookingID) points=\(input.points.count) reason=\(input.endedReason)")
        return .created
    }

    // GET /instructor/bookings/:bookingID/journey — for the "View Journey" map screen.
    financeProtected.get("instructor", "bookings", ":bookingID", "journey") { req async throws -> Response in
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard let journey = try await LessonJourney.query(on: req.db)
            .filter(\.$bookingID == bookingID)
            .first()
        else { return Response(status: .noContent) }
        return try await journey.encodeResponse(for: req)
    }

    // POST /instructor/lessons/:lessonID/discount — applies a one-off, instructor's-
    // discretion discount to a single lesson, as an absolute amount off that lesson's
    // undiscounted (hourlyRateSnapshot × duration) price. Reducing priceSnapshot directly
    // means every existing consumer (payment, late-cancellation charge, confirmed-lesson
    // billing, business finance "earned" totals) picks it up automatically — none of them
    // need to know a discount exists, they already just read priceSnapshot.
    financeProtected.post("instructor", "lessons", ":lessonID", "discount") { req async throws -> LessonDiscountView in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing lessonID")
        }

        struct Input: Decodable { let amount: Decimal; let reason: String? }
        let input = try req.content.decode(Input.self)
        guard input.amount > 0 else {
            throw Abort(.badRequest, reason: "Discount amount must be greater than zero")
        }

        guard let finance = try await LessonFinance.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "No finance record for this lesson — is a student actually booked on it?")
        }
        guard finance.chargeStatus == "not_charged" else {
            throw Abort(.conflict, reason: "This lesson has already been charged — its price can't be changed retroactively.")
        }

        let fullPrice = LessonFinance.calculatedPrice(durationMinutes: finance.durationMinutes, hourlyRate: finance.hourlyRateSnapshot)
        guard input.amount <= fullPrice else {
            throw Abort(.badRequest, reason: "Discount can't exceed the lesson's full price")
        }

        finance.discountAmount = input.amount
        finance.discountReason = input.reason
        finance.priceSnapshot = fullPrice - input.amount
        try await finance.save(on: req.db)

        req.logger.notice("[Discount] Applied \(input.amount) discount to lesson \(lessonID) by \(instructor.username)")
        return LessonDiscountView(
            lessonID: lessonID,
            priceSnapshot: finance.priceSnapshot,
            discountAmount: finance.discountAmount,
            discountReason: finance.discountReason
        )
    }

    // DELETE /instructor/lessons/:lessonID/discount — clears a previously-applied discount,
    // restoring the lesson's full undiscounted price.
    financeProtected.delete("instructor", "lessons", ":lessonID", "discount") { req async throws -> LessonDiscountView in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing lessonID")
        }

        guard let finance = try await LessonFinance.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "No finance record for this lesson")
        }
        guard finance.chargeStatus == "not_charged" else {
            throw Abort(.conflict, reason: "This lesson has already been charged — its price can't be changed retroactively.")
        }

        let fullPrice = LessonFinance.calculatedPrice(durationMinutes: finance.durationMinutes, hourlyRate: finance.hourlyRateSnapshot)
        finance.discountAmount = nil
        finance.discountReason = nil
        finance.priceSnapshot = fullPrice
        try await finance.save(on: req.db)

        req.logger.notice("[Discount] Cleared discount on lesson \(lessonID) by \(instructor.username)")
        return LessonDiscountView(
            lessonID: lessonID,
            priceSnapshot: finance.priceSnapshot,
            discountAmount: nil,
            discountReason: nil
        )
    }

    // POST /admin/undo-confirm/:bookingID — deletes the ConfirmedLesson, its auto-charge
    // LedgerEntry, and resets LessonFinance back to charge_pending. Use when a lesson
    // was accidentally marked as attended before it actually happened.
    financeProtected.post("admin", "undo-confirm", ":bookingID") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found")
        }
        let lessonID = booking.$lesson.id
        let userID   = booking.$user.id

        // 1. Delete the ConfirmedLesson record
        if let cl = try await ConfirmedLesson.query(on: req.db)
            .filter(\.$booking.$id == bookingID)
            .first()
        {
            try await cl.delete(on: req.db)
        }

        // 2. Delete the auto-created lesson_charge LedgerEntry for this lesson/student
        if let sql = req.db as? SQLDatabase {
            try await sql.raw(
                "DELETE FROM ledger_entries WHERE lesson_id = \(bind: lessonID) AND student_id = \(bind: userID) AND type = 'lesson_charge'"
            ).run()
        }

        // 3. Reset LessonFinance so it can be charged again when the lesson actually happens
        if let lf = try await LessonFinance.find(lessonID, on: req.db) {
            lf.chargeStatus    = "not_charged"
            lf.financeStatus   = "charge_pending"
            lf.coveredAt       = nil
            lf.$chargedLedgerEntry.id = nil
            try await lf.save(on: req.db)
        }

        req.logger.notice("[Admin] Undid confirmed lesson for booking \(bookingID) by \(instructor.username)")
        return .ok
    }

    // POST /admin/users/update-email — corrects a typo'd email on an existing account. Updates
    // both User.username (the login) and StudentProfile.email (if a profile exists) together so
    // they never drift out of sync. Refuses if the new email is already taken by another account.
    financeProtected.post("admin", "users", "update-email") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let oldEmail: String; let newEmail: String }
        let input = try req.content.decode(Input.self)
        let oldEmail = input.oldEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let newEmail = input.newEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newEmail.isEmpty, newEmail.contains("@") else {
            throw Abort(.unprocessableEntity, reason: "Please provide a valid new email address.")
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == oldEmail)
            .first()
        else { throw Abort(.notFound, reason: "No account found for that email") }

        guard try await User.query(on: req.db).filter(\.$username == newEmail).count() == 0
        else { throw Abort(.conflict, reason: "An account with the new email already exists.") }

        let userID = try user.requireID()

        user.username = newEmail
        try await user.save(on: req.db)

        if let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() {
            profile.email = newEmail
            try await profile.save(on: req.db)
        }

        req.logger.notice("[Admin] Updated email '\(oldEmail)' -> '\(newEmail)' by \(instructor.username)")
        return .ok
    }

    // POST /admin/users/update-name — corrects a typo'd first/last name on an existing
    // account. Updates both User and StudentProfile (if one exists) together.
    financeProtected.post("admin", "users", "update-name") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let email: String; let firstName: String?; let lastName: String? }
        let input = try req.content.decode(Input.self)
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == email)
            .first()
        else { throw Abort(.notFound, reason: "No account found for that email") }

        let userID = try user.requireID()

        if let firstName = input.firstName { user.firstName = firstName }
        if let lastName = input.lastName { user.lastName = lastName }
        try await user.save(on: req.db)

        if let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() {
            if let firstName = input.firstName { profile.firstName = firstName }
            if let lastName = input.lastName { profile.lastName = lastName }
            try await profile.save(on: req.db)
        }

        req.logger.notice("[Admin] Updated name for '\(email)' by \(instructor.username)")
        return .ok
    }

    // POST /admin/users/delete-orphan — deletes a bare User account (no attached StudentProfile).
    // Use when a client account was created (e.g. via /admin/users) but never completed proper
    // registration, leaving an orphaned login that blocks /auth/register with "already exists"
    // and can't be approved via the normal pending-student flow. Refuses to touch any account
    // that actually has a StudentProfile, to avoid ever deleting a real client by mistake.
    financeProtected.post("admin", "users", "delete-orphan") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let email: String }
        let input = try req.content.decode(Input.self)
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == email)
            .first()
        else { throw Abort(.notFound, reason: "No account found for that email") }

        let userID = try user.requireID()

        guard try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .count() == 0
        else { throw Abort(.conflict, reason: "This account has a StudentProfile attached — refusing to delete a real client.") }

        try await SessionToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await PasswordResetToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await user.delete(on: req.db)

        req.logger.notice("[Admin] Deleted orphaned account '\(email)' by \(instructor.username)")
        return .ok
    }

    // POST /admin/users/delete-rejected — fully deletes a student account that was registered and
    // then explicitly rejected via POST /instructor/students/:studentID/reject. Unlike delete-orphan
    // (which only handles bare Users with no StudentProfile), this cascades through every
    // StudentProfile-linked table so throwaway/rejected registrations can be purged completely.
    // Refuses unless approvalStatus == "rejected", and refuses if any real financial history
    // (LedgerEntry or ConfirmedLesson) exists for the account, to avoid ever deleting a real
    // client or real money records by mistake.
    financeProtected.post("admin", "users", "delete-rejected") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let email: String }
        let input = try req.content.decode(Input.self)
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == email)
            .first()
        else { throw Abort(.notFound, reason: "No account found for that email") }

        let userID = try user.requireID()

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else { throw Abort(.conflict, reason: "This account has no StudentProfile — use delete-orphan instead.") }

        guard profile.approvalStatus == "rejected" else {
            throw Abort(.conflict, reason: "This account's approvalStatus is '\(profile.approvalStatus)', not 'rejected' — refusing to delete.")
        }

        guard try await LedgerEntry.query(on: req.db).filter(\.$student.$id == userID).count() == 0,
              try await ConfirmedLesson.query(on: req.db).filter(\.$user.$id == userID).count() == 0
        else { throw Abort(.conflict, reason: "This account has real financial history — refusing to delete.") }

        try await Booking.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await TestAppointment.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await StudentSafetyProgress.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await StudentProgress.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await StudentStatusEvent.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await LessonFinance.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await SessionToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await PasswordResetToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await profile.delete(on: req.db)
        try await user.delete(on: req.db)

        req.logger.notice("[Admin] Deleted rejected account '\(email)' by \(instructor.username)")
        return .ok
    }

    // POST /admin/users/delete-confirmed — force-deletes a student account regardless of its
    // approvalStatus, for leftover/test registrations the instructor has explicitly confirmed
    // (out-of-band) are not real clients. Requires `confirm: true` as a deliberate extra step
    // and still refuses if any real financial history (LedgerEntry or ConfirmedLesson) exists,
    // so even an explicit confirm can't destroy real money records.
    financeProtected.post("admin", "users", "delete-confirmed") { req async throws -> HTTPStatus in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let email: String; let confirm: Bool }
        let input = try req.content.decode(Input.self)
        guard input.confirm else {
            throw Abort(.badRequest, reason: "Must set confirm: true to force-delete this account.")
        }
        let email = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == email)
            .first()
        else { throw Abort(.notFound, reason: "No account found for that email") }

        let userID = try user.requireID()

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else { throw Abort(.conflict, reason: "This account has no StudentProfile — use delete-orphan instead.") }

        guard try await LedgerEntry.query(on: req.db).filter(\.$student.$id == userID).filter(\.$voidedAt == nil).count() == 0,
              try await ConfirmedLesson.query(on: req.db).filter(\.$user.$id == userID).count() == 0
        else { throw Abort(.conflict, reason: "This account has real (non-voided) financial history — refusing to delete.") }

        try await LedgerEntry.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await Booking.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await TestAppointment.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await StudentSafetyProgress.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await StudentProgress.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await StudentStatusEvent.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await LessonFinance.query(on: req.db).filter(\.$student.$id == userID).delete()
        try await SessionToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await PasswordResetToken.query(on: req.db).filter(\.$user.$id == userID).delete()
        try await profile.delete(on: req.db)
        try await user.delete(on: req.db)

        req.logger.notice("[Admin] Force-deleted confirmed-leftover account '\(email)' by \(instructor.username)")
        return .ok
    }

    struct NotifyResult: Content {
        var sent: Int
        var total: Int
    }

    // POST /admin/notify-all-students — ad-hoc broadcast push (custom title/body) to every
    // student with a registered FCM token. Fire-and-forget per recipient — one failed/missing
    // token never blocks the rest. Driven from the instructor app's "+" quick-actions composer.
    financeProtected.post("admin", "notify-all-students") { req async throws -> NotifyResult in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let title: String; let body: String }
        let input = try req.content.decode(Input.self)
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Abort(.badRequest, reason: "Title and body are required") }

        let students = try await User.query(on: req.db)
            .filter(\.$role == "student")
            .all()

        var sent = 0
        if let fcm = FCMNotificationService(req: req) {
            for student in students {
                guard let token = student.fcmToken else { continue }
                do {
                    try await fcm.send(to: token, title: input.title, body: input.body)
                    sent += 1
                } catch {
                    req.logger.error("[notify-all-students] send failed for \(student.username): \(error)")
                }
            }
        }

        req.logger.notice("[Admin] Broadcast notification sent to \(sent)/\(students.count) students by \(instructor.username)")
        return NotifyResult(sent: sent, total: students.count)
    }

    // POST /admin/notify-instructor — lets a client app push an arbitrary title/body to the
    // instructor's own device. Used for "heads up" events detected client-side (e.g. the
    // Instructor app auto-restoring an archived client to Students) that the server itself
    // has no way to observe, since the triggering state (local Contacts.app archive reason)
    // only exists on the instructor's Mac.
    financeProtected.post("admin", "notify-instructor") { req async throws -> HTTPStatus in
        let caller = try req.auth.require(User.self)
        guard caller.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let title: String; let body: String }
        let input = try req.content.decode(Input.self)
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Abort(.badRequest, reason: "Title and body are required") }

        guard let instructor = try await User.query(on: req.db)
            .filter(\.$role == "instructor")
            .first(),
            let token = instructor.fcmToken,
            let fcm = FCMNotificationService(req: req)
        else { return .ok }

        try? await fcm.send(to: token, title: input.title, body: input.body)
        return .ok
    }

    // POST /admin/users/check — bulk, read-only lookup of account status by email. Used to audit
    // whether client-side "add contact" entries (which never touch the server) have a matching
    // real server account. Never creates or modifies anything.
    financeProtected.post("admin", "users", "check") { req async throws -> [AdminUserCheckResult] in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        struct Input: Decodable { let emails: [String] }
        let input = try req.content.decode(Input.self)
        let emails = input.emails.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

        let users = try await User.query(on: req.db)
            .filter(\.$username ~~ emails)
            .all()
        let userByEmail = Dictionary(uniqueKeysWithValues: users.map { ($0.username, $0) })

        let userIDs = users.compactMap { $0.id }
        let profiles = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id ~~ userIDs)
            .all()
        let profileByUserID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.$user.id, $0) })

        return emails.map { email in
            guard let user = userByEmail[email], let userID = user.id else {
                return AdminUserCheckResult(email: email, accountExists: false, hasProfile: false, approvalStatus: nil)
            }
            let profile = profileByUserID[userID]
            return AdminUserCheckResult(
                email: email,
                accountExists: true,
                hasProfile: profile != nil,
                approvalStatus: profile?.approvalStatus
            )
        }
    }

    // GET /admin/users?role=student — bulk, read-only listing of every account for a role
    // (defaults to "student"). Server-only utility, not called from any app UI — added to let
    // the instructor pull a full email roster in one shot instead of checking one at a time.
    financeProtected.get("admin", "users") { req async throws -> [AdminUserListRow] in
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }

        let role = (try? req.query.get(String.self, at: "role")) ?? "student"

        let users = try await User.query(on: req.db)
            .filter(\.$role == role)
            .sort(\.$username)
            .all()

        let userIDs = users.compactMap { $0.id }
        let profiles = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id ~~ userIDs)
            .all()
        let profileByUserID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.$user.id, $0) })

        return try users.map { user in
            let id = try user.requireID()
            return AdminUserListRow(
                id: id,
                email: user.username,
                firstName: user.firstName,
                lastName: user.lastName,
                role: user.role,
                approvalStatus: profileByUserID[id]?.approvalStatus
            )
        }
    }

    financeProtected.post("finance", "payments", use: finance.addPayment)
    financeProtected.get("finance", "expenses", "export", use: finance.exportExpensesCSV)
    financeProtected.get("finance", "ledger", "export", use: finance.exportLedgerCSV)
    financeProtected.post("finance", "lessons", ":lessonID", "charge", use: finance.chargeLesson)
    financeProtected.post("instructor", "lessons", ":lessonID", "apply-late-charge", use: finance.applyLateChargeToLesson)
    financeProtected.get("finance", "students", use: finance.studentBalances)
    financeProtected.get("finance", "students", ":studentID", "transactions", use: finance.studentTransactions)
    financeProtected.get("finance", "students", ":studentID", "outstanding-lessons", use: finance.outstandingLessons)
    financeProtected.get("finance", "business-summary", use: finance.businessSummary)
    financeProtected.get("finance", "business-summary", "monthly-tax", use: finance.monthlyTaxBreakdown)
    financeProtected.get("finance", "business-summary", "tax-trend", use: finance.taxTrend)
    financeProtected.get("instructor", "finance", "week-total", use: finance.weekTotal)
    financeProtected.post("instructor", "ledger", ":entryID", "waive",   use: finance.waiveFee)
    financeProtected.post("instructor", "finance", "ledger", ":entryID", "void",   use: finance.voidEntry)
    financeProtected.post("instructor", "finance", "ledger", ":entryID", "refund", use: finance.refundEntry)

    // GET  /instructor/student/:studentID/progress
    // PATCH /instructor/student/:studentID/progress
    financeProtected.get("instructor",   "student", ":studentID", "progress", use: progressController.instructorGetProgress)
    financeProtected.patch("instructor", "student", ":studentID", "progress", use: progressController.updateProgress)

    // GET   /instructor/student/:studentID/safety-questions
    // PATCH /instructor/student/:studentID/safety-questions/:questionID
    financeProtected.get("instructor",   "student", ":studentID", "safety-questions",              use: safetyController.instructorGetQuestions)
    financeProtected.patch("instructor", "student", ":studentID", "safety-questions", ":questionID", use: safetyController.instructorSetMastered)

    // POST /instructor/student/:studentID/notes
    // GET  /instructor/student/:studentID/notes
    // Public lesson notes (student can see these via GET /student/notes)
    financeProtected.post("instructor",  "student", ":studentID", "notes", use: noteController.createNote)
    financeProtected.get("instructor",   "student", ":studentID", "notes", use: noteController.instructorGetNotes)
    financeProtected.patch("instructor", "notes", ":noteID",      use: noteController.updateNote)
    financeProtected.delete("instructor","notes", ":noteID",      use: noteController.deleteNote)

    // GET  /instructor/student/:studentID/documents       — document status
    // GET  /instructor/student/:studentID/license-photo  — view licence photo
    // POST /instructor/student/:studentID/documents/verify
    financeProtected.get("instructor",  "student", ":studentID", "documents",        use: documentController.instructorGetDocuments)
    financeProtected.get("instructor",  "student", ":studentID", "license-photo",    use: documentController.instructorGetLicencePhoto)
    financeProtected.get("instructor",  "student", ":studentID", "licence-image",    use: documentController.instructorGetLicencePhoto)
    financeProtected.post("instructor", "student", ":studentID", "documents", "verify", use: documentController.verifyLicence)
    financeProtected.post("instructor", "student", ":studentID", "documents", "revoke", use: documentController.revokeLicence)

    // GET /instructor/student/:studentID/profile-photo — view the student's profile photo
    financeProtected.get("instructor", "student", ":studentID", "profile-photo", use: documentController.instructorGetProfilePhoto)
    financeProtected.on(.POST, "instructor", "profile-photo", body: .collect(maxSize: "10mb"), use: documentController.uploadInstructorProfilePhoto)
    // Same handler at both paths — it takes no studentID and the photo isn't sensitive
    // to either auth group, so the instructor app previewing its own upload in Settings
    // reuses the identical GET rather than a near-duplicate self-view variant.
    financeProtected.get("instructor", "profile-photo", use: documentController.getInstructorProfilePhoto)
    studentProtected.get("instructor", "profile-photo", use: documentController.getInstructorProfilePhoto)

    // Vehicle management
    // POST /instructor/vehicle/log
    // GET  /instructor/vehicle/latest-log
    // GET  /instructor/vehicle/logs
    // POST /instructor/vehicle/expenses       (multipart)
    // GET  /instructor/vehicle/expenses       (?year=)
    // GET  /instructor/vehicle/expenses/summary (?year=)
    // GET  /instructor/vehicle/expenses/:expenseID/receipt
    let vehicleController = VehicleController()
    financeProtected.post("instructor", "vehicle", "log",                use: vehicleController.logVehicleStatus)
    financeProtected.get("instructor",  "vehicle", "latest-log",         use: vehicleController.getVehicleStatus)
    financeProtected.get("instructor",  "vehicle", "alerts",             use: vehicleController.getAlerts)
    financeProtected.get("instructor",  "vehicle", "logs",               use: vehicleController.getVehicleLogs)
    financeProtected.on(.POST, "instructor", "vehicle", "expenses",
                        body: .collect(maxSize: "10mb"),                 use: vehicleController.createExpense)
    financeProtected.get("instructor",  "vehicle", "expenses",           use: vehicleController.listExpenses)
    financeProtected.get("instructor",  "vehicle", "expenses", "summary",use: vehicleController.expenseSummary)
    financeProtected.get("instructor",  "vehicle", "expenses", ":expenseID", "receipt", use: vehicleController.getReceipt)
    financeProtected.patch("instructor", "vehicle", "expenses", ":expenseID", use: vehicleController.updateExpense)
    financeProtected.delete("instructor", "vehicle", "expenses", ":expenseID", use: vehicleController.deleteExpense)

    // Vehicle — service history / MOT history / road tax & insurance / insurance claims
    financeProtected.post("instructor",   "vehicle", "services",              use: vehicleController.createServiceRecord)
    financeProtected.get("instructor",    "vehicle", "services",              use: vehicleController.listServiceRecords)
    financeProtected.patch("instructor",  "vehicle", "services", ":serviceID",use: vehicleController.updateServiceRecord)
    financeProtected.delete("instructor", "vehicle", "services", ":serviceID",use: vehicleController.deleteServiceRecord)

    financeProtected.post("instructor",   "vehicle", "mot",                   use: vehicleController.createMOTRecord)
    financeProtected.get("instructor",    "vehicle", "mot",                   use: vehicleController.listMOTRecords)
    financeProtected.patch("instructor",  "vehicle", "mot", ":motID",         use: vehicleController.updateMOTRecord)
    financeProtected.delete("instructor", "vehicle", "mot", ":motID",         use: vehicleController.deleteMOTRecord)

    financeProtected.get("instructor",    "vehicle", "documents",             use: vehicleController.getVehicleDocument)
    financeProtected.put("instructor",    "vehicle", "documents",             use: vehicleController.updateVehicleDocument)

    financeProtected.post("instructor",   "vehicle", "claims",                use: vehicleController.createInsuranceClaim)
    financeProtected.get("instructor",    "vehicle", "claims",                use: vehicleController.listInsuranceClaims)
    financeProtected.patch("instructor",  "vehicle", "claims", ":claimID",    use: vehicleController.updateInsuranceClaim)
    financeProtected.delete("instructor", "vehicle", "claims", ":claimID",    use: vehicleController.deleteInsuranceClaim)

    // Mileage log (HMRC per-trip)
    // GET    /instructor/mileage          — summary + all entries
    // POST   /instructor/mileage          — add entry
    // DELETE /instructor/mileage/:entryID — remove entry
    let mileageController = MileageController()
    financeProtected.get("instructor",    "mileage",            use: mileageController.list)
    financeProtected.post("instructor",   "mileage",            use: mileageController.create)
    financeProtected.delete("instructor", "mileage", ":entryID", use: mileageController.delete)

    // Odometer log (daily odometer readings)
    // GET    /instructor/odometer         — full history + stats
    // GET    /instructor/odometer/last    — most recent entry
    // POST   /instructor/odometer         — log today's reading (date = yesterday)
    // POST   /instructor/odometer/gap     — back-fill missing days
    // DELETE /instructor/odometer/:entryID
    let odometerController = OdometerController()
    financeProtected.get("instructor",    "odometer",              use: odometerController.list)
    financeProtected.get("instructor",    "odometer", "last",      use: odometerController.lastEntry)
    financeProtected.post("instructor",   "odometer",              use: odometerController.logReading)
    financeProtected.post("instructor",   "odometer", "gap",       use: odometerController.logGapEntries)
    financeProtected.delete("instructor", "odometer", ":entryID",  use: odometerController.delete)

    // Fuel log
    // GET    /instructor/fuel          — full history + stats
    // POST   /instructor/fuel          — log a fill-up
    // DELETE /instructor/fuel/:entryID
    // GET    /instructor/fuel/nearby   — nearby petrol stations with live prices
    let fuelController = FuelController()
    financeProtected.get("instructor",    "fuel",              use: fuelController.list)
    financeProtected.post("instructor",   "fuel",              use: fuelController.log)
    financeProtected.patch("instructor",  "fuel", ":entryID",  use: fuelController.update)
    financeProtected.delete("instructor", "fuel", ":entryID",  use: fuelController.delete)

    financeProtected.get("instructor", "fuel", "nearby") { req async throws -> [FuelPriceService.NearbyStation] in
        struct Query: Decodable {
            var lat: Double
            var lng: Double
            var radius: Double?
            var fuelType: String?
        }
        let q = try req.query.decode(Query.self)
        guard let clientID = Environment.get("FUEL_FINDER_CLIENT_ID"),
              let clientSecret = Environment.get("FUEL_FINDER_CLIENT_SECRET"),
              !clientID.isEmpty, !clientSecret.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Fuel Finder credentials not configured")
        }
        return try await FuelPriceService.shared.nearbyStations(
            lat: q.lat,
            lng: q.lng,
            radiusMiles: q.radius ?? 5.0,
            fuelType: q.fuelType ?? "B7_STANDARD",
            clientID: clientID,
            clientSecret: clientSecret,
            client: req.client
        )
    }

    // Fuel Finder raw debug (returns first batch of price rows as raw JSON string)
    financeProtected.get("instructor", "fuel", "raw-debug") { req async throws -> FuelPriceService.RawDebugResponse in
        guard let clientID = Environment.get("FUEL_FINDER_CLIENT_ID"),
              let clientSecret = Environment.get("FUEL_FINDER_CLIENT_SECRET"),
              !clientID.isEmpty, !clientSecret.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Fuel Finder credentials not configured")
        }
        return try await FuelPriceService.shared.rawDebug(
            clientID: clientID, clientSecret: clientSecret, client: req.client
        )
    }

    // Chat
    // GET    /student/chat/messages
    // POST   /student/chat/messages
    // PATCH  /student/chat/messages/read
    // GET    /instructor/chat/students
    // GET    /instructor/chat/student/:studentID/messages
    // POST   /instructor/chat/student/:studentID/messages
    // PATCH  /instructor/chat/student/:studentID/read
    let chatController = ChatController()
    studentProtected.get("chat", "messages",                          use: chatController.studentGetMessages)
    studentProtected.post("chat", "messages",                         use: chatController.studentSendMessage)
    studentProtected.patch("chat", "messages", "read",                use: chatController.studentMarkRead)
    studentProtected.patch("chat", "messages", ":messageID", "read",  use: chatController.studentMarkMessageRead)
    studentProtected.post("chat", "typing",                           use: chatController.studentTyping)
    studentProtected.get("instructor", "presence",                    use: chatController.instructorPresence)
    studentProtected.on(.POST, "chat", "upload-attachment", body: .collect(maxSize: "10mb"), use: chatController.uploadAttachment)
    studentProtected.get("chat", "attachments", ":attachmentID",      use: chatController.serveAttachment)

    // GET /student/tests and POST /student/test-requests are handled by TestAppointmentController
    financeProtected.get("instructor",   "chat", "students",                                           use: chatController.instructorInbox)
    financeProtected.get("instructor",   "chat", "student", ":studentID", "messages",                  use: chatController.instructorGetMessages)
    financeProtected.post("instructor",  "chat", "student", ":studentID", "messages",                  use: chatController.instructorSendMessage)
    financeProtected.patch("instructor", "chat", "student", ":studentID", "read",                      use: chatController.instructorMarkRead)
    financeProtected.patch("instructor", "chat", "student", ":studentID", "unread",                    use: chatController.instructorMarkUnread)
    financeProtected.delete("instructor", "chat", "student", ":studentID", "messages",                 use: chatController.instructorDeleteConversation)
    financeProtected.patch("instructor", "chat", "student", ":studentID", "messages", ":messageID", "read", use: chatController.instructorMarkMessageRead)
    financeProtected.post("instructor",  "chat", "student", ":studentID", "typing",                    use: chatController.instructorTyping)
    financeProtected.get("instructor",   "student", ":studentID", "presence",                          use: chatController.studentPresence)
    financeProtected.on(.POST, "instructor", "chat", "upload-attachment", body: .collect(maxSize: "10mb"), use: chatController.uploadAttachment)
    financeProtected.get("instructor",   "chat", "attachments", ":attachmentID",                       use: chatController.serveAttachment)

    // Private instructor-only notes (no student endpoint — inaccessible to student auth)
    let privateNoteController = PrivateNoteController()
    financeProtected.get("instructor",    "student", ":studentID", "private-notes", use: privateNoteController.getPrivateNotes)
    financeProtected.post("instructor",   "student", ":studentID", "private-notes", use: privateNoteController.createPrivateNote)
    financeProtected.patch("instructor",  "private-notes", ":noteID", use: privateNoteController.updatePrivateNote)
    financeProtected.delete("instructor", "private-notes", ":noteID", use: privateNoteController.deletePrivateNote)

    // Pending student approval (instructor)
    let pendingController = InstructorPendingStudentsController()
    financeProtected.get("instructor",  "students", "pending",              use: pendingController.listPending)
    financeProtected.post("instructor", "students", ":studentID", "approve", use: pendingController.approve)
    financeProtected.post("instructor", "students", ":studentID", "reject",  use: pendingController.reject)
    financeProtected.post("instructor", "students", "create",                use: pendingController.createStudentAccount)

    // Student approval status check + profile completion
    studentProtected.get("status",            use: pendingController.studentStatus)
    studentProtected.post("complete-profile", use: pendingController.completeProfile)
    studentProtected.post("account-status",   use: pendingController.updateAccountStatus)

    // controllers
    try app.register(collection: AuthController())
    try app.register(collection: LessonsController())
    try app.register(collection: UserBookingsController())
    try app.register(collection: BookingsController())
    try app.register(collection: LessonAdminController())
    try app.register(collection: StudentBookingsController())
    try app.register(collection: StudentLessonController())
    try app.register(collection: InstructorLessonController())
    try app.register(collection: TestAppointmentController())
    try app.register(collection: TestCentreController())
    try app.register(collection: ConfirmedLessonController())
    try app.register(collection: AdminCalendarController())
    try app.register(collection: AdminUserController())
    try app.register(collection: AdminBackfillController())

}
