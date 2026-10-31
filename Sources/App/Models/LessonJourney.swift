import Fluent
import Vapor

/// One point in a recorded lesson route. Stored as a `jsonb` array on `LessonJourney`
/// rather than a child table — the full route is only ever read or written as a single
/// unit (one batch upload from the instructor's phone, one full-route render on the map
/// review screen), never queried point-by-point.
struct RoutePoint: Codable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    /// GPS-reported ground speed in mph, nil when the device reported an invalid
    /// reading (CLLocation.speed < 0) — converted to mph client-side at capture time.
    let speedMph: Double?
}

/// A single stationary period (≥5 minutes) detected within a recorded route — purely
/// informational, does not split the journey into separate recordings.
struct StopMarker: Codable {
    let latitude: Double
    let longitude: Double
    let arrivedAt: Date
    let departedAt: Date
    let durationMinutes: Int
}

/// A sudden speed change detected from consecutive GPS speed samples — a GPS-only
/// heuristic (not accelerometer-fused), so treat as approximate. See
/// `detectDrivingEvents` in routes.swift for the detection thresholds.
struct DrivingEvent: Codable {
    /// "hardBrake" | "rapidAccel"
    let type: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let fromMph: Double
    let toMph: Double
    let deltaMph: Double
}

/// The complete recorded GPS route for one lesson, uploaded as a single batch by the
/// instructor's phone once the journey finishes (geofence reached, manually ended, or
/// auto-expired) — see JourneyTrackingManager (Instructor-server-side-app) for how the
/// route is captured client-side, and `POST /instructor/tracking/journey` for the
/// upload. Unlike `TrackingSession`, this row only ever gets created once, fully formed,
/// at upload time — there's no "in progress" server-side state to track.
///
/// `bookingID` is a plain field (not `@Parent`), matching `TrackingSession`'s pattern —
/// every read site already has the booking resolved via its own query.
final class LessonJourney: Model, Content, @unchecked Sendable {
    static let schema = "lesson_journeys"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "booking_id")
    var bookingID: UUID

    @Field(key: "started_at")
    var startedAt: Date

    @Field(key: "ended_at")
    var endedAt: Date

    /// "geofence" | "manual" | "auto_expired"
    @Field(key: "ended_reason")
    var endedReason: String

    @Field(key: "points")
    var points: [RoutePoint]

    @Field(key: "distance_miles")
    var distanceMiles: Double

    @Field(key: "stop_markers")
    var stopMarkers: [StopMarker]

    @Field(key: "top_speed_mph")
    var topSpeedMph: Double

    @Field(key: "average_speed_mph")
    var averageSpeedMph: Double

    @Field(key: "driving_events")
    var drivingEvents: [DrivingEvent]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        bookingID: UUID,
        startedAt: Date,
        endedAt: Date,
        endedReason: String,
        points: [RoutePoint],
        distanceMiles: Double,
        stopMarkers: [StopMarker],
        topSpeedMph: Double,
        averageSpeedMph: Double,
        drivingEvents: [DrivingEvent]
    ) {
        self.id = id
        self.bookingID = bookingID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endedReason = endedReason
        self.points = points
        self.distanceMiles = distanceMiles
        self.stopMarkers = stopMarkers
        self.topSpeedMph = topSpeedMph
        self.averageSpeedMph = averageSpeedMph
        self.drivingEvents = drivingEvents
    }
}
