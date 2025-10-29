import Vapor
import Fluent

// MARK: - DTOs
struct AdminBookingRow: Content {
    var id: UUID?
    var bookedAt: Date?
    var cancelledAt: Date?
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

// MARK: - Controller
struct LessonAdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // /admin/lessons/...
        let admin = routes.grouped("admin", "lessons")

        // Listings / stats
        admin.get(":lessonID", "bookings", use: lessonBookings)
        admin.get(":lessonID", "stats", use: lessonStats)
        admin.get(":lessonID", "attendees", use: lessonAttendees)

        // Cancellation — support both shapes:
        // 1) /admin/lessons/bookings/:bookingID/cancel
        admin.post("bookings", ":bookingID", "cancel", use: cancelBooking)
        // 2) /admin/lessons/:lessonID/bookings/:bookingID/cancel
        admin.post(":lessonID", "bookings", ":bookingID", "cancel", use: cancelBookingScoped)
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
        return try await cancelCommon(bookingID: bookingID, req)
    }

    // MARK: - Shared cancel logic (soft-delete + audit timestamp if present)
    private func cancelCommon(bookingID: UUID, _ req: Request) async throws -> HTTPStatus {
        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found.")
        }
        // If your model has these, they’ll compile. If not, comment them out.
        booking.cancelledAt = Date()
        try await booking.save(on: req.db)

        try await booking.delete(on: req.db) // soft-delete
        return .noContent
    }

    // MARK: GET /admin/lessons/:lessonID/bookings?page=&per=&includeDeleted=true
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
                cancelledAt: b.cancelledAt,
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

        // If your Lesson has a capacity field, wire it here. For now default to 1.
        let capacity = 1

        // By default, Fluent excludes soft-deleted records, so this only counts active bookings.
        let booked = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .count()

        let available = max(0, capacity - booked)
        return LessonStatsResponse(capacity: capacity, booked: booked, available: available)
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
}
