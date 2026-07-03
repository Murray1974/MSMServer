import Fluent
import Vapor

final class MileageEntry: Model, @unchecked Sendable {
    static let schema = "mileage_entries"

    @ID(key: .id) var id: UUID?
    @Field(key: "date") var date: Date
    @Field(key: "miles") var miles: Double
    @Field(key: "purpose") var purpose: String
    @OptionalField(key: "from_location") var fromLocation: String?
    @OptionalField(key: "to_location") var toLocation: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(date: Date, miles: Double, purpose: String, fromLocation: String? = nil, toLocation: String? = nil) {
        self.date = date
        self.miles = miles
        self.purpose = purpose
        self.fromLocation = fromLocation
        self.toLocation = toLocation
    }
}
