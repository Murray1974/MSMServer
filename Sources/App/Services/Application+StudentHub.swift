import Vapor

/// Storage key for the student WebSocket hub
private struct MSMStudentHubKey: StorageKey {
    typealias Value = WebSocketHub
}

extension Application {
    /// Singleton hub for **student** websocket clients (future Student app)
    var msmStudentHub: WebSocketHub {
        get {
            if let hub = storage[MSMStudentHubKey.self] { return hub }
            let hub = WebSocketHub()
            storage[MSMStudentHubKey.self] = hub
            return hub
        }
        set { storage[MSMStudentHubKey.self] = newValue }
    }
}
