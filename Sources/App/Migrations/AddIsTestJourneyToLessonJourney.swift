import Fluent

struct AddIsTestJourneyToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .field("is_test_journey", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("is_test_journey")
            .update()
    }
}
