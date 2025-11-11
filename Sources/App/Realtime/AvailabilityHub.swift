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
    // v1 schema additions (non‑breaking)
    var version: Int?      // auto = 1 if nil
    var eventId: UUID?     // auto = new UUID if nil
}

final class AvailabilityHub: @unchecked Sendable {
    private var clients: [WebSocket] = []
    private let lock = NIOLock()
    /// Optional fanout (set by Application) to mirror messages to other hubs
    var fanout: ((String) -> Void)?

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
            // Fill defaults without forcing call sites to change
            var enriched = update
            if enriched.version == nil { enriched.version = 1 }
            if enriched.eventId == nil { enriched.eventId = UUID() }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(enriched)
            guard let json = String(data: data, encoding: .utf8) else { return }

            // Send to any legacy AvailabilityHub clients
            lock.withLock {
                for ws in clients {
                    ws.send(json)
                }
            }

            // Mirror to additional hubs if configured by Application
            fanout?(json)
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
        // Fanout to both instructor and student hubs using the same payload
        hub.fanout = { [weak self] text in
            guard let app = self else { return }
            app.msmInstructorHub.broadcast(text)
            app.msmStudentHub.broadcast(text)
            app.logger.info("Broadcasted(all): \(text)")
        }
        storage[HubKey.self] = hub
        return hub
    }
}
