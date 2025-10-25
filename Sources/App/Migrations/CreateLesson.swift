import Fluent

struct CreateLesson: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("lessons")
            .id()
            .field("title", .string, .required)
            .field("starts_at", .datetime, .required)
            .field("ends_at", .datetime, .required)
            .field("capacity", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("lessons").delete()
    }
}
