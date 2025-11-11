import Vapor

/// Storage key for the instructor WebSocket hub
private struct MSMInstructorHubKey: StorageKey {
    typealias Value = WebSocketHub
}

extension Application {
    /// Singleton hub for **instructor** websocket clients (MSM Agent on your Mac)
    var msmInstructorHub: WebSocketHub {
        get {
            if let hub = storage[MSMInstructorHubKey.self] { return hub }
            let hub = WebSocketHub()
            storage[MSMInstructorHubKey.self] = hub
            return hub
        }
        set { storage[MSMInstructorHubKey.self] = newValue }
    }
}
