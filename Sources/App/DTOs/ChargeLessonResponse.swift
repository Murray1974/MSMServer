import Vapor

struct ChargeLessonResponse: Content {
    let lessonID: UUID
    let ledgerEntryID: UUID
    let studentID: UUID
    let amount: Decimal
    let chargeStatus: String
}
