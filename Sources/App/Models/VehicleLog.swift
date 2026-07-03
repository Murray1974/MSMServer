import Fluent
import Vapor

final class VehicleLog: Model, Content, @unchecked Sendable {
    static let schema = "vehicle_logs"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    /// Date this log entry was recorded.
    @Field(key: "log_date")
    var logDate: Date

    /// Odometer reading in miles at time of log.
    @OptionalField(key: "odometer")
    var odometer: Int?

    /// Whether tyre pressures were checked on this date.
    @Field(key: "tyre_pressure_checked")
    var tyrePressureChecked: Bool

    /// Set only when a service was carried out — used to compute Next Service Due.
    @OptionalField(key: "service_date")
    var serviceDate: Date?

    /// Fuel quantity in litres (Quick Fuel Log).
    @OptionalField(key: "fuel_litres")
    var fuelLitres: Decimal?

    /// Date the MOT was carried out — set when logging an MOT expense.
    @OptionalField(key: "last_mot_date")
    var lastMOTDate: Date?

    /// Date the MOT expires (lastMOTDate + 1 year) — used for alert calculations.
    @OptionalField(key: "mot_expiry_date")
    var motExpiryDate: Date?

    @OptionalField(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        logDate: Date,
        odometer: Int? = nil,
        tyrePressureChecked: Bool = false,
        serviceDate: Date? = nil,
        fuelLitres: Decimal? = nil,
        lastMOTDate: Date? = nil,
        motExpiryDate: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.logDate = logDate
        self.odometer = odometer
        self.tyrePressureChecked = tyrePressureChecked
        self.serviceDate = serviceDate
        self.fuelLitres = fuelLitres
        self.lastMOTDate = lastMOTDate
        self.motExpiryDate = motExpiryDate
        self.notes = notes
    }
}
