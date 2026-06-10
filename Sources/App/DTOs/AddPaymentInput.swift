import Vapor

struct AddPaymentInput: Content {
    let studentID: UUID
    let amount: Decimal
    let paymentMethod: String
    let note: String?
    let effectiveDate: Date
    let lessonID: UUID?
}
