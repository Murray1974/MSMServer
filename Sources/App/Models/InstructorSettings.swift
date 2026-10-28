import Fluent
import Vapor

/// Singleton row holding instructor-configurable pricing defaults. Only ever one row
/// exists (fetched via `.first()`), created lazily on first access rather than seeded,
/// so no migration-time data decision is needed.
final class InstructorSettings: Model, Content, @unchecked Sendable {
    static let schema = "instructor_settings"

    @ID(key: .id)
    var id: UUID?

    /// The hourly rate (in pence) stamped onto brand-new students at registration time.
    /// Changing this never touches any existing StudentProfile.hourlyRatePence — each
    /// student's rate is already its own independent field, so existing clients simply
    /// keep whatever rate they're already on (the "legacy pricing" behaviour).
    @Field(key: "current_hourly_rate_pence")
    var currentHourlyRatePence: Int

    /// Instructor-entered contact + vehicle details, surfaced to students via
    /// GET /student/instructor-info (the "Your instructor" screen). All optional —
    /// a field left blank just doesn't render on the student side.
    @OptionalField(key: "contact_phone")
    var contactPhone: String?

    @OptionalField(key: "vehicle_registration")
    var vehicleRegistration: String?

    @OptionalField(key: "vehicle_make")
    var vehicleMake: String?

    @OptionalField(key: "vehicle_model")
    var vehicleModel: String?

    @OptionalField(key: "vehicle_colour")
    var vehicleColour: String?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        currentHourlyRatePence: Int = 4500,
        contactPhone: String? = nil,
        vehicleRegistration: String? = nil,
        vehicleMake: String? = nil,
        vehicleModel: String? = nil,
        vehicleColour: String? = nil
    ) {
        self.id = id
        self.currentHourlyRatePence = currentHourlyRatePence
        self.contactPhone = contactPhone
        self.vehicleRegistration = vehicleRegistration
        self.vehicleMake = vehicleMake
        self.vehicleModel = vehicleModel
        self.vehicleColour = vehicleColour
    }

    /// Fetches the singleton settings row, creating it with the default rate if it
    /// doesn't exist yet.
    static func current(on db: Database) async throws -> InstructorSettings {
        if let existing = try await InstructorSettings.query(on: db).first() {
            return existing
        }
        let created = InstructorSettings(currentHourlyRatePence: 4500)
        try await created.save(on: db)
        return created
    }

    /// Convenience for call sites that only need the rate, not the full row.
    static func currentRatePence(on db: Database) async throws -> Int {
        try await InstructorSettings.current(on: db).currentHourlyRatePence
    }
}
