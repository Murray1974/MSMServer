import Vapor

struct StudentSelfBalanceView: Content {
    let currentBalance: Decimal
    let lateCancelFeesCount: Int
    let lateCancelFeesTotal: Decimal
    let transactions: [StudentTransactionView]
    let accountHold: Bool
    let accountHoldReason: String?
    let accountStatus: String
    /// Non-nil when the student has an active upcoming booking that is not yet covered
    /// and the lesson starts within the next 50 hours. Triggers the persistent payment modal.
    let pendingPaymentBooking: PendingPaymentView?
    /// Non-nil when the student is on hold and we could identify the auto-cancelled lesson.
    let holdLessonID: String?
    let holdLessonStartsAt: String?
    let holdLessonAvailable: Bool
    /// Any active booking whose lesson hasn't started yet. Lets the client choose a sensible
    /// default landing tab (My Lessons vs Book) without a separate round trip.
    let hasUpcomingLessons: Bool
    /// The student's own per-hour rate, for client-side display of rate-scaled amounts
    /// (e.g. a "10 hour block" top-up estimate) — never used client-side to compute an
    /// actual charge, only to show it before the server computes the real amount.
    let hourlyRatePence: Int
}

struct PendingPaymentView: Content {
    let bookingID: String
    let lessonID: String
    let startsAt: String
    let endsAt: String
    let amountDue: Decimal
}
