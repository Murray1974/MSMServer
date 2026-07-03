import Fluent

struct CreateLessonFinance: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lesson_finance")
            .field("lesson_id", .uuid, .identifier(auto: false), .required, .references("lessons", "id", onDelete: .cascade))
            .field("student_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("instructor_id", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("duration_minutes", .int, .required)
            .field("hourly_rate_snapshot", .sql(raw: "NUMERIC(10,2)"), .required)
            .field("price_snapshot", .sql(raw: "NUMERIC(10,2)"), .required)
            .field("charge_status", .string, .required)
            .field("charged_ledger_entry_id", .uuid, .references("ledger_entries", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lesson_finance").delete()
    }
}
