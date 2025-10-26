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

    // Audit trail
    @OptionalParent(key: "cancelled_by")
    var cancelledBy: User?

    @Timestamp(key: "cancelled_at", on: .none)
    var cancelledAt: Date?

    // Soft-delete column; calling `delete(on:)` will set this (not hard-delete)
    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue, lessonID: Lesson.IDValue) {
        self.id = id
        self.$user.id = userID
        self.$lesson.id = lessonID
    }
}

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


// Fluent models are not Sendable by default
extension Booking: @unchecked Sendable {}
