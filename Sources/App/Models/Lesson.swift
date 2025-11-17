import Vapor
import Fluent

final class Lesson: Model, Content {
    static let schema = "lessons"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "title")
    var title: String

    @Field(key: "starts_at")
    var startsAt: Date

    @Field(key: "ends_at")
    var endsAt: Date

    @Field(key: "capacity")
    var capacity: Int

    @Field(key: "calendar_name")
    var calendarName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        title: String,
        startsAt: Date,
        endsAt: Date,
        capacity: Int,
        calendarName: String = "Untitled"
    ) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.capacity = capacity
        self.calendarName = calendarName
    }
}

// Public (safe) payload for clients, with availability
extension Lesson {
    struct Public: Content {
        let id: UUID?
        let title: String
        let startsAt: Date
        let endsAt: Date
        let capacity: Int
        let available: Int
    }

    func asPublic(available: Int) -> Public {
        .init(id: id, title: title, startsAt: startsAt, endsAt: endsAt, capacity: capacity, available: available)
    }
}

// Concurrency
extension Lesson: @unchecked Sendable {}
