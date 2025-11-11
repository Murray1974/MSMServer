import Vapor
import NIOConcurrencyHelpers

final class WebSocketHub: @unchecked Sendable {
    private let lock = NIOLock()
    private var clients: [WebSocket] = []

    func add(_ ws: WebSocket) {
        lock.withLock { clients.append(ws) }
    }

    func remove(_ ws: WebSocket) {
        lock.withLock { clients.removeAll { $0 === ws } }
    }

    func broadcast(_ text: String) {
        lock.withLock { clients.forEach { $0.send(text) } }
    }
}

// MARK: - Storage key & Application accessor
extension Application {
    private struct InstructorHubKey: StorageKey { typealias Value = WebSocketHub }

    var instructorHub: WebSocketHub {
        get {
            if let hub = storage[InstructorHubKey.self] { return hub }
            let hub = WebSocketHub()
            storage[InstructorHubKey.self] = hub
            return hub
        }
        set { storage[InstructorHubKey.self] = newValue }
    }

    // Student-facing hub (Phase 2): mirrors instructor hub but used for student clients (/ws/student)
    var studentHub: WebSocketHub {
        struct StudentHubKey: StorageKey { typealias Value = WebSocketHub }
        if let hub = storage[StudentHubKey.self] { return hub }
        let hub = WebSocketHub()
        storage[StudentHubKey.self] = hub
        return hub
    }
}
