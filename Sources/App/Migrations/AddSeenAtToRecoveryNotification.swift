import Fluent

struct AddSeenAtToRecoveryNotification: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("recovery_notifications")
            .field("seen_at", .datetime)
            .update()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("recovery_notifications")
            .deleteField("seen_at")
            .update()
    }
}
