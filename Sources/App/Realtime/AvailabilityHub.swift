import Vapor
import NIOConcurrencyHelpers

struct AvailabilityUpdate: Content {
    var action: String            // e.g. "slot.created", "slot.cancelled"
    var id: UUID?
    var title: String?
    var startsAt: Date?
    var endsAt: Date?
    var capacity: Int?
    var instructor: String?
    var location: String?
    var durationMinutes: Int?
}

final class AvailabilityHub: @unchecked Sendable {
    private var clients: [WebSocket] = []
    private let lock = NIOLock()

    func add(_ ws: WebSocket) {
        lock.withLock { clients.append(ws) }
        ws.onClose.whenComplete { [weak self, weak ws] _ in
            guard let self, let ws else { return }
            self.remove(ws)
        }
    }

    private func remove(_ ws: WebSocket) {
        lock.withLock {
            clients.removeAll { $0 === ws }
        }
    }

    func broadcast(_ update: AvailabilityUpdate) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(update)
            guard let json = String(data: data, encoding: .utf8) else { return }
            lock.withLock {
                for ws in clients {
                    ws.send(json)
                }
            }
        } catch {
            print("❌ AvailabilityHub broadcast failed: \(error)")
        }
    }
}

private struct HubKey: StorageKey { typealias Value = AvailabilityHub }

extension Application {
    var availabilityHub: AvailabilityHub {
        if let existing = storage[HubKey.self] { return existing }
        let hub = AvailabilityHub()
        storage[HubKey.self] = hub
        return hub
    }
}
