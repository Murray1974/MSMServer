import Vapor

/// Runs the theory-certificate-expiry warning cycle once a day.
/// Registered in configure.swift via `app.lifecycle.use(TheoryExpiryWarningLifecycle())`.
final class TheoryExpiryWarningLifecycle: LifecycleHandler {

    func didBoot(_ app: Application) throws {
        let logger = app.logger
        logger.notice("[TheoryExpiryWarning] Scheduler starting — 24-hour cycle.")

        Task {
            while !Task.isCancelled {
                let service = TheoryExpiryWarningService(db: app.db, app: app, logger: logger)
                await service.runCycle()
                try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
            }
        }
    }
}
