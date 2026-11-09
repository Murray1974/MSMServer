import Fluent

struct AddManoeuvreEventsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            // Matches the `jsonb[]` type FixLessonJourneyArrayColumnTypes corrected
            // `points`/`stop_markers`/`driving_events` to, not the original (broken)
            // `.array(of: nil)` from AddDrivingMetricsToLessonJourney — real rows already
            // exist in this table, so a default is required for the new column.
            .field("manoeuvre_events", .array(of: .dictionary), .required, .sql(.default("'{}'")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("manoeuvre_events")
            .update()
    }
}
