import Fluent

struct AddFullChargeAppliedToLessonFinance: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("lesson_finance")
            .field("full_charge_applied", .bool)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("lesson_finance")
            .deleteField("full_charge_applied")
            .update()
    }
}
