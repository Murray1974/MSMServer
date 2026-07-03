import Fluent

struct CreateExpenseEntry: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("expense_entries")
            .id()
            .field("instructor_id", .uuid, .required, .references("users", "id", onDelete: .restrict))
            .field("amount", .sql(raw: "NUMERIC(10,2)"), .required)
            .field("category", .string, .required)
            .field("note", .string)
            .field("expense_date", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("expense_entries").delete()
    }
}
