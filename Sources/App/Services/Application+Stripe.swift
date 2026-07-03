import Vapor

private struct StripeSecretKeyStorageKey: StorageKey {
    typealias Value = String
}

private struct StripeWebhookSecretStorageKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Stripe secret key (sk_test_... / sk_live_...) — loaded from STRIPE_SECRET_KEY at boot.
    var stripeSecretKey: String? {
        get { storage[StripeSecretKeyStorageKey.self] }
        set { storage[StripeSecretKeyStorageKey.self] = newValue }
    }

    /// Stripe webhook signing secret (whsec_...) — loaded from STRIPE_WEBHOOK_SECRET at boot.
    /// Used to verify that incoming POST /stripe/webhook requests really came from Stripe.
    var stripeWebhookSecret: String? {
        get { storage[StripeWebhookSecretStorageKey.self] }
        set { storage[StripeWebhookSecretStorageKey.self] = newValue }
    }
}
