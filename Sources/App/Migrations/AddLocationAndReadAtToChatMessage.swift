import Fluent

struct AddLocationAndReadAtToChatMessage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("chat_messages")
            .field("latitude", .double)
            .field("longitude", .double)
            .field("read_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("chat_messages")
            .deleteField("latitude")
            .deleteField("longitude")
            .deleteField("read_at")
            .update()
    }
}
