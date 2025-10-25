import Vapor
import Fluent

/// Public lessons listing + protected "book"
struct LessonsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let lessons = routes.grouped("lessons")

        // Public reads (upcoming-only, paginated)
        lessons.get(use: list)
        lessons.get(":id", use: detail)

        // Protected actions (requires valid bearer token)
        let protected = lessons.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        protected.post(":id", "book", use: book)
    }

    struct PageQuery: Content {
        var page: Int?
        var per: Int?
    }

    // GET /lessons?page=1&per=20  (upcoming only)
    func list(req: Request) async throws -> [Lesson.Public] {
        let q = try? req.query.decode(PageQuery.self)
        let page = max(q?.page ?? 1, 1)
        let per  = min(max(q?.per ?? 20, 1), 100)
        let offset = (page - 1) * per

        let now = Date()

        // Page the upcoming lessons
        let items = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= now)
            .sort(\.$startsAt, .ascending)
            .range(offset..<(offset + per))
            .all()

        guard !items.isEmpty else { return [] }

        // Get booking counts for these lessons
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

        // Duplicate booking guard
        if try await Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .filter(\.$lesson.$id == lessonID)
            .first() != nil
        {
            throw Abort(.conflict, reason: "You have already booked this lesson.")
        }

        // Capacity check
        let current = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .count()
        if current >= lesson.capacity {
            throw Abort(.conflict, reason: "Lesson is full.")
        }

        // Create booking
        let booking = Booking(userID: uid, lessonID: try lesson.requireID())
        try await booking.save(on: req.db)
        return .created
    }
}
