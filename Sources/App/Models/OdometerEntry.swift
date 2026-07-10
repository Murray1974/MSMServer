import Fluent
import Vapor

final class OdometerEntry: Model, @unchecked Sendable {
    static let schema = "odometer_entries"

    @ID(key: .id) var id: UUID?
    @Field(key: "date")         var date: Date
    @OptionalField(key: "odometer") var odometer: Double?
    @Field(key: "daily_miles")  var dailyMiles: Double
    @Field(key: "is_gap_entry") var isGapEntry: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(date: Date, odometer: Double?, dailyMiles: Double, isGapEntry: Bool = false) {
        self.date = date
        self.odometer = odometer
        self.dailyMiles = dailyMiles
        self.isGapEntry = isGapEntry
    }
}
