import Fluent

struct AddDiscountFieldsToLessonFinance: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_finance")
            .field("discount_amount", .sql(raw: "NUMERIC(10,2)"))
            .field("discount_reason", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_finance")
            .deleteField("discount_amount")
            .deleteField("discount_reason")
            .update()
    }
}
