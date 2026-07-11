import Fluent

struct AddAccountHoldToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("account_hold", .bool, .required, .custom("DEFAULT FALSE"))
            .field("account_hold_reason", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("account_hold")
            .deleteField("account_hold_reason")
            .update()
    }
}
