import Fluent
import Vapor

/// A live-location-sharing window for one booking — created automatically by
/// TrackingSchedulerLifecycle ~10 minutes before the lesson starts, and ended either
/// manually (instructor taps "End") or automatically once the lesson's end time passes,
/// whichever happens first. `bookingID` is a plain field (not `@Parent`) since every
/// read site already has the student/lesson resolved via the booking query itself.
final class TrackingSession: Model, Content, @unchecked Sendable {
    static let schema = "tracking_sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "booking_id")
    var bookingID: UUID

    @Field(key: "started_at")
    var startedAt: Date

    /// Mirrors the lesson's endsAt at creation time — this is what auto-expiry checks
    /// against, independent of whether the instructor ever manually ends the session.
    @Field(key: "ends_at")
    var endsAt: Date

    @OptionalField(key: "ended_at")
    var endedAt: Date?

    /// "manual" | "auto_expired" — nil while the session is still active.
    @OptionalField(key: "ended_reason")
    var endedReason: String?

    @OptionalField(key: "last_latitude")
    var lastLatitude: Double?

    @OptionalField(key: "last_longitude")
    var lastLongitude: Double?

    @OptionalField(key: "last_updated_at")
    var lastUpdatedAt: Date?

    /// Drive-time ETA to the pickup address, computed client-side by the instructor
    /// app via MapKit routing and sent along with each location ping — absolute
    /// timestamp rather than a duration so it doesn't go stale between pings.
    @OptionalField(key: "estimated_arrival_at")
    var estimatedArrivalAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    var isActive: Bool { endedAt == nil }

    init() {}

    init(
        id: UUID? = nil,
        bookingID: UUID,
        startedAt: Date,
        endsAt: Date
    ) {
        self.id = id
        self.bookingID = bookingID
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}
