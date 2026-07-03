import Fluent

struct AddPaymentStatusToBooking: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("bookings")
            .field("payment_status", .string)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("bookings")
            .deleteField("payment_status")
            .update()
    }
}
