import Vapor
import Fluent

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

        student.get("bookings", use: myBookings)
    }

    struct CreateBookingInput: Content {
        let lessonID: UUID
    }

    // MARK: - create booking
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

        if existingCount >= lesson.capacity {
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

        try await booking.delete(on: req.db)
        return .noContent
    }

    struct RescheduleInput: Content {
        let newLessonID: UUID
    }

    // POST /bookings/reschedule/:bookingID
    func rescheduleBooking(_ req: Request) async throws -> HTTPStatus {
        // 1. who is this?
        let user = try req.auth.require(User.self)

        // 2. which booking?
        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID in path")
        }

        // 3. what lesson do they want instead?
        struct RescheduleInput: Content {
            let lessonID: UUID
        }
        let body = try req.content.decode(RescheduleInput.self)

        // 4. load the booking, make sure it’s theirs and not deleted
        guard let booking = try await Booking
            .query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        // 5. load the new lesson
        guard let newLesson = try await Lesson
            .query(on: req.db)
            .filter(\.$id == body.lessonID)
            .first()
        else {
            throw Abort(.notFound, reason: "Lesson to move to not found")
        }

        // 6. (optional) capacity check — skip if you don’t want it right now
        // if let cap = newLesson.capacity, cap <= 0 {
        //     throw Abort(.conflict, reason: "Lesson is full")
        // }

        // 7. update booking to point at the new lesson
        booking.$lesson.id = try newLesson.requireID()
        try await booking.update(on: req.db)

        return .ok
    }
    
    // MARK: POST /me/bookings/:bookingID/reschedule
    func rescheduleMyBooking(_ req: Request) async throws -> HTTPStatus {
        struct Input: Content {
            var newLessonID: UUID
        }

        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)
        let input = try req.content.decode(Input.self)

        // 1. load booking & check ownership
        guard let booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound, reason: "Booking not found")
        }
        guard booking.$user.id == user.id else {
            throw Abort(.forbidden, reason: "This booking does not belong to you")
        }

        // 2. load target lesson
        guard let newLesson = try await Lesson.find(input.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Target lesson not found")
        }

        // 3. check user is not already booked on target lesson
        let already = try await Booking.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$lesson.$id == input.newLessonID)
            .filter(\.$deletedAt == nil)
            .first()

        if already != nil {
            throw Abort(.conflict, reason: "You are already booked on that lesson")
        }

        // 4. capacity check (same logic as admin)
        let capacity = newLesson.capacity ?? 1
        let activeCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.newLessonID)
            .filter(\.$deletedAt == nil)
            .count()

        guard activeCount < capacity else {
            throw Abort(.conflict, reason: "That lesson is full")
        }

        // 5. perform the reschedule (just move the booking)
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

    struct StudentBookingDTO: Content {
        var id: UUID?
        var lessonID: UUID?
        var lessonTitle: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
    }
}
