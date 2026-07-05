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

    /// Sends a WebSocket ping to all open clients to keep connections alive through
    /// reverse-proxy idle timeouts (Nginx default: 60s). Call every ~30s.
    func pingAll() {
        lock.withLock {
            clients = clients.filter { !$0.isClosed }
            clients.forEach { $0.sendPing() }
        }
    }

    var hasClients: Bool {
        lock.withLock { clients.contains { !$0.isClosed } }
    }
}

// MARK: - Keepalive lifecycle

final class WebSocketKeepaliveLifecycle: LifecycleHandler, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func didBoot(_ application: Application) throws {
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                application.instructorHub.pingAll()
                application.studentHub.pingAll()
                application.availabilityHub.pingAll()
            }
        }
        application.logger.notice("[WS] Keepalive started — pinging all hubs every 30s")
    }

    func shutdown(_ application: Application) {
        task?.cancel()
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

    private struct StudentHubKey: StorageKey { typealias Value = WebSocketHub }

    // Student-facing hub (Phase 2): mirrors instructor hub but used for student clients (/ws/student)
    var studentHub: WebSocketHub {
        get {
            if let hub = storage[StudentHubKey.self] { return hub }
            let hub = WebSocketHub()
            storage[StudentHubKey.self] = hub
            return hub
        }
        set { storage[StudentHubKey.self] = newValue }
    }
}
