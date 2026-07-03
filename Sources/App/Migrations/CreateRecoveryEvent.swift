import Fluent

struct CreateRecoveryEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("recovery_events")
            .id()
            .field("lesson_id", .uuid, .required)
            .field("stage", .string, .required)
            .field("result", .string, .required)
            .field("client_count", .int, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("recovery_events").delete()
    }
}
