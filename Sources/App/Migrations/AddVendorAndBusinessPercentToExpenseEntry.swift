import Fluent

struct AddVendorAndBusinessPercentToExpenseEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("expense_entries")
            .field("vendor",               .string)
            .field("business_use_percent", .double, .custom("DEFAULT 100.0"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("expense_entries")
            .deleteField("vendor")
            .deleteField("business_use_percent")
            .update()
    }
}
