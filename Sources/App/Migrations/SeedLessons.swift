import Fluent
import Vapor

struct SeedLessons: AsyncMigration {
    func prepare(on db: Database) async throws {
        // Only seed if table is empty
        let count = try await Lesson.query(on: db).count()
        guard count == 0 else { return }

        let now = Date()
        let oneHour: TimeInterval = 60 * 60

        let lessons: [Lesson] = [
            Lesson(title: "Intro to Algebra",   startsAt: now.addingTimeInterval( oneHour * 24), endsAt: now.addingTimeInterval( oneHour * 25), capacity: 12),
            Lesson(title: "Biology Lab 101",    startsAt: now.addingTimeInterval( oneHour * 26), endsAt: now.addingTimeInterval( oneHour * 27), capacity: 10),
            Lesson(title: "English Literature",  startsAt: now.addingTimeInterval( oneHour * 30), endsAt: now.addingTimeInterval( oneHour * 31), capacity: 15),
            Lesson(title: "Chemistry Basics",    startsAt: now.addingTimeInterval( oneHour * 48), endsAt: now.addingTimeInterval( oneHour * 49), capacity: 14)
        ]

        try await lessons.create(on: db)
    }

    func revert(on db: Database) async throws {
        try await Lesson.query(on: db).delete()
    }
}
