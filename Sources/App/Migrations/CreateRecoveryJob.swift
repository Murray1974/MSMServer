import Fluent

struct CreateRecoveryJob: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("recovery_jobs")
            .id()
            .field("lesson_id", .uuid, .required)
            .field("stage", .string, .required)
            .field("scheduled_for", .datetime, .required)
            .field("sent_at", .datetime)
            .field("cancelled_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("recovery_jobs").delete()
    }
}
