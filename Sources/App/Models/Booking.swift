import Vapor
import Fluent

final class Booking: Model, Content, @unchecked Sendable {
    static let schema = "bookings"

    @ID(key: .id)
    var id: UUID?

    // The student who owns this booking.
    @Parent(key: "user_id")
    var user: User

    // The lesson slot that this booking is attached to.
    @Parent(key: "lesson_id")
    var lesson: Lesson

    /// Optional duration in minutes for this booking. When nil, the full
    /// lesson duration is assumed.
    @OptionalField(key: "duration_minutes")
    var durationMinutes: Int?

    /// Optional override for when this booking actually ends. When nil,
    /// the lesson's `endsAt` is used instead.
    @OptionalField(key: "actual_ends_at")
    var actualEndsAt: Date?

    /// When the booking was created.
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// Soft-delete timestamp used for cancelled bookings.
    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?

    /// Optional free-form pickup location for this specific booking.
    @OptionalField(key: "pickup_location")
    var pickupLocation: String?

    /// Optional source for the pickup location, e.g. "home", "work",
    /// "college", or "other".
    @OptionalField(key: "pickup_source")
    var pickupSource: String?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        lessonID: UUID,
        durationMinutes: Int? = nil,
        actualEndsAt: Date? = nil,
        pickupLocation: String? = nil,
        pickupSource: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.$lesson.id = lessonID
        self.durationMinutes = durationMinutes
        self.actualEndsAt = actualEndsAt
        self.pickupLocation = pickupLocation
        self.pickupSource = pickupSource
    }
}
