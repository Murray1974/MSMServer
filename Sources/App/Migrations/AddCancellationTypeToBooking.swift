import Fluent

struct AddCancellationTypeToBooking: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("bookings")
            .field("cancellation_type", .string)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("bookings")
            .deleteField("cancellation_type")
            .update()
    }
}
