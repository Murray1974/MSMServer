import Vapor
import Fluent

/// Runs every 6 hours via InactivityEnforcementLifecycle.
/// For every currently-active student who has had a first lesson confirmed:
///   Day 14 since last attended lesson, no future lesson booked → reminder push
///   Day 21, same condition → second reminder push
///   Day 28, same condition → auto-deactivate (accountStatus = "inactive") + push
struct InactivityEnforcementService {

    let db: Database
    let app: Application
    let logger: Logger

    // MARK: - Entry point

    func runCycle() async {
        logger.notice("[InactivityEnforcement] Cycle started at \(Date())")

        let profiles: [StudentProfile]
        do {
            profiles = try await StudentProfile.query(on: db)
                .filter(\.$accountStatus == "active")
                .filter(\.$firstLessonConfirmedAt != nil)
                .all()
        } catch {
            logger.error("[InactivityEnforcement] Failed to query student profiles: \(error)")
            return
        }

        for profile in profiles {
            await process(profile)
        }

        logger.notice("[InactivityEnforcement] Cycle complete — evaluated \(profiles.count) student(s).")
    }

    // MARK: - Per-student logic

    private func process(_ profile: StudentProfile) async {
        let studentID = profile.$user.id
        guard let lastLesson = profile.lastAttendedLessonAt else { return }

        let hasFuture = await hasFutureLesson(studentID: studentID)
        guard !hasFuture else { return }

        let days = Calendar.current.dateComponents([.day], from: lastLesson, to: Date()).day ?? 0

        if days >= 28 && profile.inactivityAutoDeactivatedAt == nil {
            await autoDeactivate(profile: profile, studentID: studentID, lastLesson: lastLesson)
        } else if days >= 21 && profile.inactivityStage21SentAt == nil {
            await sendStagePush(studentID: studentID, lastLesson: lastLesson, dayLabel: 21)
            profile.inactivityStage21SentAt = Date()
            try? await profile.save(on: db)
        } else if days >= 14 && profile.inactivityStage14SentAt == nil {
            await sendStagePush(studentID: studentID, lastLesson: lastLesson, dayLabel: 14)
            profile.inactivityStage14SentAt = Date()
            try? await profile.save(on: db)
        }
    }

    /// True if the student has any active (non-cancelled) booking for a lesson that hasn't
    /// started yet. Late-cancelled bookings are already soft-deleted (deletedAt set), so the
    /// plain deletedAt == nil filter already excludes them.
    private func hasFutureLesson(studentID: UUID) async -> Bool {
        let now = Date()
        let bookings = (try? await Booking.query(on: db)
            .filter(\.$user.$id == studentID)
            .filter(\.$deletedAt == .null)
            .with(\.$lesson)
            .all()) ?? []
        return bookings.contains { $0.lesson.startsAt > now }
    }

    // MARK: - Auto-deactivate at day 28

    private func autoDeactivate(profile: StudentProfile, studentID: UUID, lastLesson: Date) async {
        let previousStatus = profile.accountStatus
        profile.accountStatus = "inactive"
        profile.inactivityAutoDeactivatedAt = Date()
        do {
            try await profile.save(on: db)
        } catch {
            logger.error("[InactivityEnforcement] Failed to auto-deactivate student \(studentID): \(error)")
            return
        }

        // Counts as an immediate loss for turnover metrics — no human declared this a hold.
        let event = StudentStatusEvent(
            studentID: studentID,
            fromStatus: previousStatus,
            toStatus: "inactive",
            reason: "auto_archive"
        )
        try? await event.save(on: db)

        logger.notice("[InactivityEnforcement] Auto-deactivated student \(studentID) — no lesson since \(lastLesson), no future lesson booked.")

        // .all (not just .students) — the instructor's existing reconcile listener auto-archives
        // this student locally too, exactly as it does for a self-deactivation.
        app.broadcastAccountStatusUpdated(studentID: studentID, status: "inactive", to: .all)

        // Push directly to the student.
        if let user = try? await User.find(studentID, on: db),
           let fcmToken = user.fcmToken,
           let fcm = FCMNotificationService(app: app) {
            try? await fcm.send(
                to: fcmToken,
                title: "Account set to inactive",
                body: "It's been 28 days since your last lesson with no upcoming lessons booked, so we've paused your account. You can reactivate any time in the app."
            )
        }

        // Push to the instructor too, since this is a genuine status change — mirrors Part A's
        // instructor-facing notification for a manual/self status change.
        if let instructor = try? await User.query(on: db).filter(\.$role == "instructor").first(),
           let fcmToken = instructor.fcmToken,
           let fcm = FCMNotificationService(app: app) {
            let name = [profile.firstName, profile.lastName].compactMap { $0 }.joined(separator: " ")
            try? await fcm.send(
                to: fcmToken,
                title: "Student auto-archived",
                body: "\(name.isEmpty ? "A student" : name) was automatically set to Inactive after 28 days without a lesson."
            )
        }
    }

    // MARK: - Stage 14 / 21 reminder pushes

    private func sendStagePush(studentID: UUID, lastLesson: Date, dayLabel: Int) async {
        guard let user = try? await User.find(studentID, on: db),
              let fcmToken = user.fcmToken,
              let fcm = FCMNotificationService(app: app) else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        let dateStr = formatter.string(from: lastLesson)

        try? await fcm.send(
            to: fcmToken,
            title: "It's been a while!",
            body: "Your last lesson was on \(dateStr) and you don't have any upcoming lessons booked. Book your next one when you're ready."
        )
        logger.info("[InactivityEnforcement] Stage \(dayLabel) reminder push sent for student \(studentID).")
    }
}
