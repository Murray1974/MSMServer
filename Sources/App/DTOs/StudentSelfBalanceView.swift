import Vapor

struct StudentSelfBalanceView: Content {
    let currentBalance: Decimal
    let lateCancelFeesCount: Int
    let lateCancelFeesTotal: Decimal
    let transactions: [StudentTransactionView]
    let accountHold: Bool
    let accountHoldReason: String?
}
