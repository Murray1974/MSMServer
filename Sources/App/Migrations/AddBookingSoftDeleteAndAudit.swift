import Fluent

struct AddBookingSoftDeleteAndAudit: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("bookings")
            .field("cancelled_by", .uuid, .references("users", "id", onDelete: .setNull))
            .field("cancelled_at", .datetime)
            .field("deleted_at", .datetime)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("bookings")
            .deleteField("cancelled_by")
            .deleteField("cancelled_at")
            .deleteField("deleted_at")
            .update()
    }
}
