import Fluent

struct CreateLedgerEntry: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("ledger_entries")
            .id()
            .field("student_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("instructor_id", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("lesson_id", .uuid, .references("lessons", "id", onDelete: .setNull))
            .field("type", .string, .required)
            .field("amount", .sql(raw: "NUMERIC(10,2)"), .required)
            .field("payment_method", .string)
            .field("note", .string)
            .field("effective_date", .datetime, .required)
            .field("created_at", .datetime)
            .field("created_by_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("ledger_entries").delete()
    }
}
