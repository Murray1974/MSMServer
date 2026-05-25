import Fluent

struct AddDropoffLocationToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("bookings")
            .field("dropoff_location", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("bookings")
            .deleteField("dropoff_location")
            .update()
    }
}
