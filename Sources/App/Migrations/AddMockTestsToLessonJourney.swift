import Fluent

struct AddMockTestsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            // Same `jsonb[]` shape as `manoeuvre_events` — see
            // AddManoeuvreEventsToLessonJourney for why `.sql(.default("{}"))` (not a
            // quoted "'{}'") is required once real rows already exist in this table.
            .field("mock_tests", .array(of: .dictionary), .required, .sql(.default("{}")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("mock_tests")
            .update()
    }
}
