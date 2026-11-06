import Fluent

struct AddEstimatedArrivalAtToTrackingSession: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tracking_sessions")
            .field("estimated_arrival_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tracking_sessions")
            .deleteField("estimated_arrival_at")
            .update()
    }
}
