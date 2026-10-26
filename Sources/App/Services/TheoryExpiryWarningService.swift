import Vapor
import Fluent

/// Runs once a day via TheoryExpiryWarningLifecycle.
/// DVSA theory certificates are valid for 2 years from the test date. For every student who
/// has passed theory and whose certificate expires within the next 6 months, sends a one-shot
/// push to both the student and the instructor. Unlike TheoryTestReminderService (which nags
/// students who haven't passed yet, every 14 days), this fires once per certificate — there's
/// nothing to re-warn about until a new theory test date is recorded.
struct TheoryExpiryWarningService {

    let db: Database
    let app: Application
    let logger: Logger

    static let warningWindow: TimeInterval = 183 * 24 * 60 * 60 // ~6 months

    func runCycle() async {
        logger.notice("[TheoryExpiryWarning] Cycle started at \(Date())")

        let profiles: [StudentProfile]
        do {
            profiles = try await StudentProfile.query(on: db)
                .filter(\.$theoryTestPassed == true)
                .filter(\.$theoryExpiryWarningSentAt == nil)
                .all()
        } catch {
            logger.error("[TheoryExpiryWarning] Failed to query student profiles: \(error)")
            return
        }

        var sent = 0
        for profile in profiles {
            if await process(profile) { sent += 1 }
        }

        logger.notice("[TheoryExpiryWarning] Cycle complete — evaluated \(profiles.count) student(s), sent \(sent) warning(s).")
    }

    private func process(_ profile: StudentProfile) async -> Bool {
        guard let expiry = profile.theoryCertificateExpiryDate else { return false }
        let timeUntilExpiry = expiry.timeIntervalSinceNow
        // Still sends a (late) warning for a certificate that's already within the window even
        // if it's edged past expiry by the time this runs — only skips once it's clearly stale
        // (e.g. a historical record backfilled long after the fact).
        guard timeUntilExpiry <= Self.warningWindow, timeUntilExpiry > -30 * 24 * 60 * 60 else { return false }

        let studentID = profile.$user.id
        guard let fcm = FCMNotificationService(app: app) else { return false }

        let df = DateFormatter()
        df.dateFormat = "d MMMM yyyy"
        df.timeZone = TimeZone(identifier: "Europe/London")
        let expiryLabel = df.string(from: expiry)

        if let user = try? await User.find(studentID, on: db), let fcmToken = user.fcmToken {
            try? await fcm.send(
                to: fcmToken,
                title: "Theory certificate expiring soon",
                body: "Your theory test certificate expires on \(expiryLabel). You'll need to retake it if your practical test isn't booked before then."
            )
        }

        if let instructor = try? await User.query(on: db).filter(\.$role == "instructor").first(),
           let fcmToken = instructor.fcmToken {
            let name = [profile.firstName, profile.lastName].compactMap { $0 }.joined(separator: " ")
            try? await fcm.send(
                to: fcmToken,
                title: "Student theory certificate expiring",
                body: "\(name.isEmpty ? "A student" : name)'s theory certificate expires on \(expiryLabel)."
            )
        }

        profile.theoryExpiryWarningSentAt = Date()
        try? await profile.save(on: db)

        logger.info("[TheoryExpiryWarning] Warning sent for student \(studentID), expiry \(expiryLabel).")
        return true
    }
}
