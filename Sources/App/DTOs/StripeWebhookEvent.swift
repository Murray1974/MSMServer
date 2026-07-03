import Vapor

/// Minimal decode of a Stripe webhook event envelope.
/// Extra fields in the JSON are silently ignored — we only decode what we use.
struct StripeWebhookEvent: Decodable {
    let type: String
    let data: EventData

    struct EventData: Decodable {
        let object: PaymentIntentObject
    }

    /// Fields we need from the PaymentIntent object inside the event.
    struct PaymentIntentObject: Decodable {
        let id: String                      // "pi_3Rxxx..."
        let amount: Int                     // pence
        let currency: String                // "gbp"
        let metadata: [String: String]      // contains "studentID"
    }
}
