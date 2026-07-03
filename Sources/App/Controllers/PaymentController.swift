import Vapor
import Fluent

struct PaymentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - POST /student/payment-intent
    //         POST /student/create-payment-intent  (alias)

    /// Creates a Stripe PaymentIntent for a balance top-up.
    /// Route is on `studentProtected` — requires a valid Bearer token.
    /// The student's UUID is stored in PaymentIntent metadata so the webhook
    /// can later credit the correct ledger account.
    ///
    /// Request:  { "amount": <Int — pence, e.g. 1500 = £15.00> }
    /// Response: { "clientSecret": "pi_xxx_secret_xxx" }
    func createPaymentIntent(_ req: Request) async throws -> CreatePaymentIntentResponse {
        let student   = try req.auth.require(User.self)
        let studentID = try student.requireID()

        let input  = try req.content.decode(CreatePaymentIntentRequest.self)
        let stripe = try StripeService(request: req)

        var amountPence: Int
        var metadata: [String: String] = ["studentID": studentID.uuidString]

        if let bookingID = input.bookingID {
            // Verify the booking belongs to this student and is active
            guard let booking = try await Booking.query(on: req.db)
                .filter(\.$id == bookingID)
                .filter(\.$user.$id == studentID)
                .filter(\.$deletedAt == .null)
                .first()
            else {
                throw Abort(.notFound, reason: "Booking not found")
            }

            // Resolve price: prefer LessonFinance snapshot, fall back to duration estimate
            let lessonID = booking.$lesson.id
            let price: Decimal
            if let snapshot = try await LessonFinance.find(lessonID, on: req.db)?.priceSnapshot {
                price = snapshot
            } else {
                let lesson = try await booking.$lesson.get(on: req.db)
                let mins = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
                price = (Decimal(45) * Decimal(mins)) / Decimal(60)
            }

            var pence = price * 100
            var rounded = Decimal()
            NSDecimalRound(&rounded, &pence, 0, .plain)
            amountPence = max(50, NSDecimalNumber(decimal: rounded).intValue)

            metadata["bookingID"] = bookingID.uuidString

        } else if let explicit = input.amount {
            amountPence = explicit
        } else {
            throw Abort(.badRequest, reason: "Provide bookingID (per-lesson) or amount (top-up).")
        }

        let secret = try await stripe.createPaymentIntent(
            amount: amountPence,
            metadata: metadata
        )

        return CreatePaymentIntentResponse(clientSecret: secret, amountPence: amountPence)
    }

    // MARK: - POST /stripe/webhook

    /// Receives Stripe webhook events and processes payment confirmations.
    ///
    /// Security: every request is verified against the HMAC-SHA256 signature in
    /// the `Stripe-Signature` header (via `StripeService.verifySignature`) before
    /// any business logic runs.
    ///
    /// On `payment_intent.succeeded`:
    ///   1. Extract `studentID` from PaymentIntent metadata.
    ///   2. Guard against duplicate processing (idempotency via PaymentIntent ID).
    ///   3. Create a positive `LedgerEntry(type: "payment")` — this immediately
    ///      increases the student's balance returned by GET /student/balance.
    func handleWebhook(_ req: Request) async throws -> HTTPStatus {

        // ── 1. Signature verification ────────────────────────────────────────
        guard let sigHeader = req.headers["Stripe-Signature"].first else {
            throw Abort(.badRequest, reason: "Missing Stripe-Signature header.")
        }
        guard let webhookSecret = req.application.stripeWebhookSecret else {
            req.logger.critical("[Stripe] Webhook secret not configured — set STRIPE_WEBHOOK_SECRET.")
            throw Abort(.internalServerError, reason: "Webhook not configured.")
        }
        guard let rawBody = req.body.data else {
            throw Abort(.badRequest, reason: "Empty webhook body.")
        }

        // Verification lives in StripeService so Crypto types stay out of this file.
        try StripeService.verifySignature(rawBody: rawBody, header: sigHeader, secret: webhookSecret)

        // ── 2. Decode event ──────────────────────────────────────────────────
        let event = try JSONDecoder().decode(
            StripeWebhookEvent.self,
            from: Data(rawBody.readableBytesView)
        )

        // Return 200 for event types we don't handle — Stripe retries on non-2xx.
        guard event.type == "payment_intent.succeeded" else {
            req.logger.info("[Stripe] Unhandled event '\(event.type)' — acknowledged.")
            return .ok
        }

        let pi = event.data.object

        // ── 3. Extract student from metadata ─────────────────────────────────
        guard let studentIDString = pi.metadata["studentID"],
              let studentID = UUID(uuidString: studentIDString) else {
            req.logger.warning("[Stripe] payment_intent.succeeded missing studentID metadata — piID=\(pi.id)")
            // Return 200: this PaymentIntent wasn't created by our app (no metadata).
            // Retrying won't help — we'll never have the studentID for it.
            return .ok
        }

        let piID = pi.id

        // ── 4. Idempotency guard ──────────────────────────────────────────────
        // Stripe guarantees at-least-once delivery, so the same event can arrive
        // multiple times (network retry, dashboard resend, etc.).
        // We use the PaymentIntent ID stored in `note` as a surrogate idempotency
        // key. The combination (type = "payment") AND (note = piID) is unique per
        // successful Stripe charge, so this query is a reliable duplicate check.
        //
        // A proper stripe_payment_intent_id column would be cleaner but requires
        // a migration; the note field is sufficient until we need richer querying.
        let duplicate = try await LedgerEntry.query(on: req.db)
            .filter(\.$type == "payment")
            .filter(\.$note == piID)
            .first()

        if duplicate != nil {
            req.logger.notice("[Stripe] ⚠️  Duplicate webhook ignored — PI \(piID) already credited.")
            return .ok  // 200 tells Stripe we received it successfully; no retry needed
        }

        // ── 5. Resolve student name for logging ───────────────────────────────
        let studentName = try await User.find(studentID, on: req.db)
            .map { $0.username }
            ?? studentID.uuidString          // fallback if account was deleted

        // ── 6. Resolve instructor (required FK on LedgerEntry) ────────────────
        guard let instructor = try await User.query(on: req.db)
            .filter(\.$role == "instructor")
            .first()
        else {
            // This is a server misconfiguration — return 500 so Stripe retries
            // until the instructor account exists.
            req.logger.error("[Stripe] ❌ No instructor account found — cannot save ledger entry for PI \(piID). Stripe will retry.")
            throw Abort(.internalServerError, reason: "Instructor account not found.")
        }
        let instructorID = try instructor.requireID()

        // ── 7. Credit the student's balance ───────────────────────────────────
        // Stripe amounts are in the smallest currency unit (pence for GBP).
        // LedgerEntry.amount stores pounds as Decimal.
        let creditPounds = Decimal(pi.amount) / 100

        let entry = LedgerEntry(
            studentID: studentID,
            instructorID: instructorID,
            lessonID: nil,
            type: "payment",
            amount: creditPounds,
            paymentMethod: "stripe",
            note: piID,             // Stripe PaymentIntent ID — idempotency key (step 4)
            effectiveDate: Date()
        )

        // Explicit do-catch so a DB failure produces a clear log entry before
        // Vapor converts the thrown error into a 500 response for Stripe to retry.
        do {
            try await entry.save(on: req.db)
        } catch {
            req.logger.error("[Stripe] ❌ DB write failed for PI \(piID) (student: \(studentName)) — Stripe will retry. Error: \(error)")
            throw error     // Propagates as 500 → Stripe retries with back-off
        }

        req.logger.notice("[Stripe] ✅ Payment succeeded for student '\(studentName)' — £\(creditPounds) credited. PI: \(piID)")

        // ── 8. Mark the booking as paid if this was a per-lesson payment ─────
        if let bookingIDStr = pi.metadata["bookingID"],
           let bookingID = UUID(uuidString: bookingIDStr),
           let booking = try? await Booking.find(bookingID, on: req.db) {
            booking.paymentStatus = "paid"
            try? await booking.save(on: req.db)
            req.logger.info("[Stripe] Booking \(bookingID) marked paid.")
        }

        // ── 10. Re-evaluate lesson coverage now that the student's balance has increased ──
        do {
            try await FinanceController().reevaluateCoverageForStudent(studentID, on: req.db)
        } catch {
            req.logger.error("reevaluateCoverage failed: \(error)")
        }

        // ── 11. Real-time balance update ─────────────────────────────────────
        req.application.broadcastBalanceUpdated(studentID: studentID, creditPounds: creditPounds)

        // ── 12. FCM push notification (best-effort) ──────────────────────────
        if let fcmToken = try await User.find(studentID, on: req.db)?.fcmToken,
           let fcm = FCMNotificationService(req: req) {
            try? await fcm.send(
                to: fcmToken,
                title: "Payment Received!",
                body: "£\(creditPounds) has been added to your balance. 🚗"
            )
        }

        return .ok
    }
}
