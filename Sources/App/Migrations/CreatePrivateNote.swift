import Fluent

struct CreatePrivateNote: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("private_notes")
            .id()
            .field("student_id",    .uuid,   .required)
            .field("instructor_id", .uuid,   .required)
            .field("content",       .string, .required)
            .field("created_at",    .datetime)
            .field("updated_at",    .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("private_notes").delete()
    }
}
