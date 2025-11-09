import Vapor
import Fluent

struct StudentLessonController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let student = routes.grouped("student")
        student.get("lessons", "available", use: availableLessons)
    }

    func availableLessons(_ req: Request) async throws -> [Lesson] {
        let now = Date()

        // NOTE: your model uses `startsAt` (not `startAt`)
        let futureLessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt > now)
            .all()

        var available: [Lesson] = []
        for lesson in futureLessons {
            // check if this lesson already has a booking
            let hasBooking = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lesson.requireID())
                .first() != nil

            if !hasBooking {
                available.append(lesson)
            }
        }

        return available
    }
}
