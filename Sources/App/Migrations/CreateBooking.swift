import Fluent

struct CreateBooking: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("bookings")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("lesson_id", .uuid, .required, .references("lessons", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            // One booking per (user, lesson)
            .unique(on: "user_id", "lesson_id")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("bookings").delete()
    }
}
