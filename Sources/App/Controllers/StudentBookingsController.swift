import Vapor
import Fluent

struct StudentBookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // student, session-protected
        let student = routes
            .grouped("student")
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())

        // /student/bookings
        let bookings = student.grouped("bookings")

        // POST /student/bookings
        bookings.post(use: createBooking)

        // GET /student/bookings
        bookings.get(use: myBookings)

        // /student/bookings/:bookingID/*
        let byID = bookings.grouped(":bookingID")

        // DELETE /student/bookings/:bookingID
        byID.delete(use: cancelBooking)

        // POST /student/bookings/:bookingID/cancel
        byID.post("cancel", use: cancelBooking)

        // POST /student/bookings/:bookingID/reschedule
        byID.post("reschedule", use: rescheduleBooking)

        // PATCH /student/bookings/:bookingID/duration  ← NEW ROUTE
        byID.patch("duration", use: updateDuration)

        // PATCH /student/bookings/:bookingID/pickup
        byID.patch("pickup", use: updatePickup)
    }

    // MARK: INPUT STRUCTS

    struct CreateBookingInput: Content {
        let lessonID: UUID
        let durationMinutes: Int?
        let startOffsetMinutes: Int?
    }

    struct UpdateDurationInput: Content {
        let durationMinutes: Int
        let startOffsetMinutes: Int?
    }

    // MARK: CREATE BOOKING

    func createBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let input = try req.content.decode(CreateBookingInput.self)
        let offsetMinutes = input.startOffsetMinutes ?? 0

        guard let lesson = try await Lesson.find(input.lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Prevent duplicates
        let alreadyBooked = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .first()

        if alreadyBooked != nil {
            throw Abort(.conflict, reason: "You have already booked this lesson")
        }

        // Capacity check
        let existingCount = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == input.lessonID)
            .filter(\.$deletedAt == nil)
            .count()

        let cap = lesson.capacity ?? 1
        if existingCount >= cap {
            throw Abort(.conflict, reason: "Lesson is full")
        }

        // Check duration+offset inside slot
        if let mins = input.durationMinutes {
            let slotMinutes = Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60)
            if offsetMinutes < 0 || offsetMinutes + mins > slotMinutes {
                throw Abort(.badRequest, reason: "Requested duration/offset exceeds lesson length (\(slotMinutes)m)")
            }
        }

        // Build the booking
        var actualEndsAt: Date? = nil
        if let mins = input.durationMinutes {
            let effectiveStart = lesson.startsAt.addingTimeInterval(Double(offsetMinutes) * 60)
            actualEndsAt = effectiveStart.addingTimeInterval(Double(mins) * 60)
        }

        // Default pickup from StudentProfile
        var defaultPickupSource: String? = nil
        var defaultPickupLocation: String? = nil

        if let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        {
            let home = profile.pickupHome?.trimmingCharacters(in: .whitespacesAndNewlines)
            let work = profile.pickupWork?.trimmingCharacters(in: .whitespacesAndNewlines)
            let college = profile.pickupCollege?.trimmingCharacters(in: .whitespacesAndNewlines)
            let school = profile.pickupSchool?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let a = home, !a.isEmpty { defaultPickupSource = "home"; defaultPickupLocation = a }
            else if let a = work, !a.isEmpty { defaultPickupSource = "work"; defaultPickupLocation = a }
            else if let a = college, !a.isEmpty { defaultPickupSource = "college"; defaultPickupLocation = a }
            else if let a = school, !a.isEmpty { defaultPickupSource = "school"; defaultPickupLocation = a }
        }

        let booking = Booking(
            userID: userID,
            lessonID: input.lessonID,
            durationMinutes: input.durationMinutes,
            actualEndsAt: actualEndsAt
        )
        booking.pickupSource = defaultPickupSource
        booking.pickupLocation = defaultPickupLocation

        try await booking.save(on: req.db)

        let bookedLesson = try await booking.$lesson.get(on: req.db)
        try req.broadcastBooked(for: bookedLesson)

        return .created
    }

    // MARK: CANCEL BOOKING

    func cancelBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing booking ID")
        }

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found for this user")
        }

        try await booking.delete(on: req.db)

        let evt = BookingEvent(
            type: "student.cancelled",
            userID: try user.requireID(),
            lessonID: booking.$lesson.id,
            bookingID: try booking.requireID()
        )
        try await evt.save(on: req.db)

        let freedLesson = try await booking.$lesson.get(on: req.db)
        req.broadcastCancelled(for: freedLesson)
        return .ok
    }

    // MARK: RESCHEDULE

    struct RescheduleInput: Content {
        let newLessonID: UUID
    }

    func rescheduleBooking(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)

        guard let bookingID = req.parameters.get("bookingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing bookingID")
        }

        let body = try req.content.decode(RescheduleInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$deletedAt == nil)
            .with(\.$lesson)
            .first()
        else {
            throw Abort(.notFound, reason: "Booking not found")
        }

        guard let newLesson = try await Lesson.find(body.newLessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson to move to not found")
        }

        let oldLesson = try await booking.$lesson.get(on: req.db)

        booking.$lesson.id = try newLesson.requireID()

        if let mins = booking.durationMinutes {
            let newStart = newLesson.startsAt
            booking.actualEndsAt = newStart.addingTimeInterval(Double(mins) * 60)
        } else {
            booking.actualEndsAt = nil
        }

        try await booking.save(on: req.db)
        req.broadcastRescheduled(old: oldLesson, new: newLesson)

        return .ok
    }

    // MARK: UPDATE DURATION (NEW)

    func updateDuration(_ req: Request) async throws -> StudentBookingDTO {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)
        let input = try req.content.decode(UpdateDurationInput.self)

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$id == bookingID)
            .with(\.$lesson)
            .first()
        else { throw Abort(.notFound) }

        guard booking.$user.id == user.id else {
            throw Abort(.forbidden, reason: "This booking does not belong to you")
        }

        guard let lesson = booking.$lesson.value else {
            throw Abort(.internalServerError, reason: "Booking missing lesson")
        }

        let slotMinutes = Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60)

        // Determine effective start
        let effectiveStart: Date
        if let offset = input.startOffsetMinutes {
            effectiveStart = lesson.startsAt.addingTimeInterval(Double(offset) * 60)
        } else if let mins = booking.durationMinutes,
                  let actualEnd = booking.actualEndsAt {
            effectiveStart = actualEnd.addingTimeInterval(Double(-mins) * 60)
        } else {
            effectiveStart = lesson.startsAt
        }

        let newOffsetMinutes = Int(effectiveStart.timeIntervalSince(lesson.startsAt) / 60)

        if newOffsetMinutes < 0 ||
            newOffsetMinutes + input.durationMinutes > slotMinutes
        {
            throw Abort(.badRequest, reason: "Requested duration/offset exceeds lesson slot.")
        }

        let newEndsAt = effectiveStart.addingTimeInterval(Double(input.durationMinutes) * 60)

        booking.durationMinutes = input.durationMinutes
        booking.actualEndsAt = newEndsAt

        try await booking.save(on: req.db)

        return StudentBookingDTO(
            id: booking.id,
            lessonID: booking.$lesson.id,
            lessonTitle: lesson.title,
            startsAt: effectiveStart,
            endsAt: newEndsAt,
            status: "active",
            pickupLocation: booking.pickupLocation,
            pickupSource: booking.pickupSource,
            lessonStartsAt: lesson.startsAt,
            lessonEndsAt: lesson.endsAt
        )
    }

    // MARK: GET MY BOOKINGS

    func myBookings(_ req: Request) async throws -> [StudentBookingDTO] {
        struct Query: Decodable {
            var scope: String?
            var limit: Int?
        }

        let q = try req.query.decode(Query.self)
        let user = try req.auth.require(User.self)

        let userID = try user.requireID()
        let now = Date()

        var query = Booking.query(on: req.db)
            .withDeleted()
            .filter(\.$user.$id == userID)
            .with(\.$lesson)

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
            let lesson = booking.$lesson.value

            let baseEndsAt = booking.actualEndsAt ?? lesson?.endsAt
            let effectiveStart: Date?
            if let mins = booking.durationMinutes, let end = baseEndsAt {
                effectiveStart = end.addingTimeInterval(Double(-mins) * 60)
            } else {
                effectiveStart = lesson?.startsAt
            }

            return StudentBookingDTO(
                id: booking.id,
                lessonID: booking.$lesson.id,
                lessonTitle: lesson?.title,
                startsAt: effectiveStart,
                endsAt: baseEndsAt,
                status: booking.deletedAt == nil ? "active" : "cancelled",
                pickupLocation: booking.pickupLocation,
                pickupSource: booking.pickupSource,
                lessonStartsAt: lesson?.startsAt,
                lessonEndsAt: lesson?.endsAt
            )
        }
    }

    // MARK: DTO

    struct StudentBookingDTO: Content {
        var id: UUID?
        var lessonID: UUID?
        var lessonTitle: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
        var pickupLocation: String?
        var pickupSource: String?
        var lessonStartsAt: Date?
        var lessonEndsAt: Date?
    }

    // MARK: UPDATE PICKUP

    func updatePickup(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let bookingID = try req.parameters.require("bookingID", as: UUID.self)
        let input = try req.content.decode(UpdatePickupInput.self)

        guard var booking = try await Booking.find(bookingID, on: req.db) else {
            throw Abort(.notFound)
        }

        guard booking.$user.id == user.id else {
            throw Abort(.forbidden)
        }

        booking.pickupLocation = input.pickupLocation
        booking.pickupSource = input.pickupSource

        try await booking.save(on: req.db)
        return .ok
    }

    struct UpdatePickupInput: Content {
        var pickupLocation: String?
        var pickupSource: String?
    }
}
