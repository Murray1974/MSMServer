import Fluent

struct CreateStudentSafetyProgress: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_safety_progress")
            .id()
            .field("student_id",  .uuid, .required,
                   .references("users",            "id", onDelete: .cascade))
            .field("question_id", .uuid, .required,
                   .references("safety_questions", "id", onDelete: .cascade))
            .field("mastered",    .bool, .required, .custom("DEFAULT FALSE"))
            .field("updated_at",  .datetime)
            .unique(on: "student_id", "question_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_safety_progress").delete()
    }
}
