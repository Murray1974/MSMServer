import Fluent

struct CreateBookingEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("booking_events")
            .id()
            .field("type", .string, .required)
            .field("user_id", .uuid)
            .field("lesson_id", .uuid)
            .field("booking_id", .uuid)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("booking_events").delete()
    }
}
