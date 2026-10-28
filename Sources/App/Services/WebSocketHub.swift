import Vapor
import NIOConcurrencyHelpers

final class WebSocketHub: @unchecked Sendable {
    private let lock = NIOLock()
    private var clients: [ObjectIdentifier: (ws: WebSocket, lastPong: Date)] = [:]

    func add(_ ws: WebSocket) {
        lock.withLock { clients[ObjectIdentifier(ws)] = (ws, Date()) }
    }

    func remove(_ ws: WebSocket) {
        lock.withLock { _ = clients.removeValue(forKey: ObjectIdentifier(ws)) }
    }

    /// Call from the route's `ws.onPong` handler — without this, `pingAll()`'s
    /// staleness check below has nothing to go on and will incorrectly treat every
    /// client as dead after ~70s, even ones that are genuinely still connected.
    func recordPong(_ ws: WebSocket) {
        lock.withLock {
            guard var entry = clients[ObjectIdentifier(ws)] else { return }
            entry.lastPong = Date()
            clients[ObjectIdentifier(ws)] = entry
        }
    }

    func broadcast(_ text: String) {
        lock.withLock { clients.values.forEach { $0.ws.send(text) } }
    }

    /// Sends a WebSocket ping to all open clients to keep connections alive through
    /// reverse-proxy idle timeouts (Nginx default: 60s), and proactively closes any
    /// client that hasn't ponged in over two ping cycles (~70s).
    ///
    /// Found via a real bug report: swiping an app away (rather than a clean app-level
    /// disconnect) doesn't always send a TCP close/RST promptly — `WebSocket.isClosed`
    /// can stay false indefinitely for a connection that's actually dead, which left
    /// instructor/student "Active now" presence stuck on for minutes after the app was
    /// gone. A missed-pong timeout is what actually detects that case; `isClosed` alone
    /// only catches a clean close.
    func pingAll() {
        let stale: [WebSocket] = lock.withLock {
            clients = clients.filter { !$0.value.ws.isClosed }
            let now = Date()
            let staleEntries = clients.values.filter { now.timeIntervalSince($0.lastPong) > 70 }
            clients.values.forEach { $0.ws.sendPing() }
            return staleEntries.map { $0.ws }
        }
        // Closed outside the lock — the resulting onClose handler calls back into
        // remove(), which would deadlock if still holding this same lock.
        stale.forEach { ws in
            _ = ws.close(code: .goingAway)
        }
    }

    var hasClients: Bool {
        lock.withLock { clients.values.contains { !$0.ws.isClosed } }
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
