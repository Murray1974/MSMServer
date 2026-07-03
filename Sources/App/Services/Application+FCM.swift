import Vapor

extension Application {
    private struct FCMProjectIdKey: StorageKey { typealias Value = String }
    private struct FCMClientEmailKey: StorageKey { typealias Value = String }
    private struct FCMPrivateKeyKey: StorageKey { typealias Value = String }

    var fcmProjectId: String? {
        get { storage[FCMProjectIdKey.self] }
        set { storage[FCMProjectIdKey.self] = newValue }
    }

    var fcmClientEmail: String? {
        get { storage[FCMClientEmailKey.self] }
        set { storage[FCMClientEmailKey.self] = newValue }
    }

    // PEM private key (newlines already substituted at configure-time).
    var fcmPrivateKey: String? {
        get { storage[FCMPrivateKeyKey.self] }
        set { storage[FCMPrivateKeyKey.self] = newValue }
    }

    var isFCMConfigured: Bool {
        fcmProjectId != nil && fcmClientEmail != nil && fcmPrivateKey != nil
    }
}
