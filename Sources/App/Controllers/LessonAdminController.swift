import Vapor
import Fluent

// MARK: - DTOs

struct AdminBookingRow: Content {
    var id: UUID?
    var bookedAt: Date?
    var deletedAt: Date?
    var userID: UUID?
    var username: String?
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

struct AdminLessonRow: Content {
    var id: UUID?
    var title: String?
    var startsAt: Date?
    var endsAt: Date?
    var capacity: Int
    var booked: Int
    var available: Int
}

// MARK: - Controller

struct LessonAdminController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")

        admin.get("dashboard", use: dashboard)
        admin.get("students", ":studentID", "bookings", use: studentBookings)
        admin.get("users", ":userID", "bookings", use: userBookings)

        let lessons = admin.grouped("lessons")

        lessons.get(use: listLessons)
        lessons.get(":lessonID", "bookings", use: lessonBookings)
        lessons.get(":lessonID", "stats", use: lessonStats)
        lessons.get(":lessonID", "attendees", use: lessonAttendees)

        lessons.post(":lessonID", "bookings", use: createLessonBooking)

        // admin cancel endpoints
        lessons.post("bookings", ":bookingID", "cancel", use: cancelBooking)
        lessons.post(":lessonID", "bookings", ":bookingID", "cancel", use: cancelBookingScoped)
    }

    // MARK: shared cancel logic (ADMIN)

    private func cancelCommon(bookingID: UUID, _ req: Request) async throws -> HTTPStatus {
        // 👇 IMPORTANT: include soft-deleted (`withDeleted()`)
        guard let booking = try await Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$id == bookingID)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found.")
        }

        // cache IDs
        let userID = booking.$user.id
        let lessonID = booking.$lesson.id
        let bookingUUID = try booking.requireID()

        // perform cancel (even if already deleted, we can just re-delete)
        try await booking.delete(on: req.db)

        // log admin cancellation
        let event = BookingEvent(
            type: "admin.cancelled",
            userID: userID,
            lessonID: lessonID,
            bookingID: bookingUUID
        )
        try await event.save(on: req.db)

        return .noContent
    }

    // MARK: POST /admin/lessons/:lessonID/bookings/:bookingID/cancel

    func cancelBookingScoped(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }
        return try await cancelCommon(bookingID: bookingID, req)
    }

    // MARK: POST /admin/lessons/bookings/:bookingID/cancel

    func cancelBooking(_ req: Request) async throws -> HTTPStatus {
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid booking id.")
        }
        return try await cancelCommon(bookingID: bookingID, req)
    }

    // MARK: GET /admin/lessons

    func listLessons(_ req: Request) async throws -> Page<AdminLessonRow> {
        struct Query: Decodable { var page: Int?; var per: Int?; var availableOnly: Bool? }
        let q = try req.query.decode(Query.self)

        var query = Lesson.query(on: req.db)
            .sort(\.$startsAt, .ascending)

        let page = try await query.paginate(PageRequest(page: q.page ?? 1, per: q.per ?? 10))

        let lessonIDs = page.items.compactMap { $0.id }

        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ lessonIDs)
            .withDeleted()
            .all()

        var counts: [UUID: Int] = [:]
        for b in bookings {
            guard b.deletedAt == nil else { continue }
            counts[b.$lesson.id, default: 0] += 1
        }

        var rows: [AdminLessonRow] = page.items.map { lesson in
            let booked = counts[lesson.id!] ?? 0
            let capacity = lesson.capacity ?? 1
            let available = max(0, capacity - booked)

            return AdminLessonRow(
                id: lesson.id,
                title: lesson.title,
                startsAt: lesson.startsAt,
                endsAt: lesson.endsAt,
                capacity: capacity,
                booked: booked,
                available: available
            )
        }

        if q.availableOnly == true {
            rows = rows.filter { $0.available > 0 }
        }

        return Page(items: rows, metadata: page.metadata)
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
            .with(\.$user)
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
                userID: b.$user.id,
                username: b.$user.value?.username,
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
        let totalLessons = try await Lesson.query(on: req.db).count()
        let activeBookings = try await Booking.query(on: req.db).count()
        let totalBookings = try await Booking.query(on: req.db).withDeleted().count()
        let cancelledBookings = max(0, totalBookings - activeBookings)

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
        struct Query: Decodable { var scope: String?; var limit: Int? }
        let q = try req.query.decode(Query.self)

        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid student id.")
        }

        guard try await User.find(studentID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Student not found")
        }

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

    // MARK: POST /admin/lessons/:lessonID/bookings

    func createLessonBooking(_ req: Request) async throws -> HTTPStatus {
        struct Input: Content { var userID: UUID }

        let lessonID = try req.parameters.require("lessonID", as: UUID.self)
        let input = try req.content.decode(Input.self)

        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        let existing = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$user.$id == input.userID)
            .filter(\.$deletedAt == nil)
            .first()

        if existing != nil {
            throw Abort(.conflict, reason: "User already booked on this lesson")
        }

        let capacity = lesson.capacity ?? 1
        let activeCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .count()

        guard activeCount < capacity else {
            throw Abort(.conflict, reason: "Lesson is full")
        }

        let booking = Booking()
        booking.$lesson.id = lessonID
        booking.$user.id = input.userID
        booking.createdAt = Date()

        try await booking.save(on: req.db)
        return .created
    }

    // MARK: GET /admin/users/:userID/bookings

    func userBookings(_ req: Request) async throws -> [AdminBookingRow] {
        struct Query: Decodable { var scope: String?; var limit: Int? }
        let q = try req.query.decode(Query.self)

        let userID = try req.parameters.require("userID", as: UUID.self)

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
