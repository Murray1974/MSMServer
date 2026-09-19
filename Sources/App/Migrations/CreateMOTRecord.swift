import Fluent

struct CreateMOTRecord: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("mot_records")
            .id()
            .field("instructor_id",     .uuid,     .required,
                   .references("users", "id", onDelete: .cascade))
            .field("test_date",         .datetime, .required)
            .field("odometer",          .int)
            .field("cost",              .sql(raw: "NUMERIC(10,2)"))
            .field("result",            .string,   .required)
            .field("expiry_date",       .datetime)
            .field("advisories",        .string)
            .field("essential_repairs", .string)
            .field("notes",             .string)
            .field("created_at",        .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("mot_records").delete()
    }
}
