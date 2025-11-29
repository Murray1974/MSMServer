import Vapor
import Fluent

struct StudentLessonController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {

        let student = routes
            .grouped("student")
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())

        student.get("lessons", "available", use: availableLessons)
    }

    func availableLessons(_ req: Request) async throws -> [Lesson] {
        let now = Date()

        // 1) Start with all future lessons on the "Untitled" calendar.
        let candidates = try await Lesson.query(on: req.db)
            .filter(\.$startsAt > now)
            .filter(\.$calendarName == "Untitled")
            .all()

        // 2) For each lesson, check how many active bookings it already has and only
        //    return those that are not yet full (respecting capacity, defaulting to 1).
        var available: [Lesson] = []
        for lesson in candidates {
            guard let lessonID = lesson.id else { continue }

            let existingCount = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$deletedAt == nil)
                .count()

            let capacity = lesson.capacity ?? 1
            if existingCount < capacity {
                available.append(lesson)
            }
        }

        return available
    }
}
