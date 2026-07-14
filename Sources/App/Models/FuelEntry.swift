import Fluent
import Vapor

final class FuelEntry: Model, @unchecked Sendable {
    static let schema = "fuel_entries"

    @ID(key: .id) var id: UUID?
    @Field(key: "date")               var date: Date
    @Field(key: "vendor")             var vendor: String
    @Field(key: "total_cost")         var totalCost: Double        // £
    @Field(key: "pence_per_litre")    var pencePerLitre: Double
    @Field(key: "litres")             var litres: Double
    @Field(key: "odometer_reading")   var odometerReading: Double  // at-pump reading
    @Field(key: "is_full_tank")       var isFullTank: Bool
    @OptionalField(key: "miles_since_last_fill") var milesSinceLastFill: Double?
    @OptionalField(key: "mpg")        var mpg: Double?
    @OptionalField(key: "cost_per_mile") var costPerMile: Double?  // pence per mile
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(date: Date, vendor: String, totalCost: Double, pencePerLitre: Double,
         litres: Double, odometerReading: Double, isFullTank: Bool,
         milesSinceLastFill: Double? = nil, mpg: Double? = nil, costPerMile: Double? = nil) {
        self.date = date
        self.vendor = vendor
        self.totalCost = totalCost
        self.pencePerLitre = pencePerLitre
        self.litres = litres
        self.odometerReading = odometerReading
        self.isFullTank = isFullTank
        self.milesSinceLastFill = milesSinceLastFill
        self.mpg = mpg
        self.costPerMile = costPerMile
    }
}
