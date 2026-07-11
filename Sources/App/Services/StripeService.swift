import Vapor
import Crypto

/// Wraps the Stripe REST API for server-side payment operations.
///
/// There is no official Stripe Swift server SDK; this service calls
/// api.stripe.com directly using Vapor's built-in AsyncHTTPClient —
/// the same technique used by every community Stripe package.
///
/// Usage (inside a route handler):
///   let stripe = try StripeService(request: req)
///   let secret = try await stripe.createPaymentIntent(amount: 1500)
struct StripeService {

    private let secretKey: String
    private let client: Client
    private let logger: Logger

    /// Initialises the service from the current request context.
    /// Throws 500 if the key was absent from the environment when the server booted.
    init(request req: Request) throws {
        guard let key = req.application.stripeSecretKey else {
            req.logger.critical("[Stripe] stripeSecretKey was not initialised at startup — check STRIPE_SECRET_KEY in your environment.")
            throw Abort(.internalServerError, reason: "Payment service not configured.")
        }
        self.secretKey = key
        self.client    = req.client
        self.logger    = req.logger
    }

    // MARK: - PaymentIntent

    /// Creates a Stripe PaymentIntent and returns its `client_secret` for
    /// the Flutter Payment Sheet.
    ///
    /// - Parameters:
    ///   - amount:   Amount in pence. `1500` = £15.00. Stripe minimum is `50`.
    ///   - currency: ISO 4217 code. Defaults to `"gbp"`.
    ///   - metadata: Key-value pairs attached to the PaymentIntent in Stripe's
    ///               dashboard (e.g. `["studentID": "abc-123"]`). Use this to
    ///               correlate Stripe events back to MSM users.
    func createPaymentIntent(
        amount: Int,
        currency: String = "gbp",
        metadata: [String: String] = [:]
    ) async throws -> String {
        guard amount >= 50 else {
            throw Abort(
                .badRequest,
                reason: "Amount must be at least 50p — Stripe's minimum charge for GBP."
            )
        }

        var params = [
            "amount=\(amount)",
            "currency=\(currency)",
            "automatic_payment_methods%5Benabled%5D=true",
        ]

        for (key, value) in metadata {
            let encodedKey   = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            params.append("metadata%5B\(encodedKey)%5D=\(encodedValue)")
        }

        let formBody = params.joined(separator: "&")

        let response = try await client.post(
            URI(string: "https://api.stripe.com/v1/payment_intents")
        ) { outReq in
            outReq.headers.basicAuthorization = BasicAuthorization(username: secretKey, password: "")
            outReq.headers.contentType = .urlEncodedForm
            outReq.body = .init(string: formBody)
        }

        guard response.status == .ok else {
            let raw = response.body.map {
                String(bytes: $0.readableBytesView, encoding: .utf8) ?? "(unreadable)"
            } ?? "(empty body)"
            logger.error("Stripe \(response.status): \(raw)")
            throw Abort(.badGateway, reason: "Payment intent creation failed.")
        }

        struct StripePaymentIntent: Decodable {
            let client_secret: String
        }

        let pi = try response.content.decode(StripePaymentIntent.self)
        return pi.client_secret
    }

    // MARK: - Refund

    /// Issues a Stripe refund against an existing PaymentIntent.
    /// - Parameters:
    ///   - paymentIntentID: The `pi_...` ID stored in the `LedgerEntry.note` field.
    ///   - amount: Amount to refund in pence. Pass `nil` to refund the full charge.
    func createRefund(paymentIntentID: String, amount: Int? = nil) async throws {
        var params = ["payment_intent=\(paymentIntentID)"]
        if let amount { params.append("amount=\(amount)") }
        let formBody = params.joined(separator: "&")

        let response = try await client.post(
            URI(string: "https://api.stripe.com/v1/refunds")
        ) { outReq in
            outReq.headers.basicAuthorization = BasicAuthorization(username: secretKey, password: "")
            outReq.headers.contentType = .urlEncodedForm
            outReq.body = .init(string: formBody)
        }

        guard response.status == .ok else {
            let raw = response.body.map {
                String(bytes: $0.readableBytesView, encoding: .utf8) ?? "(unreadable)"
            } ?? "(empty body)"
            logger.error("[Stripe] Refund failed \(response.status): \(raw)")

            // Surface Stripe's own error message when available.
            struct StripeError: Decodable {
                struct Detail: Decodable { let message: String? }
                let error: Detail?
            }
            let reason: String
            if let data = response.body,
               let se = try? JSONDecoder().decode(StripeError.self, from: Data(data.readableBytesView)),
               let msg = se.error?.message {
                reason = msg
            } else {
                reason = "Stripe refund failed."
            }
            throw Abort(.badGateway, reason: reason)
        }

        logger.notice("[Stripe] Refund issued for PaymentIntent \(paymentIntentID).")
    }

    // MARK: - Webhook signature verification

    /// Verifies the `Stripe-Signature` header against the raw request body using
    /// HMAC-SHA256 and the endpoint's webhook signing secret (whsec_...).
    ///
    /// Reference: https://stripe.com/docs/webhooks/signatures
    ///
    /// - Parameters:
    ///   - rawBody:  The unmodified request body bytes as received from Stripe.
    ///   - header:   The full value of the `Stripe-Signature` header.
    ///   - secret:   The webhook endpoint signing secret from the Stripe dashboard.
    static func verifySignature(rawBody: ByteBuffer, header: String, secret: String) throws {
        // Parse "t=<timestamp>,v1=<sig>[,v1=<sig>...]"
        var timestamp: String?
        var v1Signatures: [String] = []

        for component in header.split(separator: ",") {
            let kv = component.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "t":  timestamp = String(kv[1])
            case "v1": v1Signatures.append(String(kv[1]))
            default:   break
            }
        }

        guard let timestamp else {
            throw Abort(.badRequest, reason: "Stripe-Signature header is malformed — missing timestamp.")
        }

        // Replay-attack protection: reject events older than 5 minutes.
        guard let ts = Int(timestamp),
              abs(Int(Date().timeIntervalSince1970) - ts) <= 300 else {
            throw Abort(.badRequest, reason: "Stripe webhook timestamp is outside the tolerance window.")
        }

        // Stripe signs "{timestamp}.{rawBody}" with the endpoint secret.
        let bodyString   = String(bytes: rawBody.readableBytesView, encoding: .utf8) ?? ""
        let signedString = "\(timestamp).\(bodyString)"

        let key      = SymmetricKey(data: Data(secret.utf8))
        let mac      = HMAC<SHA256>.authenticationCode(for: Data(signedString.utf8), using: key)
        let computed = Data(mac).map { String(format: "%02hhx", $0) }.joined()

        guard v1Signatures.contains(computed) else {
            throw Abort(.badRequest, reason: "Stripe webhook signature mismatch — request rejected.")
        }
    }
}
