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

    @Field(key: "state")
    var state: String

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
        calendarName: String = "MSM Available",
        state: String = "available"
    ) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.capacity = capacity
        self.calendarName = calendarName
        self.state = state
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
        let state: String
    }

    func asPublic(available: Int) -> Public {
        .init(id: id, title: title, startsAt: startsAt, endsAt: endsAt, capacity: capacity, available: available, state: state)
    }
}

// Concurrency
extension Lesson: @unchecked Sendable {}


// MARK: - Recovery Event Logging

final class RecoveryEvent: Model, Content {
    static let schema = "recovery_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "lesson_id")
    var lessonID: UUID

    @Field(key: "stage")
    var stage: String // P1, P2, P3

    @Field(key: "result")
    var result: String // sent, stopped_filled, no_clients

    @Field(key: "client_count")
    var clientCount: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, lessonID: UUID, stage: String, result: String, clientCount: Int) {
        self.id = id
        self.lessonID = lessonID
        self.stage = stage
        self.result = result
        self.clientCount = clientCount
    }
}

extension RecoveryEvent: @unchecked Sendable {}
