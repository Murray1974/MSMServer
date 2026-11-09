import Fluent

struct AddManoeuvreEventsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            // Matches the `jsonb[]` type FixLessonJourneyArrayColumnTypes corrected
            // `points`/`stop_markers`/`driving_events` to, not the original (broken)
            // `.array(of: nil)` from AddDrivingMetricsToLessonJourney — real rows already
            // exist in this table, so a default is required for the new column.
            //
            // `.sql(.default(...))` quote-wraps its String argument itself — passing
            // "'{}'" (already quoted) got double-wrapped into `DEFAULT '''{}'''`, which
            // Postgres rejected as a malformed array literal and crash-looped the whole
            // server on every boot (confirmed in production 9 Nov 2026). The bare `"{}"`
            // below is what actually renders as `DEFAULT '{}'`.
            .field("manoeuvre_events", .array(of: .dictionary), .required, .sql(.default("{}")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("manoeuvre_events")
            .update()
    }
}
