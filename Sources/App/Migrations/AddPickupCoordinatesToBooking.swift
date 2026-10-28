import Fluent

struct AddPickupCoordinatesToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("bookings")
            .field("pickup_latitude", .double)
            .field("pickup_longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("bookings")
            .deleteField("pickup_latitude")
            .deleteField("pickup_longitude")
            .update()
    }
}
