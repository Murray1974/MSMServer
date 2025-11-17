import Vapor
import Fluent

/// Admin-only lesson management
struct LessonAdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // base path: /admin
        let admin = routes.grouped("admin")

        // protect it the same way your /me/ routes are protected
        let protected = admin.grouped(
            SessionTokenAuthenticator(),
            User.guardMiddleware()
        )

        // GET /admin/lessons
        protected.get("lessons", use: list)

        // POST /admin/lessons
        protected.post("lessons", use: create)

        // POST /admin/push-slot
        protected.post("push-slot", use: pushSlot)

        // GET /admin/lessons/:lessonID
        protected.get("lessons", ":lessonID", use: get)

        // PUT /admin/lessons/:lessonID
        protected.put("lessons", ":lessonID", use: update)

        // DELETE /admin/lessons/:lessonID
        protected.delete("lessons", ":lessonID", use: delete)
    }

    // MARK: GET /admin/lessons
    func list(_ req: Request) async throws -> [Lesson] {
        try await Lesson.query(on: req.db)
            .sort(\.$startsAt, .descending)
            .all()
    }

    // MARK: GET /admin/lessons/:lessonID
    func get(_ req: Request) async throws -> Lesson {
        guard let id = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id")
        }
        guard let lesson = try await Lesson.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }
        return lesson
    }

    // MARK: POST /admin/lessons
    func create(_ req: Request) async throws -> Lesson {
        struct Input: Content {
            var title: String
            var startsAt: Date
            var endsAt: Date
            var capacity: Int?   // 👈 make it optional in the JSON
            var calendarName: String?
        }

        let input = try req.content.decode(Input.self)

        let lesson = Lesson(
            title: input.title,
            startsAt: input.startsAt,
            endsAt: input.endsAt,
            capacity: input.capacity ?? 1,   // 👈 DEFAULT so build doesn’t fail
            calendarName: input.calendarName ?? "Untitled"
        )

        try await lesson.save(on: req.db)
        // Broadcast realtime availability update
        let update = AvailabilityUpdate(
            action: "slot.created",
            id: try lesson.requireID(),
            title: lesson.title,
            startsAt: lesson.startsAt,
            endsAt: lesson.endsAt,
            capacity: lesson.capacity
        )
        req.application.availabilityHub.broadcast(update)
        // Broadcast slot.created event to connected instructor agents
        let hours = Int(round(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 3600))
        let title = "New \(hours)-hour slot"
        let msg   = niceDateRange(start: lesson.startsAt, end: lesson.endsAt) + (lesson.title.isEmpty ? "" : " (\(lesson.title))")
        req.application.broadcastEvent(type: "slot.created", title: title, message: msg)
        return lesson
    }

    // MARK: POST /admin/push-slot
    func pushSlot(_ req: Request) async throws -> Lesson {
        struct Input: Content {
            var title: String
            var startsAt: Date
            var endsAt: Date
            var capacity: Int?
            var calendarName: String?
        }

        let input = try req.content.decode(Input.self)

        let lesson = Lesson(
            title: input.title,
            startsAt: input.startsAt,
            endsAt: input.endsAt,
            capacity: input.capacity ?? 1,
            calendarName: input.calendarName ?? "Untitled"
        )

        try await lesson.save(on: req.db)
        return lesson
    }

    // MARK: PUT /admin/lessons/:lessonID
    func update(_ req: Request) async throws -> Lesson {
        struct Input: Content {
            var title: String?
            var startsAt: Date?
            var endsAt: Date?
        }

        guard let id = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id")
        }
        guard let lesson = try await Lesson.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        let input = try req.content.decode(Input.self)
        if let t = input.title { lesson.title = t }
        if let s = input.startsAt { lesson.startsAt = s }
        if let e = input.endsAt { lesson.endsAt = e }

        try await lesson.save(on: req.db)
        return lesson
    }

    // MARK: DELETE /admin/lessons/:lessonID
    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id")
        }
        guard let lesson = try await Lesson.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }
        try await lesson.delete(on: req.db)
        return .noContent
    }
}
