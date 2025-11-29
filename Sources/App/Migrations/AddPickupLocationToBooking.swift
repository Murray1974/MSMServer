import Fluent

struct AddPickupLocationToBooking: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("bookings")
            .field("pickup_location", .string)
            .field("pickup_source", .string)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("bookings")
            .deleteField("pickup_location")
            .deleteField("pickup_source")
            .update()
    }
}
