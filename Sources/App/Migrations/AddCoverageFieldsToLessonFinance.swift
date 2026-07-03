import Fluent

struct AddCoverageFieldsToLessonFinance: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_finance")
            .field("finance_status", .string, .required, .sql(.default("not_covered")))
            .field("covered_at", .datetime)
            .field("reserved_amount", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_finance")
            .deleteField("finance_status")
            .deleteField("covered_at")
            .deleteField("reserved_amount")
            .update()
    }
}
