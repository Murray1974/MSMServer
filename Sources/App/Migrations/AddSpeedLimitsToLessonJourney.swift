import Fluent

struct AddSpeedLimitsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            // Same `jsonb[]` shape/default pitfall as `manoeuvre_events`/`mock_tests` —
            // `.sql(.default("{}"))`, never a quoted `'{}'`, once real rows already exist.
            .field("speed_limit_points", .array(of: .dictionary), .required, .sql(.default("{}")))
            .field("speeding_events", .array(of: .dictionary), .required, .sql(.default("{}")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("speed_limit_points")
            .deleteField("speeding_events")
            .update()
    }
}
