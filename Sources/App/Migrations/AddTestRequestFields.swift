import Fluent

struct AddTestRequestFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_appointments")
            .field("status", .string, .required, .sql(.default("'confirmed'")))
            .field("test_centre", .string)
            .field("submitted_by", .string, .required, .sql(.default("'instructor'")))
            .field("examiner", .string)
            .field("outcome", .string)   // "pass" | "fail"
            .field("faults", .string)    // JSON-encoded [String]
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_appointments")
            .deleteField("status")
            .deleteField("test_centre")
            .deleteField("submitted_by")
            .deleteField("examiner")
            .deleteField("outcome")
            .deleteField("faults")
            .update()
    }
}
