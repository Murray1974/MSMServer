import Fluent

struct CreateLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .id()
            .field("booking_id", .uuid, .required)
            .field("started_at", .datetime, .required)
            .field("ended_at", .datetime, .required)
            .field("ended_reason", .string, .required)
            // `.array(of: nil)` maps to a JSONB column on Postgres — the whole route is
            // always read/written as one unit, never queried point-by-point, so this is
            // stored as a single JSON array rather than a child table.
            .field("points", .array(of: nil), .required)
            .field("distance_miles", .double, .required)
            .field("stop_markers", .array(of: nil), .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys").delete()
    }
}
