import Vapor
import Fluent

/// Runs every 15 minutes via PaymentEnforcementScheduler.
/// For every active upcoming booking that isn't covered:
///   T-48h  → reminder push
///   7pm UK on the T-48h calendar day (next day for first-lesson students) → warning push
///   8pm UK on that same day → auto-cancel, account hold
struct PaymentEnforcementService {

    let db: Database
    let app: Application
    let logger: Logger

    private static let ukTimeZone = TimeZone(identifier: "Europe/London")!

    // MARK: - Entry point

    func runCycle() async {
        let now = Date()
        logger.info("[PaymentEnforcement] Cycle started at \(now)")

        // Find lessons starting within the next 50 hours (48h + 2h buffer).
        let windowEnd = now.addingTimeInterval(50 * 3_600)
        let lessonIDs: [UUID]
        do {
            lessonIDs = try await Lesson.query(on: db)
                .filter(\.$startsAt > now)
                .filter(\.$startsAt <= windowEnd)
                .all()
                .compactMap { $0.id }
        } catch {
            logger.error("[PaymentEnforcement] Failed to query upcoming lessons: \(error)")
            return
        }

        guard !lessonIDs.isEmpty else { return }

        // Fetch all active bookings for those lessons.
        let bookings: [Booking]
        do {
            bookings = try await Booking.query(on: db)
                .filter(\.$lesson.$id ~~ lessonIDs)
                .filter(\.$deletedAt == .null)
                .with(\.$lesson)
                .with(\.$user)
                .all()
        } catch {
            logger.error("[PaymentEnforcement] Failed to query bookings: \(error)")
            return
        }

        for booking in bookings {
            await processBooking(booking, now: now)
        }

        logger.info("[PaymentEnforcement] Cycle complete — processed \(bookings.count) booking(s).")
    }

    // MARK: - Per-booking logic

    private func processBooking(_ booking: Booking, now: Date) async {
        guard let bookingID = booking.id else { return }
        let lesson = booking.lesson
        guard let lessonID = lesson.id else { return }
        let studentID = booking.$user.id
        let startsAt = lesson.startsAt

        // Only act once we're inside the 48-hour window.
        let threshold = startsAt.addingTimeInterval(-48 * 3_600)
        guard now >= threshold else { return }

        // Skip if already covered.
        do {
            if let lf = try await LessonFinance.find(lessonID, on: db) {
                if lf.financeStatus == "covered" { return }
            }
        } catch {
            logger.error("[PaymentEnforcement] Coverage lookup failed for booking \(bookingID): \(error)")
            return
        }

        // First-lesson check: no prior ConfirmedLessons for this student.
        let isFirst = await isFirstLesson(studentID: studentID)

        // Compute the effective 7pm/8pm enforcement day in UK local time.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.ukTimeZone

        // Base day = the calendar day on which T-48h falls.
        // First-lesson students get an extra 24 hours (enforcement moves to the next day).
        var enforcementDay = cal.startOfDay(for: threshold)
        if isFirst {
            enforcementDay = cal.date(byAdding: .day, value: 1, to: enforcementDay)!
        }

        let warningTime = cal.date(bySettingHour: 19, minute: 0, second: 0, of: enforcementDay)!
        let cancelTime  = cal.date(bySettingHour: 20, minute: 0, second: 0, of: enforcementDay)!

        // ── Auto-cancel at 8pm ────────────────────────────────────────────────
        // If the cancel deadline has already passed but this booking was created
        // AFTER that deadline (student booked within the 48h window), give them
        // 2 hours from creation before auto-cancelling.
        let effectiveCancelTime: Date
        if let createdAt = booking.createdAt, createdAt > cancelTime {
            effectiveCancelTime = createdAt.addingTimeInterval(2 * 3_600)
        } else {
            effectiveCancelTime = cancelTime
        }

        if now >= effectiveCancelTime {
            await performAutoCancel(booking: booking, lesson: lesson, studentID: studentID)
            return
        }

        // ── Warning push at 7pm ───────────────────────────────────────────────
        if now >= warningTime && booking.paymentWarningSentAt == nil {
            await sendWarningPush(studentID: studentID, lesson: lesson)
            booking.paymentWarningSentAt = Date()
            try? await booking.save(on: db)
        }

        // ── 48h reminder push (sent as soon as we enter the window) ──────────
        if booking.paymentReminderSentAt == nil {
            await sendReminderPush(studentID: studentID, lesson: lesson)
            booking.paymentReminderSentAt = Date()
            try? await booking.save(on: db)
        }
    }

    // MARK: - Auto-cancel

    private func performAutoCancel(booking: Booking, lesson: Lesson, studentID: UUID) async {
        guard let bookingID = booking.id, let lessonID = lesson.id else { return }

        // Already soft-deleted by a previous cycle run — skip.
        guard booking.deletedAt == nil else { return }

        logger.notice("[PaymentEnforcement] Auto-cancelling booking \(bookingID) for student \(studentID) — unpaid at 8pm deadline.")

        do {
            // Determine charge amount.
            let chargeAmount: Decimal
            if let snapshot = try await LessonFinance.find(lessonID, on: db)?.priceSnapshot, snapshot > 0 {
                chargeAmount = snapshot
            } else {
                let mins = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
                chargeAmount = (Decimal(45) * Decimal(mins)) / Decimal(60)
            }

            // Resolve instructor ID for the ledger entry.
            guard let instructor = try await User.query(on: db).filter(\.$role == "instructor").first(),
                  let instructorID = instructor.id else {
                logger.error("[PaymentEnforcement] No instructor found — cannot auto-cancel booking \(bookingID).")
                return
            }

            // Soft-delete booking with system_auto_cancel source.
            booking.cancellationType = "late_cancellation"
            booking.cancellationSource = "system_auto_cancel"
            try await booking.save(on: db)    // persist cancellation fields first
            try await booking.delete(on: db)  // then soft-delete (sets deletedAt)

            // Stamp LessonFinance.
            if let lf = try await LessonFinance.find(lessonID, on: db) {
                lf.fullChargeApplied = true
                try await lf.save(on: db)
            }

            // Debit ledger.
            let charge = LedgerEntry(
                studentID: studentID,
                instructorID: instructorID,
                lessonID: lessonID,
                type: "late_cancellation_charge",
                amount: -chargeAmount,
                note: "Auto-cancelled (unpaid after 48h deadline)",
                effectiveDate: Date()
            )
            try await charge.save(on: db)

            // Release lesson slot back to available.
            lesson.state = "available"
            try await lesson.save(on: db)

            // Set account hold on StudentProfile.
            if let profile = try await StudentProfile.query(on: db)
                .filter(\.$user.$id == studentID)
                .first() {
                profile.accountHold = true
                profile.accountHoldReason = "Unpaid lesson auto-cancelled. Pay the outstanding charge to restore access."
                try await profile.save(on: db)
            }

            // Broadcast freed slot to instructor hub.
            app.broadcastRecoveryCandidate(for: lesson)

            // Push notification to student.
            if let user = try? await User.find(studentID, on: db),
               let fcmToken = user.fcmToken,
               let fcm = FCMNotificationService(app: app) {
                try? await fcm.send(
                    to: fcmToken,
                    title: "Lesson Cancelled — Payment Not Received",
                    body: "Your lesson has been released. Your account is on hold until the outstanding balance is settled."
                )
            }

            logger.notice("[PaymentEnforcement] ✅ Auto-cancel complete for booking \(bookingID) — account hold set for student \(studentID).")

        } catch {
            logger.error("[PaymentEnforcement] Auto-cancel failed for booking \(bookingID): \(error)")
        }
    }

    // MARK: - Push helpers

    private func sendReminderPush(studentID: UUID, lesson: Lesson) async {
        guard let user = try? await User.find(studentID, on: db),
              let fcmToken = user.fcmToken,
              let fcm = FCMNotificationService(app: app) else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = Self.ukTimeZone
        let dateStr = formatter.string(from: lesson.startsAt)

        try? await fcm.send(
            to: fcmToken,
            title: "Payment Reminder",
            body: "Your lesson on \(dateStr) needs to be paid. Open the app to pay now."
        )
        logger.info("[PaymentEnforcement] Reminder push sent for student \(studentID).")
    }

    private func sendWarningPush(studentID: UUID, lesson: Lesson) async {
        guard let user = try? await User.find(studentID, on: db),
              let fcmToken = user.fcmToken,
              let fcm = FCMNotificationService(app: app) else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = Self.ukTimeZone
        let dateStr = formatter.string(from: lesson.startsAt)

        try? await fcm.send(
            to: fcmToken,
            title: "⚠️ Final Warning — Lesson at Risk",
            body: "Your lesson on \(dateStr) will be cancelled at 8pm tonight if payment is not received."
        )
        logger.info("[PaymentEnforcement] Warning push sent for student \(studentID).")
    }

    // MARK: - First-lesson detection

    private func isFirstLesson(studentID: UUID) async -> Bool {
        let count = (try? await ConfirmedLesson.query(on: db)
            .filter(\.$user.$id == studentID)
            .count()) ?? 0
        return count == 0
    }
}
