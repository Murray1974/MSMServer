import Fluent

struct AddRescheduledToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("bookings")
            .field("rescheduled", .bool)
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("bookings")
            .deleteField("rescheduled")
            .update()
    }
}
