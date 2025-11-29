import Fluent

struct CreateBooking: Migration {
    func prepare(on db: Database) -> EventLoopFuture<Void> {
        db.schema("bookings")
            .id() // ← important: creates 'id' UUID PK column
            .field("user_id", .uuid, .required,
                   .references("users", "id", onDelete: .cascade))
            .field("lesson_id", .uuid, .required,
                   .references("lessons", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("pickup_location", .string)
            .field("pickup_source", .string)
            .unique(on: "user_id", "lesson_id") // prevent duplicates (optional but recommended)
            .create()
    }

    func revert(on db: Database) -> EventLoopFuture<Void> {
        db.schema("bookings").delete()
    }
}
