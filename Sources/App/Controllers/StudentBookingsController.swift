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

    // MARK: - reschedule booking
    func rescheduleBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing booking ID")
        }

        let input = try req.content.decode(RescheduleInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == userID)
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        guard let newLesson = try await Lesson.find(input.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "New lesson not found")
        }

        let newLessonBookingsCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.newLessonID)
            .filter(\.$deletedAt == nil)
            .count()

        if newLessonBookingsCount >= newLesson.capacity {
            throw Abort(.conflict, reason: "Target lesson is full")
        }

        if booking.$lesson.id == input.newLessonID {
            throw Abort(.conflict, reason: "This booking is already for that lesson")
        }

        booking.$lesson.id = input.newLessonID
        try await booking.save(on: req.db)

        return .ok
    }
}
