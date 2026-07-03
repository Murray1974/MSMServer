import Fluent

struct CreateStudentProgress: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_progress")
            .id()
            .field("student_id",  .uuid,     .required,
                   .references("users",            "id", onDelete: .cascade))
            .field("topic_id",    .uuid,     .required,
                   .references("syllabus_topics",  "id", onDelete: .cascade))
            .field("level",       .int,      .required)
            .field("updated_at",  .datetime)
            // One progress record per student per topic.
            .unique(on: "student_id", "topic_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_progress").delete()
    }
}
