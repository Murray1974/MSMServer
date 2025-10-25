import Vapor
import Fluent

final class Booking: Model, Content {
    static let schema = "bookings"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "lesson_id")
    var lesson: Lesson

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue, lessonID: Lesson.IDValue) {
        self.id = id
        self.$user.id = userID
        self.$lesson.id = lessonID
    }
}

// Safe payload for API
extension Booking {
    struct Public: Content {
        let id: UUID?
        let bookedAt: Date?
        let lesson: Lesson.Public
    }

    var asPublicMinimal: Public {
        .init(id: id, bookedAt: createdAt, lesson: lesson.asPublic(available: 0))
    }
}

// Fluent models are event-loop bound
extension Booking: @unchecked Sendable {}
