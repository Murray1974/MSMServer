import Fluent

struct CreateUserToken: Migration {
    func prepare(on db: Database) -> EventLoopFuture<Void> {
        db.schema("user_tokens")
            .id()
            .field("value", .string, .required)
            .field("user_id", .uuid, .required,
                   .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime)  // optional
            .unique(on: "value")
            .create()
    }

    func revert(on db: Database) -> EventLoopFuture<Void> {
        db.schema("user_tokens").delete()
    }
}
