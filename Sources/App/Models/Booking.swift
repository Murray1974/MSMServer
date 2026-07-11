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

    /// Optional alternate drop-off address for this booking, if different from pickup.
    @OptionalField(key: "dropoff_location")
    var dropoffLocation: String?

    /// Payment lifecycle status. Set to "pending" on creation, "confirmed"
    /// after a successful payment flow, or "paid" when manually marked by student.
    @OptionalField(key: "payment_status")
    var paymentStatus: String?

    /// Set to "late_cancellation" when the booking is cancelled within 48 hours
    /// of the lesson start time. Nil for normal (on-time) cancellations.
    @OptionalField(key: "cancellation_type")
    var cancellationType: String?

    /// Who initiated the cancellation:
    ///   "student_app"        — student cancelled via the student app
    ///   "instructor_cancel"  — instructor cancelled on the student's behalf
    ///   "instructor_personal"— instructor reclaimed the slot as personal
    @OptionalField(key: "cancellation_source")
    var cancellationSource: String?

    /// True when this booking was moved from a different lesson via the reschedule flow.
    @OptionalField(key: "rescheduled")
    var rescheduled: Bool?

    /// Set when the 48-hour payment reminder push was dispatched.
    @OptionalField(key: "payment_reminder_sent_at")
    var paymentReminderSentAt: Date?

    /// Set when the 7pm payment warning push was dispatched.
    @OptionalField(key: "payment_warning_sent_at")
    var paymentWarningSentAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        lessonID: UUID,
        durationMinutes: Int? = nil,
        actualEndsAt: Date? = nil,
        pickupLocation: String? = nil,
        pickupSource: String? = nil,
        paymentStatus: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.$lesson.id = lessonID
        self.durationMinutes = durationMinutes
        self.actualEndsAt = actualEndsAt
        self.pickupLocation = pickupLocation
        self.pickupSource = pickupSource
        self.paymentStatus = paymentStatus
    }
}
