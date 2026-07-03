import Vapor

struct StudentSelfBalanceView: Content {
    let currentBalance: Decimal
    let lateCancelFeesCount: Int
    let lateCancelFeesTotal: Decimal
    let transactions: [StudentTransactionView]
}
