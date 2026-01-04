@preconcurrency import Vapor
import NIOConcurrencyHelpers
struct AvailabilityUpdate: Content {
    var action: String            // e.g. "slot.created", "slot.cancelled"
    var id: UUID?                // Lesson/slot identifier (maps to MSM_LESSON_ID)
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
// Canonical actions understood by clients.
// Keep as String to remain backwards-compatible with any existing decoders.
enum AvailabilityAction {
    static let slotCreated = "slot.created"
    static let slotAvailable = "slot.available"     // slot is available to be booked
    static let slotUnavailable = "slot.unavailable" // slot is not available (booked/personal/etc)
    static let bookingChanged = "booking_changed"   // legacy
    static let bookingCleared = "booking.cleared"   // booking association removed; slot now available
}

extension AvailabilityUpdate {
    /// Minimal "slot is available" message (used when returning an event to the Unassigned calendar).
    static func available(lessonID: UUID, title: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, instructor: String? = nil) -> AvailabilityUpdate {
        AvailabilityUpdate(
            action: AvailabilityAction.slotAvailable,
            id: lessonID,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            capacity: nil,
            instructor: instructor,
            location: nil,
            durationMinutes: nil,
            version: 1,
            eventId: UUID()
        )
    }

    /// "booking cleared" message – consumers can treat this as slot becoming available.
    static func bookingCleared(lessonID: UUID, title: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, instructor: String? = nil) -> AvailabilityUpdate {
        AvailabilityUpdate(
            action: AvailabilityAction.bookingCleared,
            id: lessonID,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            capacity: nil,
            instructor: instructor,
            location: nil,
            durationMinutes: nil,
            version: 1,
            eventId: UUID()
        )
    }

    /// Minimal "slot is unavailable" message.
    static func unavailable(lessonID: UUID, title: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, instructor: String? = nil) -> AvailabilityUpdate {
        AvailabilityUpdate(
            action: AvailabilityAction.slotUnavailable,
            id: lessonID,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            capacity: nil,
            instructor: instructor,
            location: nil,
            durationMinutes: nil,
            version: 1,
            eventId: UUID()
        )
    }
}

final class AvailabilityHub: @unchecked Sendable {
    private var clients: [WebSocket] = []
    private let lock = NIOLock()
    /// Optional fanout (set by Application) to mirror messages to other hubs
    /// Marked @Sendable because it may be invoked from concurrently-executed contexts.
    var fanout: (@Sendable (String) -> Void)?

    func add(_ ws: WebSocket) {
        lock.withLock { clients.append(ws) }
        ws.onClose.whenComplete { [weak self, weak ws] _ in
            guard let self, let ws else { return }
            self.remove(ws)
        }
    }

    func remove(_ ws: WebSocket) {
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
            let snapshot: [WebSocket] = lock.withLock { clients }
            for ws in snapshot {
                ws.send(json)
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
            // Schedule fanout on an EventLoop to keep ordering consistent and avoid
            // doing extra work on whatever thread invoked `broadcast`.
            app.eventLoopGroup.next().execute {
                app.msmInstructorHub.broadcast(text)
                app.msmStudentHub.broadcast(text)
                app.logger.debug("Broadcasted(all): \(text)")
            }
        }
        storage[HubKey.self] = hub
        return hub
    }
}
