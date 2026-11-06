import Fluent

/// `CreateLessonJourney`/`AddDrivingMetricsToLessonJourney` created `points`,
/// `stop_markers`, and `driving_events` as `.array(of: nil)`, which
/// `PostgresConverterDelegate` maps to a plain `jsonb` column. But Fluent's actual
/// value-encoder for a Swift `[Codable]` property binds it as a native Postgres array
/// of jsonb elements (`jsonb[]`) regardless of the declared column type — a genuine
/// mismatch between schema-creation-time and value-encoding-time type mapping. Every
/// `POST /instructor/tracking/journey` has been failing with exactly this error:
/// "column \"points\" is of type jsonb but expression is of type jsonb[]". The table
/// has zero successful rows (confirmed via production logs — every insert attempt
/// failed identically since the feature shipped), so there's no data to preserve;
/// simplest fix is to make the column type match what Fluent already writes.
struct FixLessonJourneyArrayColumnTypes: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("points")
            .deleteField("stop_markers")
            .deleteField("driving_events")
            .field("points", .array(of: .dictionary), .required)
            .field("stop_markers", .array(of: .dictionary), .required)
            .field("driving_events", .array(of: .dictionary), .required)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("points")
            .deleteField("stop_markers")
            .deleteField("driving_events")
            .field("points", .array(of: nil), .required)
            .field("stop_markers", .array(of: nil), .required)
            .field("driving_events", .array(of: nil), .required)
            .update()
    }
}
