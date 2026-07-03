import Vapor
import Fluent

final class ExpenseEntry: Model, Content, @unchecked Sendable {
    static let schema = "expense_entries"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "amount")
    var amount: Decimal

    @Field(key: "category")
    var category: String

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "expense_date")
    var expenseDate: Date

    @OptionalField(key: "receipt_path")
    var receiptPath: String?

    @Field(key: "is_business_use")
    var isBusinessUse: Bool

    @OptionalField(key: "mileage")
    var mileage: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instructorID: UUID,
        amount: Decimal,
        category: String,
        note: String? = nil,
        expenseDate: Date,
        receiptPath: String? = nil,
        isBusinessUse: Bool = true,
        mileage: Int? = nil
    ) {
        self.id = id
        self.$instructor.id = instructorID
        self.amount = amount
        self.category = category
        self.note = note
        self.expenseDate = expenseDate
        self.receiptPath = receiptPath
        self.isBusinessUse = isBusinessUse
        self.mileage = mileage
    }
}
