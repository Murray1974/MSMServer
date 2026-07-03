import Fluent

struct AddVehicleFieldsToExpenseEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("expense_entries")
            .field("receipt_path",    .string)
            .field("is_business_use", .bool, .required, .custom("DEFAULT TRUE"))
            .field("mileage",         .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("expense_entries")
            .deleteField("receipt_path")
            .deleteField("is_business_use")
            .deleteField("mileage")
            .update()
    }
}
