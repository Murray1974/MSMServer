import Fluent
import Vapor

final class ServiceRecord: Model, Content, @unchecked Sendable {
    static let schema = "service_records"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "service_date")
    var serviceDate: Date

    @OptionalField(key: "odometer")
    var odometer: Int?

    @Field(key: "service_type")
    var serviceType: String

    @OptionalField(key: "cost")
    var cost: Decimal?

    @OptionalField(key: "what_was_covered")
    var whatWasCovered: String?

    @OptionalField(key: "advisories")
    var advisories: String?

    @OptionalField(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        serviceDate: Date,
        odometer: Int? = nil,
        serviceType: String,
        cost: Decimal? = nil,
        whatWasCovered: String? = nil,
        advisories: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.serviceDate = serviceDate
        self.odometer = odometer
        self.serviceType = serviceType
        self.cost = cost
        self.whatWasCovered = whatWasCovered
        self.advisories = advisories
        self.notes = notes
    }
}
