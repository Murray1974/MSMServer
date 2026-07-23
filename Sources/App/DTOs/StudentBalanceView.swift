import Vapor

struct StudentBalanceView: Content {
    let studentID: UUID
    let studentName: String
    let currentBalance: Decimal
    let nextLessonID: UUID?
    let nextLessonStartsAt: Date?
    let nextLessonPrice: Decimal?
    let nextLessonCovered: Bool
    let nextLessonFinanceStatus: String?
    /// Total number of late-cancellation charge ledger entries ever created for this student.
    let lateCancelFeesCount: Int
    /// Absolute sum (positive) of all late-cancellation charge amounts for this student.
    let lateCancelFeesTotal: Decimal
    /// Student's hourly rate in pence (e.g. 4500 = £45.00/hr). Nil if not set on their profile.
    let hourlyRatePence: Int?
}
