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
    /// Yaw rotation rate (deg/s), from the phone's fused motion sensors
    /// (CMDeviceMotion.attitude.yaw, gyro+accelerometer+compass), sampled at the same
    /// moment as this GPS fix. World-referenced (rotation about the vertical/gravity
    /// axis), so — unlike GPS course — it stays meaningful even when the car is moving
    /// too slowly for GPS bearing to be reliable; this is what makes manoeuvre
    /// detection (see `detectManoeuvres` in routes.swift) possible at parking speeds.
    /// Only populated while the phone is mounted securely enough to be rigid with the
    /// car (currently assumed true for this single-instructor app — see CLAUDE.md).
    /// nil for journeys recorded before this was added, or if CoreMotion was
    /// unavailable.
    let yawRateDegPerSec: Double?
    /// Magnitude of gravity-removed acceleration (g), from
    /// CMDeviceMotion.userAcceleration. Frame-independent (doesn't depend on how the
    /// phone is mounted/tilted), used to spot a sharp acceleration/deceleration (e.g.
    /// an emergency stop) with more precision than GPS speed deltas alone, which are
    /// limited by GPS fix spacing/timing.
    let accelMagnitudeG: Double?

    init(latitude: Double, longitude: Double, timestamp: Date, speedMph: Double?,
         yawRateDegPerSec: Double? = nil, accelMagnitudeG: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.speedMph = speedMph
        self.yawRateDegPerSec = yawRateDegPerSec
        self.accelMagnitudeG = accelMagnitudeG
    }
}

/// A low-speed, high-steering-activity episode detected from fused GPS + motion-sensor
/// data — e.g. a turn-in-the-road or a parking manoeuvre. See `detectManoeuvres` in
/// routes.swift for the detection logic and its honest limits: GPS speed has no sign
/// (forward vs reverse is never directly knowable), so this can reliably flag *that* a
/// manoeuvre happened and roughly how much turning it involved, but can't reliably tell
/// parallel parking apart from bay parking or a reverse-and-pull-up — those all share
/// the same low-speed/high-rotation/pause-point signature from the sensors available.
struct ManoeuvreEvent: Codable {
    /// "turnInRoad" (large net rotation, e.g. a three-point turn) |
    /// "parkingManoeuvre" (smaller rotation, e.g. parallel/bay parking or a reverse) |
    /// "emergencyStop" (sharp deceleration to a stop — the one type this can identify
    /// with real confidence, since it doesn't depend on knowing travel direction)
    let type: String
    let latitude: Double
    let longitude: Double
    let startedAt: Date
    let endedAt: Date
    /// Total net heading change across the episode, in degrees (unsigned). 0 for
    /// "emergencyStop".
    let rotationDegrees: Double
    /// Count of near-complete stops within the episode (likely gear-change points
    /// between forward/reverse phases). 0 for "emergencyStop".
    let pauseCount: Int
    /// "left" | "right", from the sign of net yaw rotation before it's made unsigned
    /// for `rotationDegrees`. nil for "emergencyStop" (no rotation at all) and for any
    /// episode whose net rotation rounds to ~0° (wheel wiggled both ways and cancelled
    /// out — no dominant direction to report).
    /// Sign convention CONFIRMED 11 Nov 2026 against a real labelled test journey: a
    /// turn-in-the-road done forward-right, reverse-left, forward-right (one
    /// continuous clockwise rotation — alternating lock direction between forward and
    /// reverse phases is exactly what keeps a three-point turn rotating the same way
    /// throughout) was detected as "right", matching the actual clockwise sweep. If a
    /// future labelled journey ever contradicts this, flip the single comparison in
    /// `detectManoeuvres`'s `closeWindow` (routes.swift) rather than anything here.
    let direction: String?
    /// Instructor's own retroactive verdict — nil until reviewed on the journey map
    /// screen. Confirmed against a real lesson on 10 Nov 2026: GPS+motion data alone
    /// can't reliably tell a genuine manoeuvre apart from, e.g., a small loop through
    /// ordinary side roads to turn the car around — both look like a sequence of
    /// low-speed turns. This is the ground truth that heuristic can't produce on its
    /// own. `carryOverManoeuvreConfirmations` (routes.swift) preserves this across a
    /// re-detection (threshold change, reanalyze) by matching on overlapping time
    /// windows, since a plain re-run would otherwise regenerate every event fresh with
    /// this nil.
    var confirmed: Bool? = nil
    /// The instructor's own label for which real manoeuvre this was — parallel park,
    /// turn in the road, etc. — picked from a fixed list after confirming `confirmed =
    /// true`. nil whenever `confirmed` isn't `true` (rejecting or un-reviewing clears
    /// it). This is the ground truth `type`/`rotationDegrees` can't produce alone (see
    /// the doc comment above `type`) — collecting enough of these against the detected
    /// rotation/pauseCount/duration shape is what future tuning of the
    /// turnInRoad/parkingManoeuvre split should be based on, instead of guessing at
    /// another threshold.
    var confirmedType: String? = nil
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

/// A sudden speed change, or a sharp turn, detected purely from GPS samples — no
/// accelerometer involved, so treat as approximate. See `detectDrivingEvents` and
/// `detectHarshCornering` in routes.swift for the detection thresholds.
struct DrivingEvent: Codable {
    /// "hardBrake" | "rapidAccel" | "harshCornering"
    let type: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    /// For "harshCornering", fromMph == toMph (speed at the turn) and deltaMph is 0 —
    /// there's no speed-delta concept for a turn; see `lateralG` instead.
    let fromMph: Double
    let toMph: Double
    let deltaMph: Double
    /// Estimated lateral g-force, only set for "harshCornering" events.
    let lateralG: Double?

    init(type: String, latitude: Double, longitude: Double, timestamp: Date,
         fromMph: Double, toMph: Double, deltaMph: Double, lateralG: Double? = nil) {
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.fromMph = fromMph
        self.toMph = toMph
        self.deltaMph = deltaMph
        self.lateralG = lateralG
    }
}

/// One point's resolved speed limit — see `SpeedLimitLookupService` for how this is
/// looked up (snapped to the nearest OpenStreetMap road) and what `isEstimated` means.
/// Populated lazily, only once `POST .../journey/speed-limits/refresh` is called — never
/// at upload/finalize time (see that service's doc comment for why).
struct SpeedLimitPoint: Codable {
    let timestamp: Date
    /// nil when no road was found within snapping distance, or a nearby road's limit
    /// couldn't be resolved at all (an untagged trunk/primary/secondary/tertiary road —
    /// see `SpeedLimitLookupService`).
    let speedLimitMph: Double?
    let isEstimated: Bool
    let roadName: String?
}

/// A sustained period of travelling faster than the resolved speed limit for that road.
/// Only ever built from points with a non-nil, resolved `SpeedLimitPoint` — an "unknown
/// limit" point can't produce a speeding event by definition.
struct SpeedingEvent: Codable {
    let startedAt: Date
    let endedAt: Date
    let latitude: Double
    let longitude: Double
    let maxSpeedMph: Double
    let speedLimitMph: Double
    let isEstimatedLimit: Bool
    let roadName: String?
}

/// One instructor-marked "mock test" window, analysed in isolation from the rest of the
/// lesson's own route/metrics. The window is carved out of the same single continuous
/// recording — not a second, independently-run recording — by slicing the lesson's
/// already-captured points to the marked start/end timestamps and re-running the exact
/// same detection functions (`routeDistanceMiles`, `detectDrivingEvents`,
/// `detectHarshCornering`, `detectManoeuvres`, etc., see `POST /instructor/tracking/journey`
/// in routes.swift) over just that slice. The parent `LessonJourney`'s own fields are
/// computed over the full route regardless of any mock test windows inside it.
struct MockTestResult: Codable {
    let startedAt: Date
    let endedAt: Date
    let points: [RoutePoint]
    let distanceMiles: Double
    let topSpeedMph: Double
    let averageSpeedMph: Double
    let drivingEvents: [DrivingEvent]
    let manoeuvreEvents: [ManoeuvreEvent]
}

/// The recorded GPS route for one lesson, uploaded by the instructor's phone — see
/// JourneyTrackingManager (Instructor-server-side-app) for how the route is captured
/// client-side, and `POST /instructor/tracking/journey` for the upload. One row per
/// booking, upserted: a periodic sync while the lesson is still in progress
/// (`endedReason == "in_progress"`) overwrites the same row with the fuller point set
/// recorded so far, and the eventual terminal call (geofence/manual/auto_expired)
/// overwrites it one last time with the finished route.
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

    /// "geofence" | "manual" | "auto_expired" | "in_progress" (periodic safety-net sync
    /// while the lesson is still being recorded — not a terminal state)
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

    @Field(key: "manoeuvre_events")
    var manoeuvreEvents: [ManoeuvreEvent]

    /// Instructor-marked mock-test windows within this same recording — see
    /// `MockTestResult`'s doc comment. Empty for the vast majority of lessons.
    @Field(key: "mock_tests")
    var mockTests: [MockTestResult]

    /// true for a journey started from the app's standalone "Test Journey" control
    /// (no real Booking behind `bookingID` — just a freshly-generated UUID), used for
    /// calibrating detection thresholds outside of a real lesson. false (the default)
    /// for every normal lesson journey.
    @Field(key: "is_test_journey")
    var isTestJourney: Bool

    /// Lazily-populated speed limit per point — see `SpeedLimitPoint`'s doc comment.
    /// Empty until the journey map screen has been opened at least once.
    @Field(key: "speed_limit_points")
    var speedLimitPoints: [SpeedLimitPoint]

    @Field(key: "speeding_events")
    var speedingEvents: [SpeedingEvent]

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
        drivingEvents: [DrivingEvent],
        manoeuvreEvents: [ManoeuvreEvent] = [],
        mockTests: [MockTestResult] = [],
        isTestJourney: Bool = false,
        speedLimitPoints: [SpeedLimitPoint] = [],
        speedingEvents: [SpeedingEvent] = []
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
        self.manoeuvreEvents = manoeuvreEvents
        self.mockTests = mockTests
        self.isTestJourney = isTestJourney
        self.speedLimitPoints = speedLimitPoints
        self.speedingEvents = speedingEvents
    }
}
