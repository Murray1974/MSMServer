import Fluent

struct CreateVehicleDocument: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vehicle_documents")
            .id()
            .field("instructor_id",                  .uuid,     .required,
                   .references("users", "id", onDelete: .cascade))
            .field("road_tax_due_date",               .datetime)
            .field("road_tax_cost",                   .sql(raw: "NUMERIC(10,2)"))
            .field("road_tax_reminder_days_before",    .int,      .required, .custom("DEFAULT 14"))
            .field("insurance_provider",              .string)
            .field("insurance_policy_number",         .string)
            .field("insurance_renewal_date",          .datetime)
            .field("insurance_annual_cost",           .sql(raw: "NUMERIC(10,2)"))
            .field("insurance_reminder_days_before",   .int,      .required, .custom("DEFAULT 14"))
            .field("updated_at",                      .datetime)
            .unique(on: "instructor_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vehicle_documents").delete()
    }
}
