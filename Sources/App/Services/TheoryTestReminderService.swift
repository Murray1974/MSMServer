import Vapor
import Fluent

/// Runs once a day via TheoryTestReminderLifecycle.
/// For every approved, active student who registered more than 14 days ago and hasn't
/// passed their theory test, sends a reminder push at most once every 14 days.
struct TheoryTestReminderService {

    let db: Database
    let app: Application
    let logger: Logger

    func runCycle() async {
        logger.notice("[TheoryTestReminder] Cycle started at \(Date())")

        let profiles: [StudentProfile]
        do {
            profiles = try await StudentProfile.query(on: db)
                .filter(\.$approvalStatus == "approved")
                .filter(\.$accountStatus == "active")
                .filter(\.$theoryTestPassed == false)
                .all()
        } catch {
            logger.error("[TheoryTestReminder] Failed to query student profiles: \(error)")
            return
        }

        var sent = 0
        for profile in profiles {
            if await process(profile) { sent += 1 }
        }

        logger.notice("[TheoryTestReminder] Cycle complete — evaluated \(profiles.count) student(s), sent \(sent) reminder(s).")
    }

    private func process(_ profile: StudentProfile) async -> Bool {
        guard let registeredAt = profile.tcAcceptedAt else { return false }
        let daysSinceRegistration = Calendar.current.dateComponents([.day], from: registeredAt, to: Date()).day ?? 0
        guard daysSinceRegistration >= 14 else { return false }

        if let dismissedUntil = profile.theoryReminderDismissedUntil, dismissedUntil > Date() {
            return false
        }

        let studentID = profile.$user.id
        guard let user = try? await User.find(studentID, on: db),
              let fcmToken = user.fcmToken,
              let fcm = FCMNotificationService(app: app) else { return false }

        try? await fcm.send(
            to: fcmToken,
            title: "Passed your theory test yet?",
            body: "Let us know in the app so your instructor can plan towards your practical test."
        )

        profile.theoryReminderDismissedUntil = Date().addingTimeInterval(14 * 24 * 60 * 60)
        try? await profile.save(on: db)

        logger.info("[TheoryTestReminder] Reminder push sent for student \(studentID).")
        return true
    }
}
