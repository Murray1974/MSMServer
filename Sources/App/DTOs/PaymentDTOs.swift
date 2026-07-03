import Vapor

/// POST /student/payment-intent  (or /student/create-payment-intent)
///
/// Supply either:
///   - `bookingID`  → server looks up the lesson price from LessonFinance.priceSnapshot
///   - `amount`     → explicit pence value (top-up / future balance flow)
struct CreatePaymentIntentRequest: Content {
    let bookingID: UUID?
    /// Explicit amount in pence. Only used when bookingID is nil (balance top-up).
    let amount: Int?
}

struct CreatePaymentIntentResponse: Content {
    /// The Stripe PaymentIntent clientSecret passed to the Flutter Payment Sheet.
    let clientSecret: String
    /// Amount in pence — lets the client display "Pay £X.XX" before showing the sheet.
    let amountPence: Int
}
