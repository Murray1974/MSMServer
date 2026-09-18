import Fluent

struct CreateStudentStatusEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_status_events")
            .id()
            .field("student_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("from_status", .string, .required)
            .field("to_status", .string, .required)
            .field("reason", .string)
            .field("occurred_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_status_events").delete()
    }
}
