import Fluent

struct AddDrivingMetricsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .field("top_speed_mph", .double, .required)
            .field("average_speed_mph", .double, .required)
            // `.array(of: nil)` maps to a JSONB column on Postgres, matching `points`/
            // `stop_markers` above.
            .field("driving_events", .array(of: nil), .required)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("top_speed_mph")
            .deleteField("average_speed_mph")
            .deleteField("driving_events")
            .update()
    }
}
