import Vapor

/// POST /student/payment-intent  (or /student/create-payment-intent)
///
/// Supply one of:
///   - `bookingID`  → server looks up the lesson price from LessonFinance.priceSnapshot
///   - `amount`     → explicit pence value (fixed/custom top-up)
///   - `blockHours` → server prices it at the student's own hourly rate (e.g. a 10-hour block)
struct CreatePaymentIntentRequest: Content {
    let bookingID: UUID?
    /// Explicit amount in pence. Only used when bookingID/blockHours are nil (fixed/custom top-up).
    let amount: Int?
    /// Number of hours to price at the student's own StudentProfile.hourlyRate. The amount is
    /// always computed server-side from this — never trust a client-supplied amount for a block.
    let blockHours: Int?
}

struct CreatePaymentIntentResponse: Content {
    /// The Stripe PaymentIntent clientSecret passed to the Flutter Payment Sheet.
    let clientSecret: String
    /// Amount in pence — lets the client display "Pay £X.XX" before showing the sheet.
    let amountPence: Int
}
