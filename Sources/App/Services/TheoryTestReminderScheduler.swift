import Vapor

/// Runs the theory-test reminder cycle once a day.
/// Registered in configure.swift via `app.lifecycle.use(TheoryTestReminderLifecycle())`.
final class TheoryTestReminderLifecycle: LifecycleHandler {

    func didBoot(_ app: Application) throws {
        let logger = app.logger
        logger.notice("[TheoryTestReminder] Scheduler starting — 24-hour cycle.")

        Task {
            while !Task.isCancelled {
                let service = TheoryTestReminderService(db: app.db, app: app, logger: logger)
                await service.runCycle()
                try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
            }
        }
    }
}
