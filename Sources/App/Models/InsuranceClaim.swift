import Fluent
import Vapor

final class InsuranceClaim: Model, Content, @unchecked Sendable {
    static let schema = "insurance_claims"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "claim_date")
    var claimDate: Date

    @Field(key: "claim_description")
    var claimDescription: String

    @OptionalField(key: "amount_claimed")
    var amountClaimed: Decimal?

    @OptionalField(key: "excess_paid")
    var excessPaid: Decimal?

    /// Optional link to the real logged expense (e.g. "repairs" or "insurance_excess")
    /// that the excess was actually paid through, instead of re-typing the amount.
    @OptionalParent(key: "excess_expense_entry_id")
    var excessExpenseEntry: ExpenseEntry?

    /// "open" | "settled" | "rejected"
    @Field(key: "status")
    var status: String

    @OptionalField(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        claimDate: Date,
        claimDescription: String,
        amountClaimed: Decimal? = nil,
        excessPaid: Decimal? = nil,
        excessExpenseEntryID: UUID? = nil,
        status: String = "open",
        notes: String? = nil
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.claimDate = claimDate
        self.claimDescription = claimDescription
        self.amountClaimed = amountClaimed
        self.excessPaid = excessPaid
        self.$excessExpenseEntry.id = excessExpenseEntryID
        self.status = status
        self.notes = notes
    }
}
