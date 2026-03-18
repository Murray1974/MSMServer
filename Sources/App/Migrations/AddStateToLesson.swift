import Fluent

struct AddStateToLesson: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lessons")
            .field("state", .string, .required, .sql(.default("available")))
            .update()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lessons")
            .deleteField("state")
            .update()
    }
}
