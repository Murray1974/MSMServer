import Vapor
import Fluent

// payload for rescheduling
struct RescheduleInput: Content {
    var newLessonID: UUID
}

struct StudentBookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // student, session-protected
        let student = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())

        // POST /bookings  { "lessonID": "…" }
        student.post("bookings", use: createBooking)

        // POST /bookings/cancel/:bookingID
        student.post("bookings", "cancel", ":bookingID", use: cancelBooking)

        // POST /bookings/reschedule/:bookingID
        student.post("bookings", "reschedule", ":bookingID", use: rescheduleBooking)

        // GET /bookings
        student.get("bookings", use: myBookings)
    }

    // MARK: - create booking

    struct CreateBookingInput: Content {
        let lessonID: UUID
    }

    func createBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let input = try req.content.decode(CreateBookingInput.self)

        // 1) load lesson
        guard let lesson = try await Lesson.find(input.lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // 2) prevent duplicate booking for same user+lesson
        let alreadyBooked = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .first()

        if alreadyBooked != nil {
            throw Abort(.conflict, reason: "You have already booked this lesson")
        }

        // 3) check capacity
        let existingCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .count()

        let capacity = lesson.capacity ?? 1
        if existingCount >= capacity {
            throw Abort(.conflict, reason: "Lesson is full")
        }

        // 4) create booking
        let booking = Booking()
        booking.$user.id = userID
        booking.$lesson.id = input.lessonID
        try await booking.save(on: req.db)

        return .created
    }

    // MARK: - cancel own booking

    func cancelBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing booking ID")
        }

        // only cancel booking that belongs to this user
        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        // cache before delete
        let lessonID = booking.$lesson.id
        let bookingUUID = try booking.requireID()

        // delete / soft delete
        try await booking.delete(on: req.db)

        // log student cancellation
        let event = BookingEvent(
            type: "student.cancelled",
            userID: userID,
            lessonID: lessonID,
            bookingID: bookingUUID
        )
        try await event.save(on: req.db)

        return .noContent
    }

    // MARK: - reschedule booking

    func rescheduleBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing booking ID")
        }

        let input = try req.content.decode(RescheduleInput.self)

        // find this user's booking
        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == userID)
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        // find new lesson
        guard let newLesson = try await Lesson.find(input.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "New lesson not found")
        }

        // check capacity on new lesson
        let newLessonBookingsCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.newLessonID)
            .filter(\.$deletedAt == nil)
            .count()

        let newCapacity = newLesson.capacity ?? 1
        if newLessonBookingsCount >= newCapacity {
            throw Abort(.conflict, reason: "Target lesson is full")
        }

        // don't "reschedule" to the same lesson
        if booking.$lesson.id == input.newLessonID {
            throw Abort(.conflict, reason: "This booking is already for that lesson")
        }

        // update booking
        booking.$lesson.id = input.newLessonID
        try await booking.save(on: req.db)

        return .ok
    }

    // MARK: - get my bookings

    func myBookings(_ req: Request) async throws -> [StudentBookingDTO] {
        struct Query: Decodable {
            var scope: String?
            var limit: Int?
        }

        let q = try req.query.decode(Query.self)
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

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

        return results.map { booking in
            StudentBookingDTO(
                id: booking.id,
                lessonID: booking.$lesson.id,
                lessonTitle: booking.$lesson.value?.title,
                startsAt: booking.$lesson.value?.startsAt,
                endsAt: booking.$lesson.value?.endsAt,
                status: booking.deletedAt == nil ? "active" : "cancelled"
            )
        }
    }

    // MARK: - DTO

    struct StudentBookingDTO: Content {
        var id: UUID?
        var lessonID: UUID?
        var lessonTitle: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
    }
}
