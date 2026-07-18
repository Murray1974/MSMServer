import Vapor
import Fluent
import FluentSQL
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

        // Load all future lessons once — used for in-memory lookups to avoid N+1 DB queries.
        let now = Date()
        let futureLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= now)
            .all()

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
                  cal == "MSM Available" || cal == "MSM Lessons" ||
                  cal == "Untitled" || cal == "Mike work"
            else {
                continue
            }

            let syncedState = (cal == "MSM Available" || cal == "Untitled") ? "available" : "booked"
            guard let start = parseISO8601(s.startsAt),
                  let end = parseISO8601(s.endsAt) else {
                throw Abort(.badRequest, reason: "Use ISO8601 dates for startsAt/endsAt")
            }

            // Match by explicit id first (in-memory), then by start/end time (in-memory).
            // No per-slot DB queries — all lookups use the futureLessons fetch above.
            let timeKey = "\(start.timeIntervalSince1970)_\(end.timeIntervalSince1970)"
            let lesson: Lesson
            if let lid = s.id, let existing = futureByID[lid] {
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
            let stateChanged = lesson.state != syncedState
            if stateChanged {
                if let t = s.title { lesson.title = t }
                if let c = s.capacity { lesson.capacity = c }
                lesson.calendarName = cal
                lesson.state = syncedState
            }
            let changed = stateChanged
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
                try await Lesson.query(on: req.db)
                    .filter(\.$id ~~ pruneIDs)
                    .delete()
                prunedCount = toPrune.count
                for l in toPrune {
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

        return SyncResult(upserted: upsertedCount, pruned: prunedCount, links: links)
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

        let now = Date()
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
            let defaultHourlyRate = Decimal(45)
            let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)

            let finance = LessonFinance(
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

        let transactions = activeEntries.compactMap { entry -> StudentTransactionView? in
            guard let id = entry.id else { return nil }
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
                voidReason: nil
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
                    amountDue = (Decimal(45) * Decimal(mins)) / Decimal(60)
                }

                pendingPaymentBooking = PendingPaymentView(
                    bookingID: bookingID.uuidString,
                    lessonID: bLessonID.uuidString,
                    startsAt: iso.string(from: bLesson.startsAt),
                    endsAt: iso.string(from: bLesson.endsAt),
                    amountDue: amountDue
                )
                break  // surface the soonest only
            }
        }

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
            pendingPaymentBooking: pendingPaymentBooking,
            holdLessonID: holdLessonID,
            holdLessonStartsAt: holdLessonStartsAt,
            holdLessonAvailable: holdLessonAvailable
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

    financeProtected.post("finance", "payments", use: finance.addPayment)
    financeProtected.post("finance", "expenses", use: finance.addExpense)
    financeProtected.post("finance", "expenses", ":expenseID", "update", use: finance.updateExpense)
    financeProtected.delete("finance", "expenses", ":expenseID", use: finance.deleteExpense)
    financeProtected.get("finance", "expenses", "export", use: finance.exportExpensesCSV)
    financeProtected.get("finance", "ledger", "export", use: finance.exportLedgerCSV)
    financeProtected.post("finance", "lessons", ":lessonID", "charge", use: finance.chargeLesson)
    financeProtected.get("finance", "students", use: finance.studentBalances)
    financeProtected.get("finance", "students", ":studentID", "transactions", use: finance.studentTransactions)
    financeProtected.get("finance", "students", ":studentID", "outstanding-lessons", use: finance.outstandingLessons)
    financeProtected.get("finance", "business-summary", use: finance.businessSummary)
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
    let fuelController = FuelController()
    financeProtected.get("instructor",    "fuel",              use: fuelController.list)
    financeProtected.post("instructor",   "fuel",              use: fuelController.log)
    financeProtected.delete("instructor", "fuel", ":entryID",  use: fuelController.delete)

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
    financeProtected.post("instructor", "students", ":profileID", "approve", use: pendingController.approve)
    financeProtected.post("instructor", "students", ":profileID", "reject",  use: pendingController.reject)

    // Student approval status check
    studentProtected.get("status", use: pendingController.studentStatus)

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
