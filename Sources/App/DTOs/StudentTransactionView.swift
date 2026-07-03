import Vapor

struct StudentTransactionView: Content {
    let id: UUID
    let lessonID: UUID?
    let lessonStartsAt: Date?
    let type: String
    let amount: Decimal
    let paymentMethod: String?
    let note: String?
    let effectiveDate: Date
    let createdAt: Date?
    let voidedAt: Date?
    let voidReason: String?
}
