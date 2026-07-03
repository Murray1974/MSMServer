import Fluent

struct CreateRecoveryNotification: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("recovery_notifications")
            .id()
            .field("clients", .array(of: .string), .required)
            .field("message", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("recovery_notifications").delete()
    }
}
