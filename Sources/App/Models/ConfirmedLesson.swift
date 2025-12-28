import Vapor
import Fluent

/// A persistent record that a lesson actually took place.
///
/// This is *not* the booking itself – it's a log entry created when the
/// instructor confirms that a lesson has started / happened. It survives
/// calendar edits and is the source of truth for "Past confirmed lessons".
final class ConfirmedLesson: Model, @unchecked Sendable, Content {
    static let schema = "confirmed_lessons"

    @ID(key: .id)
    var id: UUID?

    /// The student (user) this confirmed lesson belongs to.
    @Parent(key: "user_id")
    var user: User

    /// The lesson slot that this confirmation refers to.
    @Parent(key: "lesson_id")
    var lesson: Lesson

    /// The booking that led to this confirmed lesson.
    /// (We keep this even if the booking is later soft-deleted.)
    @Parent(key: "booking_id")
    var booking: Booking

    enum Status: String, CaseIterable, Codable {
        case attended
        case noShow
        case cancelled

        /// Lowercase display string if you ever want one.
        var display: String {
            switch self {
            case .attended: return "attended"
            case .noShow: return "no show"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Normalize/validate an incoming status string.
    static func parseStatus(_ raw: String) -> Status? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Status(rawValue: trimmed) { return direct }
        // Accept a couple of common variants safely.
        switch trimmed.lowercased() {
        case "no show", "no_show", "noshow": return .noShow
        default: return nil
        }
    }

    /// Attendance status for this confirmed lesson: e.g. "attended" or "noShow".
    @Field(key: "status")
    var status: String

    /// Typed view of `status`.
    var statusValue: Status {
        get { Status(rawValue: status) ?? .attended }
        set { status = newValue.rawValue }
    }

    /// When the instructor actually confirmed the lesson.
    @Timestamp(key: "confirmed_at", on: .create)
    var confirmedAt: Date?

    /// Optional snapshot of the actual start time.
    @OptionalField(key: "actual_starts_at")
    var actualStartsAt: Date?

    /// Optional snapshot of the actual end time.
    @OptionalField(key: "actual_ends_at")
    var actualEndsAt: Date?

    /// Optional free-form notes (e.g. "arrived late", "test prep").
    @OptionalField(key: "notes")
    var notes: String?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        lessonID: UUID,
        bookingID: UUID,
        confirmedAt: Date? = nil,
        actualStartsAt: Date? = nil,
        actualEndsAt: Date? = nil,
        notes: String? = nil,
        status: Status = .attended
    ) {
        self.id = id
        self.$user.id = userID
        self.$lesson.id = lessonID
        self.$booking.id = bookingID
        self.confirmedAt = confirmedAt
        self.actualStartsAt = actualStartsAt
        self.actualEndsAt = actualEndsAt
        self.notes = notes
        self.status = status.rawValue
    }

    struct Public: Content {
        var id: UUID
        var userID: UUID
        var lessonID: UUID
        var bookingID: UUID
        var confirmedAt: Date
        var actualStartsAt: Date?
        var actualEndsAt: Date?
        var notes: String?
        var status: String
    }

    func asPublic() throws -> Public {
        Public(
            id: try requireID(),
            userID: $user.id,
            lessonID: $lesson.id,
            bookingID: $booking.id,
            confirmedAt: confirmedAt ?? Date(),
            actualStartsAt: actualStartsAt,
            actualEndsAt: actualEndsAt,
            notes: notes,
            status: statusValue.rawValue
        )
    }
}
