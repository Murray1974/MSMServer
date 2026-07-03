import Fluent

struct AddVoidFieldsToLedgerEntry: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("ledger_entries")
            .field("voided_at", .datetime)
            .field("void_reason", .string)
            .update()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("ledger_entries")
            .deleteField("voided_at")
            .deleteField("void_reason")
            .update()
    }
}
