import Foundation

struct MockPaymentResult: Codable {
    let success: Bool
    let transactionID: String
    let message: String
}

/// Simulates an external payment gateway. Always succeeds.
/// Replace this with a real provider (Stripe, etc.) when ready.
struct MockPaymentService {
    static func process(bookingID: UUID, amountPence: Int? = nil) async throws -> MockPaymentResult {
        let txID = "MOCK-\(bookingID.uuidString.prefix(8).uppercased())"
        return MockPaymentResult(
            success: true,
            transactionID: txID,
            message: "Payment simulated successfully"
        )
    }
}
