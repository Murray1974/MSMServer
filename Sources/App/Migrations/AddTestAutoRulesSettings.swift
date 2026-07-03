import Fluent

struct AddTestAutoRulesSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("test_auto_reject_clash",    .bool,    .required, .custom("DEFAULT FALSE"))
            .field("test_min_weeks_enabled",    .bool,    .required, .custom("DEFAULT FALSE"))
            .field("test_min_weeks",            .int,     .required, .custom("DEFAULT 8"))
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("test_auto_reject_clash")
            .deleteField("test_min_weeks_enabled")
            .deleteField("test_min_weeks")
            .update()
    }
}
