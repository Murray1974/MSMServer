import Fluent

struct CreateLessonNote: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_notes")
            .id()
            .field("student_id", .uuid, .required)
            .field("content", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_notes").delete()
    }
}
