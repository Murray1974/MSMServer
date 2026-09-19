import Fluent

struct CreateServiceRecord: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("service_records")
            .id()
            .field("instructor_id",     .uuid,     .required,
                   .references("users", "id", onDelete: .cascade))
            .field("service_date",      .datetime, .required)
            .field("odometer",          .int)
            .field("service_type",      .string,   .required)
            .field("cost",              .sql(raw: "NUMERIC(10,2)"))
            .field("what_was_covered",  .string)
            .field("advisories",        .string)
            .field("notes",             .string)
            .field("created_at",        .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("service_records").delete()
    }
}
