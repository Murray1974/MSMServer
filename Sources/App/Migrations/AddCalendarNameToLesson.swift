import Fluent

struct AddCalendarNameToLesson: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lessons")
            .field("calendar_name", .string, .required, .sql(.default("Untitled")))
            .update()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("lessons")
            .deleteField("calendar_name")
            .update()
    }
}
