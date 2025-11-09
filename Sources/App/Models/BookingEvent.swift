import Vapor
import Fluent

final class BookingEvent: Model, Content, @unchecked Sendable {
    static let schema = "booking_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "type")
    var type: String

    @OptionalField(key: "user_id")
    var userID: UUID?

    @OptionalField(key: "lesson_id")
    var lessonID: UUID?

    @OptionalField(key: "booking_id")
    var bookingID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        type: String,
        userID: UUID? = nil,
        lessonID: UUID? = nil,
        bookingID: UUID? = nil
    ) {
        self.type = type
        self.userID = userID
        self.lessonID = lessonID
        self.bookingID = bookingID
    }
}
