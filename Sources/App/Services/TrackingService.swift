import Vapor
import Fluent

// MARK: - Lifecycle handler (registered in configure.swift)

final class TrackingSchedulerLifecycle: LifecycleHandler, @unchecked Sendable {
    private var schedulerTask: Task<Void, Never>?

    func didBoot(_ application: Application) throws {
        let service = TrackingService(app: application)
        let db = application.db
        schedulerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await service.activateDueSessions(on: db)
                await service.expireOverdueSessions(on: db)
            }
        }
        application.logger.notice("[Tracking] Scheduler started — checking every 30s")
    }

    func shutdown(_ application: Application) {
        schedulerTask?.cancel()
    }
}

// MARK: - Service

/// Live instructor-location-tracking: a TrackingSession opens automatically ~10 minutes
/// before a booking's lesson starts and closes either when the instructor manually ends
/// it or when the lesson's end time passes, whichever comes first (the auto-expire pass
/// below is the safety net for the latter — see CLAUDE.md-style reasoning: this mirrors
/// RecoverySchedulerLifecycle/PaymentEnforcementLifecycle's existing poll-loop shape).
struct TrackingService {
    let app: Application

    private static let activationWindow: TimeInterval = 10 * 60

    // MARK: - Activate sessions for imminent bookings

    func activateDueSessions(on db: Database) async {
        let now = Date()
        let windowEnd = now.addingTimeInterval(Self.activationWindow)

        let lessonIDs: [UUID]
        do {
            lessonIDs = try await Lesson.query(on: db)
                .filter(\.$startsAt > now)
                .filter(\.$startsAt <= windowEnd)
                .all()
                .compactMap { $0.id }
        } catch {
            app.logger.warning("[Tracking] Failed to query imminent lessons: \(error)")
            return
        }
        guard !lessonIDs.isEmpty else { return }

        let bookings: [Booking]
        do {
            bookings = try await Booking.query(on: db)
                .filter(\.$lesson.$id ~~ lessonIDs)
                .filter(\.$deletedAt == .null)
                .with(\.$lesson)
                .with(\.$user)
                .all()
        } catch {
            app.logger.warning("[Tracking] Failed to query bookings for imminent lessons: \(error)")
            return
        }
        guard !bookings.isEmpty else { return }

        let bookingIDs = bookings.compactMap { $0.id }
        let alreadyTracked: Set<UUID>
        do {
            alreadyTracked = Set(
                try await TrackingSession.query(on: db)
                    .filter(\.$bookingID ~~ bookingIDs)
                    .all()
                    .map { $0.bookingID }
            )
        } catch {
            app.logger.warning("[Tracking] Failed to query existing sessions: \(error)")
            return
        }

        for booking in bookings {
            guard let bookingID = booking.id, !alreadyTracked.contains(bookingID) else { continue }
            await activate(booking: booking, on: db)
        }
    }

    private func activate(booking: Booking, on db: Database) async {
        guard let bookingID = booking.id else { return }
        let lesson = booking.lesson
        let student = booking.user

        // Geocode once, lazily, and cache onto the booking — a miss here doesn't block
        // the session from starting, it just means no destination pin for this one.
        if booking.pickupLatitude == nil, let address = booking.pickupLocation, !address.isEmpty {
            let nominatim = NominatimService(client: app.client, logger: app.logger)
            if let coords = await nominatim.geocode(address: address) {
                booking.pickupLatitude = coords.latitude
                booking.pickupLongitude = coords.longitude
                try? await booking.save(on: db)
            }
        }

        // Same lazy-cache pattern for drop-off, used by lesson-journey tracking's
        // client-side geofence — falls back to the pickup coordinates when no distinct
        // drop-off address was given, since most lessons start and end at the same place.
        if booking.dropoffLatitude == nil {
            if let address = booking.dropoffLocation, !address.isEmpty {
                let nominatim = NominatimService(client: app.client, logger: app.logger)
                if let coords = await nominatim.geocode(address: address) {
                    booking.dropoffLatitude = coords.latitude
                    booking.dropoffLongitude = coords.longitude
                    try? await booking.save(on: db)
                }
            } else if let lat = booking.pickupLatitude, let lon = booking.pickupLongitude {
                booking.dropoffLatitude = lat
                booking.dropoffLongitude = lon
                try? await booking.save(on: db)
            }
        }

        let session = TrackingSession(bookingID: bookingID, startedAt: Date(), endsAt: lesson.endsAt)
        do {
            try await session.save(on: db)
        } catch {
            app.logger.warning("[Tracking] Failed to create session for bookingID=\(bookingID): \(error)")
            return
        }
        app.logger.notice("[Tracking] Session activated bookingID=\(bookingID) studentID=\(student.id?.uuidString ?? "?")")

        if let studentToken = student.fcmToken, let fcm = FCMNotificationService(app: app) {
            try? await fcm.send(
                to: studentToken,
                title: "Your instructor is on the way",
                body: "Track their live location now.",
                data: ["type": "tracking_started", "bookingID": bookingID.uuidString]
            )
        }

        if let instructor = try? await User.query(on: db).filter(\.$role == "instructor").first(),
           let instructorToken = instructor.fcmToken,
           let fcm = FCMNotificationService(app: app) {
            // Pickup/drop-off coordinates ride along on this same push so the instructor
            // app's JourneyTrackingManager can arm its geofences immediately on arrival,
            // with no extra round-trip — mirrors how studentName is already threaded
            // through here.
            var data = [
                "type": "tracking_session_activated",
                "bookingID": bookingID.uuidString,
                "studentName": student.displayName,
                "endsAt": ISO8601DateFormatter().string(from: lesson.endsAt)
            ]
            if let lat = booking.pickupLatitude { data["pickupLatitude"] = String(lat) }
            if let lon = booking.pickupLongitude { data["pickupLongitude"] = String(lon) }
            if let lat = booking.dropoffLatitude { data["dropoffLatitude"] = String(lat) }
            if let lon = booking.dropoffLongitude { data["dropoffLongitude"] = String(lon) }

            try? await fcm.send(
                to: instructorToken,
                title: "Location sharing started",
                body: "Sharing your live location with \(student.displayName) for the next lesson.",
                data: data
            )
        }
    }

    // MARK: - Auto-expire overdue sessions

    func expireOverdueSessions(on db: Database) async {
        let now = Date()
        let overdue: [TrackingSession]
        do {
            overdue = try await TrackingSession.query(on: db)
                .filter(\.$endedAt == .null)
                .filter(\.$endsAt <= now)
                .all()
        } catch {
            app.logger.warning("[Tracking] Failed to query overdue sessions: \(error)")
            return
        }
        guard !overdue.isEmpty else { return }

        for session in overdue {
            session.endedAt = now
            session.endedReason = "auto_expired"
            try? await session.save(on: db)
            app.logger.notice("[Tracking] Session auto-expired bookingID=\(session.bookingID)")

            if let booking = try? await Booking.find(session.bookingID, on: db) {
                app.deliverTrackingEndedToStudent(studentID: booking.$user.id)
            }
        }
    }
}
