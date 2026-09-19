import Fluent

struct CreateInsuranceClaim: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("insurance_claims")
            .id()
            .field("instructor_id",           .uuid,     .required,
                   .references("users", "id", onDelete: .cascade))
            .field("claim_date",              .datetime, .required)
            .field("claim_description",       .string,   .required)
            .field("amount_claimed",          .sql(raw: "NUMERIC(10,2)"))
            .field("excess_paid",             .sql(raw: "NUMERIC(10,2)"))
            .field("excess_expense_entry_id", .uuid,
                   .references("expense_entries", "id", onDelete: .setNull))
            .field("status",                  .string,   .required, .custom("DEFAULT 'open'"))
            .field("notes",                   .string)
            .field("created_at",              .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("insurance_claims").delete()
    }
}
