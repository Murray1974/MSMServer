import Fluent

struct CreateTestRoute: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_routes")
            .id()
            .field("instructor_id", .uuid, .required,
                   .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("gpx_path", .string)
            .field("gpx_original_filename", .string)
            .field("directions_path", .string)
            .field("directions_original_filename", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_routes").delete()
    }
}
