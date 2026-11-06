import Fluent

struct AddArrivalNotifiedToTrackingSession: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tracking_sessions")
            .field("arrival_notified", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tracking_sessions")
            .deleteField("arrival_notified")
            .update()
    }
}
