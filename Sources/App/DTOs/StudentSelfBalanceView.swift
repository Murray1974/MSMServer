import Vapor

struct StudentSelfBalanceView: Content {
    let currentBalance: Decimal
    let lateCancelFeesCount: Int
    let lateCancelFeesTotal: Decimal
    let transactions: [StudentTransactionView]
    let accountHold: Bool
    let accountHoldReason: String?
    /// Non-nil when the student has an active upcoming booking that is not yet covered
    /// and the lesson starts within the next 50 hours. Triggers the persistent payment modal.
    let pendingPaymentBooking: PendingPaymentView?
    /// Non-nil when the student is on hold and we could identify the auto-cancelled lesson.
    let holdLessonID: String?
    let holdLessonStartsAt: String?
    let holdLessonAvailable: Bool
}

struct PendingPaymentView: Content {
    let bookingID: String
    let lessonID: String
    let startsAt: String
    let endsAt: String
    let amountDue: Decimal
}
