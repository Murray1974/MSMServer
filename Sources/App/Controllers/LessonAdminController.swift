import Vapor
import Fluent

// MARK: - DTOs
struct AdminBookingRow: Content {
    var id: UUID?
    var bookedAt: Date?
    var deletedAt: Date?
    var lessonTitle: String?
}

struct LessonStatsResponse: Content {
    var capacity: Int
    var booked: Int
    var available: Int
}

struct AttendeeRow: Content {
    var bookingID: UUID?
    var userID: UUID?
    var username: String?
}

struct AdminDashboardSummary: Content {
    var totalLessons: Int
    var totalBookings: Int
    var activeBookings: Int
    var cancelledBookings: Int
    var upcomingLessons: Int
}

// MARK: - Controller
struct LessonAdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // /admin
        let admin = routes.grouped("admin")
        
        // /admin/dashboard
        admin.get("dashboard", use: dashboard)
        
        // /admin/students/:studentID/bookings
        admin.get("students", ":studentID", "bookings", use: studentBookings)
        admin.get("users", ":userID", "bookings", use: userBookings)
        
        // /admin/lessons/...
        let lessons = admin.grouped("lessons")
        
        // listings / stats
        lessons.get(":lessonID", "bookings", use: lessonBookings)
        lessons.get(":lessonID", "stats", use: lessonStats)
        lessons.get(":lessonID", "attendees", use: lessonAttendees)
        
        // cancellation – two shapes
        // 1) /admin/lessons/bookings/:bookingID/cancel
        lessons.post("bookings", ":bookingID", "cancel", use: cancelBooking)
        // 2) /admin/lessons/:lessonID/bookings/:bookingID/cancel
        lessons.post(":lessonID", "bookings", ":bookingID", "cancel", use: cancelBookingScoped)
    }
    
    // MARK: POST /admin/lessons/bookings/:bookingID/cancel
    func cancelBooking(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }
        return try await cancelCommon(bookingID: bookingID, req)
    }
    
    // MARK: POST /admin/lessons/:lessonID/bookings/:bookingID/cancel
    func cancelBookingScoped(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }
        // lessonID not strictly needed because bookingID is unique
        return try await cancelCommon(bookingID: bookingID, req)
    }
    
    // MARK: shared cancel logic
    private func cancelCommon(bookingID: UUID, _ req: Request) async throws -> HTTPStatus {
        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found.")
        }
        
        // your current pattern: soft delete = cancel
        try await booking.delete(on: req.db)
        return .noContent
    }
    
    // MARK: GET /admin/lessons/:lessonID/bookings
    func lessonBookings(_ req: Request) async throws -> Page<AdminBookingRow> {
        struct Q: Decodable { var page: Int?; var per: Int?; var includeDeleted: Bool? }
        let q = try req.query.decode(Q.self)
        
        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id.")
        }
        
        var query = Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .with(\.$lesson)
            .sort(\.$id, .descending)
        
        if q.includeDeleted == true {
            query = query.withDeleted()
        }
        
        let page = try await query.paginate(PageRequest(page: q.page ?? 1, per: q.per ?? 10))
        
        let items = page.items.map { b in
            AdminBookingRow(
                id: b.id,
                bookedAt: b.createdAt,
                deletedAt: b.deletedAt,
                lessonTitle: b.$lesson.value?.title
            )
        }
        
        return Page(items: items, metadata: page.metadata)
    }
    
    // MARK: GET /admin/lessons/:lessonID/stats
    func lessonStats(_ req: Request) async throws -> LessonStatsResponse {
        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id.")
        }
        
        // TODO: once Lesson has a real capacity field, use it here
        let capacity = 1
        
        let booked = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .count()
        
        let available = max(0, capacity - booked)
        
        return LessonStatsResponse(
            capacity: capacity,
            booked: booked,
            available: available
        )
    }
    
    // MARK: GET /admin/lessons/:lessonID/attendees
    func lessonAttendees(_ req: Request) async throws -> [AttendeeRow] {
        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid lesson id.")
        }
        
        let rows = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .with(\.$user)
            .all()
        
        return rows.map { b in
            AttendeeRow(
                bookingID: b.id,
                userID: b.$user.id,
                username: b.$user.value?.username
            )
        }
    }
    
    // MARK: GET /admin/dashboard
    func dashboard(_ req: Request) async throws -> AdminDashboardSummary {
        // total lessons
        let totalLessons = try await Lesson.query(on: req.db).count()
        
        // active bookings (not soft-deleted)
        let activeBookings = try await Booking.query(on: req.db).count()
        
        // total bookings (incl. soft-deleted)
        let totalBookings = try await Booking.query(on: req.db).withDeleted().count()
        
        // cancelled = total - active
        let cancelledBookings = max(0, totalBookings - activeBookings)
        
        // upcoming lessons: startsAt >= now
        let now = Date()
        let upcomingLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= now)
            .count()
        
        return AdminDashboardSummary(
            totalLessons: totalLessons,
            totalBookings: totalBookings,
            activeBookings: activeBookings,
            cancelledBookings: cancelledBookings,
            upcomingLessons: upcomingLessons
        )
    }
    
    // MARK: GET /admin/students/:studentID/bookings
    func studentBookings(_ req: Request) async throws -> [AdminBookingRow] {
        struct Query: Decodable {
            var scope: String?
            var limit: Int?
        }
        let q = try req.query.decode(Query.self)
        
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid student id.")
        }
        
        // make sure user exists (optional but nicer error)
        guard try await User.find(studentID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Student not found")
        }
        
        // base query: bookings for this student
        var query = Booking.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .with(\.$lesson)
        
        let now = Date()
        switch q.scope?.lowercased() {
        case "upcoming":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt >= now)
                .sort(Lesson.self, \.$startsAt, .ascending)
        case "past":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt < now)
                .sort(Lesson.self, \.$startsAt, .descending)
        case "cancelled":
            query = Booking.query(on: req.db)
                .withDeleted()
                .filter(\.$user.$id == studentID)
                .filter(\.$deletedAt != nil)
                .with(\.$lesson)
                .sort(\.$deletedAt, .descending)
        default:
            query = query.sort(\.$createdAt, .descending)
        }
        
        if let limit = q.limit, limit > 0 {
            query = query.limit(limit)
        }
        
        let results = try await query.all()
        
        return results.map { b in
            AdminBookingRow(
                id: b.id,
                bookedAt: b.createdAt,
                deletedAt: b.deletedAt,
                lessonTitle: b.$lesson.value?.title
            )
        }
    }
    
    // MARK: GET /admin/users/:userID/bookings
    func userBookings(_ req: Request) async throws -> [AdminBookingRow] {
        struct Query: Decodable {
            var scope: String?
            var limit: Int?
        }
        let q = try req.query.decode(Query.self)

        let userID = try req.parameters.require("userID", as: UUID.self)

        // ensure user exists
        guard try await User.find(userID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }

        var query = Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .with(\.$lesson)

        let now = Date()
        switch q.scope?.lowercased() {
        case "upcoming":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt >= now)
                .sort(Lesson.self, \.$startsAt, .ascending)
        case "past":
            query = query
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt < now)
                .sort(Lesson.self, \.$startsAt, .descending)
        case "cancelled":
            query = Booking.query(on: req.db)
                .withDeleted()
                .filter(\.$user.$id == userID)
                .filter(\.$deletedAt != nil)
                .with(\.$lesson)
                .sort(\.$deletedAt, .descending)
        default:
            query = query.sort(\.$createdAt, .descending)
        }

        if let limit = q.limit, limit > 0 {
            query = query.limit(limit)
        }

        let results = try await query.all()
        return results.map { b in
            AdminBookingRow(
                id: b.id,
                bookedAt: b.createdAt,
                deletedAt: b.deletedAt,
                lessonTitle: b.$lesson.value?.title
            )
        }
    }
}
