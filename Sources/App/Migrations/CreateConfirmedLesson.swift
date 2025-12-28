import Fluent

struct CreateConfirmedLesson: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("confirmed_lessons")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("lesson_id", .uuid, .required, .references("lessons", "id"))
            .field("booking_id", .uuid, .required, .references("bookings", "id"))
            .field("confirmed_at", .datetime, .required)
            .field("actual_starts_at", .datetime)
            .field("actual_ends_at", .datetime)
            .field("notes", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("confirmed_lessons").delete()
    }
}
