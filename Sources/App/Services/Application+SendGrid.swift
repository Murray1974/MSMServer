import Vapor

private struct SendGridApiKeyStorageKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// SendGrid API key — loaded from SENDGRID_API_KEY at boot.
    var sendGridApiKey: String? {
        get { storage[SendGridApiKeyStorageKey.self] }
        set { storage[SendGridApiKeyStorageKey.self] = newValue }
    }
}
