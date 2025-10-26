import Vapor
import Fluent

/// Public lessons listing + protected "book"
struct LessonsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let lessons = routes.grouped("lessons")

        // Public reads (upcoming by default, supports ?start=&end= and ?page=&per=)
        lessons.get(use: list)
        lessons.get(":id", use: detail)

        // Protected actions (requires valid bearer token)
        let protected = lessons.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        protected.post(":id", "book", use: book)
    }

    struct PageQuery: Content {
        var page: Int?
        var per: Int?
        var start: String?  // ISO8601 datetime (e.g., 2025-10-26T10:00:00Z)
        var end: String?    // ISO8601 datetime
    }

    // GET /lessons?page=1&per=20&start=...&end=...
    // Defaults to upcoming-only if no start/end provided.
    func list(req: Request) async throws -> [Lesson.Public] {
        let q = try? req.query.decode(PageQuery.self)
        let page = max(q?.page ?? 1, 1)
        let per  = min(max(q?.per ?? 20, 1), 100)
        let offset = (page - 1) * per

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate: Date? = {
            if let s = q?.start {
                return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            return nil
        }()

        let endDate: Date? = {
            if let e = q?.end {
                return iso.date(from: e) ?? ISO8601DateFormatter().date(from: e)
            }
            return nil
        }()

        // Base query
        var query = Lesson.query(on: req.db)

        // If no range supplied, default to upcoming-only
        if startDate == nil && endDate == nil {
            query = query.filter(\.$startsAt >= Date())
        } else {
            if let s = startDate {
                query = query.filter(\.$startsAt >= s)
            }
            if let e = endDate {
                query = query.filter(\.$startsAt <= e)
            }
        }

        // Order + pagination
        let items = try await query
            .sort(\.$startsAt, .ascending)
            .range(offset..<(offset + per))
            .all()

        guard !items.isEmpty else { return [] }

        // Compute availability for the page efficiently
        let ids: [UUID] = items.compactMap { $0.id }
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ ids)
            .all()

        var countByLesson: [UUID: Int] = [:]
        for b in bookings {
            let lid = b.$lesson.id
            countByLesson[lid, default: 0] += 1
        }

        return items.map { lesson in
            let used = countByLesson[lesson.id ?? UUID()] ?? 0
            let available = max(lesson.capacity - used, 0)
            return lesson.asPublic(available: available)
        }
    }

    // GET /lessons/:id  (includes availability)
    func detail(req: Request) async throws -> Lesson.Public {
        guard let id = req.parameters.get("id", as: UUID.self),
              let lesson = try await Lesson.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let used = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == id)
            .count()
        let available = max(lesson.capacity - used, 0)
        return lesson.asPublic(available: available)
    }

    // POST /lessons/:id/book  → creates a booking with capacity + duplicate checks
    func book(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let uid = try user.requireID()

        guard let lessonID = req.parameters.get("id", as: UUID.self),
              let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Duplicate booking guard (only count active bookings)
        if try await Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .first() != nil
        {
            throw Abort(.conflict, reason: "You have already booked this lesson.")
        }

        // Capacity check (active bookings only)
        let current = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .count()
        if current >= lesson.capacity {
            throw Abort(.conflict, reason: "Lesson is full.")
        }

        // Create booking, catch partial-unique / duplicate races as 409
        do {
            let booking = Booking(userID: uid, lessonID: try lesson.requireID())
            try await booking.save(on: req.db)
            return .created
        } catch {
            // If DB unique index still trips (race etc), convert to 409 Conflict
            if String(reflecting: error).contains("uq_bookings_user_lesson_active")
                || String(reflecting: error).contains("23505")
            {
                throw Abort(.conflict, reason: "You have already booked this lesson.")
            }
            throw error
        }
    }
}
