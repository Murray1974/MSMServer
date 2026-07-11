import Fluent

struct AddPaymentEnforcementFieldsToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("bookings")
            .field("payment_reminder_sent_at", .datetime)
            .field("payment_warning_sent_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("bookings")
            .deleteField("payment_reminder_sent_at")
            .deleteField("payment_warning_sent_at")
            .update()
    }
}
