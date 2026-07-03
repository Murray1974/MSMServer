import Vapor

/// Storage key for the student WebSocket hub
private struct MSMStudentHubKey: StorageKey {
    typealias Value = WebSocketHub
}

/// Storage key for student socket map (studentID → [WebSocket])
/// Stores a list so multiple simultaneous connections from the same student
/// (e.g. LessonsPage + MessagesPage both open a /ws/student socket) all receive
/// targeted deliveries without race-condition overwrites.
private struct MSMStudentSocketMapKey: StorageKey {
    typealias Value = [UUID: [WebSocket]]
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

    /// Map of authenticated student sockets for targeted delivery.
    var msmStudentSockets: [UUID: [WebSocket]] {
        get { storage[MSMStudentSocketMapKey.self] ?? [:] }
        set { storage[MSMStudentSocketMapKey.self] = newValue }
    }
}
