import Fluent
import Vapor

final class MOTRecord: Model, Content, @unchecked Sendable {
    static let schema = "mot_records"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "test_date")
    var testDate: Date

    @OptionalField(key: "odometer")
    var odometer: Int?

    @OptionalField(key: "cost")
    var cost: Decimal?

    /// "pass" | "fail"
    @Field(key: "result")
    var result: String

    /// Set to testDate + 1 year when result == "pass", nil on fail.
    @OptionalField(key: "expiry_date")
    var expiryDate: Date?

    @OptionalField(key: "advisories")
    var advisories: String?

    /// Repairs required to pass — distinct from advisories, which are warnings only.
    @OptionalField(key: "essential_repairs")
    var essentialRepairs: String?

    @OptionalField(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        testDate: Date,
        odometer: Int? = nil,
        cost: Decimal? = nil,
        result: String,
        expiryDate: Date? = nil,
        advisories: String? = nil,
        essentialRepairs: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.testDate = testDate
        self.odometer = odometer
        self.cost = cost
        self.result = result
        self.expiryDate = expiryDate
        self.advisories = advisories
        self.essentialRepairs = essentialRepairs
        self.notes = notes
    }
}
