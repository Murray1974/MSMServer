import Fluent
import Vapor

/// Single row per instructor holding the current Road Tax + Insurance status
/// (not a history table — updated in place on each renewal).
final class VehicleDocument: Model, Content, @unchecked Sendable {
    static let schema = "vehicle_documents"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @OptionalField(key: "road_tax_due_date")
    var roadTaxDueDate: Date?

    @OptionalField(key: "road_tax_cost")
    var roadTaxCost: Decimal?

    @Field(key: "road_tax_reminder_days_before")
    var roadTaxReminderDaysBefore: Int

    @OptionalField(key: "insurance_provider")
    var insuranceProvider: String?

    @OptionalField(key: "insurance_policy_number")
    var insurancePolicyNumber: String?

    @OptionalField(key: "insurance_renewal_date")
    var insuranceRenewalDate: Date?

    @OptionalField(key: "insurance_annual_cost")
    var insuranceAnnualCost: Decimal?

    @Field(key: "insurance_reminder_days_before")
    var insuranceReminderDaysBefore: Int

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        roadTaxDueDate: Date? = nil,
        roadTaxCost: Decimal? = nil,
        roadTaxReminderDaysBefore: Int = 14,
        insuranceProvider: String? = nil,
        insurancePolicyNumber: String? = nil,
        insuranceRenewalDate: Date? = nil,
        insuranceAnnualCost: Decimal? = nil,
        insuranceReminderDaysBefore: Int = 14
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.roadTaxDueDate = roadTaxDueDate
        self.roadTaxCost = roadTaxCost
        self.roadTaxReminderDaysBefore = roadTaxReminderDaysBefore
        self.insuranceProvider = insuranceProvider
        self.insurancePolicyNumber = insurancePolicyNumber
        self.insuranceRenewalDate = insuranceRenewalDate
        self.insuranceAnnualCost = insuranceAnnualCost
        self.insuranceReminderDaysBefore = insuranceReminderDaysBefore
    }
}
