import Fluent

struct AddSpeedReductionEventsToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            // Same `jsonb[]` shape and `.sql(.default(...))` pattern as
            // AddManoeuvreEventsToLessonJourney — see that migration's comment for why
            // the bare `"{}"` (not `"'{}'"`) is required to avoid a malformed-array-literal
            // crash loop on boot.
            .field("speed_reduction_events", .array(of: .dictionary), .required, .sql(.default("{}")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("speed_reduction_events")
            .update()
    }
}
