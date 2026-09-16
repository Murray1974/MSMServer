import Vapor

/// Runs the inactivity enforcement cycle on a 6-hour loop.
/// Registered in configure.swift via `app.lifecycle.use(InactivityEnforcementLifecycle())`.
final class InactivityEnforcementLifecycle: LifecycleHandler {

    func didBoot(_ app: Application) throws {
        let logger = app.logger
        logger.notice("[InactivityEnforcement] Scheduler starting — 6-hour cycle.")

        Task {
            while !Task.isCancelled {
                let service = InactivityEnforcementService(db: app.db, app: app, logger: logger)
                await service.runCycle()
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
            }
        }
    }
}
