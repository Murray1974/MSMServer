import Vapor
import Fluent

// MARK: - Lifecycle handler (registered in configure.swift)

final class RecoverySchedulerLifecycle: LifecycleHandler, @unchecked Sendable {
    private var schedulerTask: Task<Void, Never>?

    func didBoot(_ application: Application) throws {
        let service = RecoverySequenceService(app: application)
        let db = application.db
        schedulerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await service.processPendingJobs(on: db)
            }
        }
        application.logger.notice("[Recovery] Scheduler started — processing pending jobs every 60s")
    }

    func shutdown(_ application: Application) {
        schedulerTask?.cancel()
    }
}

// MARK: - Service

/// Handles server-side recovery sequencing: computes P1/P2/P3 from booking history,
/// sends P1 immediately via FCM, and schedules P2/P3 as database-backed jobs so the
/// sequence survives the app being backgrounded or the instructor closing the app.
struct RecoverySequenceService {

    let app: Application

    // MARK: - Entry point (called on cancellation)

    func triggerSequence(for lesson: Lesson, on db: Database) async {
        guard let lessonID = try? lesson.requireID() else { return }

        let (p1, p2, p3) = await computeGroups(for: lesson, on: db)

        app.logger.info("[Recovery] P1=\(p1.count) P2=\(p2.count) P3=\(p3.count) lessonID=\(lessonID)")

        // Send P1 immediately
        if !p1.isEmpty {
            await send(users: p1, lesson: lesson, stage: "P1", on: db)
        }

        let now = Date()

        // Schedule P2 for 30 minutes from now
        if !p2.isEmpty {
            let job = RecoveryJob(lessonID: lessonID, stage: "p2", scheduledFor: now.addingTimeInterval(1800))
            try? await job.save(on: db)
        }

        // Schedule P3 for 60 minutes from now
        if !p3.isEmpty {
            let job = RecoveryJob(lessonID: lessonID, stage: "p3", scheduledFor: now.addingTimeInterval(3600))
            try? await job.save(on: db)
        }
    }

    // MARK: - Background job processor (called every 60 seconds)

    func processPendingJobs(on db: Database) async {
        let due: [RecoveryJob]
        do {
            due = try await RecoveryJob.query(on: db)
                .filter(\.$scheduledFor <= Date())
                .filter(\.$sentAt == .null)
                .filter(\.$cancelledAt == .null)
                .all()
        } catch {
            app.logger.warning("[Recovery] Failed to fetch pending jobs: \(error)")
            return
        }

        for job in due {
            guard let lesson = try? await Lesson.find(job.lessonID, on: db) else {
                job.cancelledAt = Date()
                try? await job.save(on: db)
                continue
            }

            // Stop if the slot was rebooked
            let hasActiveBooking = (try? await Booking.query(on: db)
                .filter(\.$lesson.$id == job.lessonID)
                .filter(\.$deletedAt == .null)
                .count()) ?? 0
            if hasActiveBooking > 0 {
                app.logger.info("[Recovery] Job \(job.id?.uuidString ?? "?") cancelled — slot rebooked")
                job.cancelledAt = Date()
                try? await job.save(on: db)
                continue
            }

            let (_, p2, p3) = await computeGroups(for: lesson, on: db)
            let recipients: [User]
            switch job.stage {
            case "p2": recipients = p2
            case "p3": recipients = p3
            default:   recipients = []
            }

            if !recipients.isEmpty {
                await send(users: recipients, lesson: lesson, stage: job.stage.uppercased(), on: db)
            }

            job.sentAt = Date()
            try? await job.save(on: db)
        }
    }

    // MARK: - Cancel pending jobs when a slot is rebooked

    func cancelPendingJobs(for lessonID: UUID, on db: Database) async {
        guard let jobs = try? await RecoveryJob.query(on: db)
            .filter(\.$lessonID == lessonID)
            .filter(\.$sentAt == .null)
            .filter(\.$cancelledAt == .null)
            .all()
        else { return }

        for job in jobs {
            job.cancelledAt = Date()
            try? await job.save(on: db)
        }
        if !jobs.isEmpty {
            app.logger.info("[Recovery] Cancelled \(jobs.count) pending job(s) for lessonID=\(lessonID) — slot rebooked")
        }
    }

    // MARK: - Priority group computation

    /// P1 — students who had a booking at the exact same weekday + start-hour in the past 90 days (2+ times)
    /// P2 — students with same start-hour on any weekday in the past 90 days (2+ times), not in P1
    /// P3 — all other students with any booking in the past 90 days, not in P1 or P2
    private func computeGroups(for lesson: Lesson, on db: Database) async -> (p1: [User], p2: [User], p3: [User]) {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: lesson.startsAt)   // 1=Sun…7=Sat
        let hour = cal.component(.hour, from: lesson.startsAt)
        let ninetyDaysAgo = Date().addingTimeInterval(-90 * 24 * 3600)

        // All students who booked any lesson in the past 90 days (excluding cancellations)
        guard let recentBookings = try? await Booking.query(on: db)
            .join(Lesson.self, on: \Booking.$lesson.$id == \Lesson.$id)
            .filter(Lesson.self, \.$startsAt >= ninetyDaysAgo)
            .filter(\.$deletedAt == .null)
            .all()
        else { return ([], [], []) }

        // Count bookings per student, and track weekday+hour matches
        var totalBookings: [UUID: Int] = [:]
        var exactMatches: [UUID: Int] = [:]    // same weekday + hour
        var hourMatches: [UUID: Int] = [:]     // same hour, any weekday

        for booking in recentBookings {
            let studentID = booking.$user.id
            guard let joinedLesson = try? booking.joined(Lesson.self) else { continue }

            totalBookings[studentID, default: 0] += 1

            let bWeekday = cal.component(.weekday, from: joinedLesson.startsAt)
            let bHour = cal.component(.hour, from: joinedLesson.startsAt)

            if bWeekday == weekday && bHour == hour {
                exactMatches[studentID, default: 0] += 1
            } else if bHour == hour {
                hourMatches[studentID, default: 0] += 1
            }
        }

        // Load all candidate users in one query
        let allStudentIDs = Array(totalBookings.keys)
        guard let users = try? await User.query(on: db)
            .filter(\.$id ~~ allStudentIDs)
            .filter(\.$role == "student")
            .all()
        else { return ([], [], []) }

        var p1: [User] = []
        var p2: [User] = []
        var p3: [User] = []

        for user in users {
            guard let uid = user.id, user.fcmToken != nil else { continue }
            if (exactMatches[uid] ?? 0) >= 2 {
                p1.append(user)
            } else if (hourMatches[uid] ?? 0) >= 2 {
                p2.append(user)
            } else if (totalBookings[uid] ?? 0) >= 1 {
                p3.append(user)
            }
        }

        // Ensure P2 and P3 are disjoint from higher priority groups
        let p1IDs = Set(p1.compactMap(\.id))
        let p2IDs = Set(p2.compactMap(\.id))
        let filteredP2 = p2.filter { !p1IDs.contains($0.id!) }
        let filteredP3 = p3.filter { !p1IDs.contains($0.id!) && !p2IDs.contains($0.id!) }

        return (p1, filteredP2, filteredP3)
    }

    // MARK: - FCM send

    private func send(users: [User], lesson: Lesson, stage: String, on db: Database) async {
        guard let lessonID = try? lesson.requireID() else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM 'at' HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        let slotString = formatter.string(from: lesson.startsAt)
        let title = "Lesson slot available"
        let body = "\(slotString) has become available — tap to book."

        var sent = 0
        for user in users {
            guard let token = user.fcmToken else { continue }
            if let fcm = FCMNotificationService(app: app) {
                try? await fcm.send(to: token, title: title, body: body)
                sent += 1
            }
        }

        app.logger.info("[Recovery] \(stage) sent to \(sent)/\(users.count) students for lessonID=\(lessonID)")

        // Log to RecoveryEvent for audit trail
        let event = RecoveryEvent(
            lessonID: lessonID,
            stage: stage,
            result: sent > 0 ? "fcm_delivered" : "no_fcm_tokens",
            clientCount: users.count
        )
        try? await event.save(on: db)
    }
}
