import Fluent

struct AddDropoffCoordinatesToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("bookings")
            .field("dropoff_latitude", .double)
            .field("dropoff_longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("bookings")
            .deleteField("dropoff_latitude")
            .deleteField("dropoff_longitude")
            .update()
    }
}
