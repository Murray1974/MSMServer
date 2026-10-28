import Fluent

struct CreateTrackingSession: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tracking_sessions")
            .id()
            .field("booking_id", .uuid, .required)
            .field("started_at", .datetime, .required)
            .field("ends_at", .datetime, .required)
            .field("ended_at", .datetime)
            .field("ended_reason", .string)
            .field("last_latitude", .double)
            .field("last_longitude", .double)
            .field("last_updated_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tracking_sessions").delete()
    }
}
