import Vapor

/// Runs the temp-hold-to-loss reclassification cycle on a 6-hour loop.
/// Registered in configure.swift via `app.lifecycle.use(TempHoldReclassificationLifecycle())`.
final class TempHoldReclassificationLifecycle: LifecycleHandler {

    func didBoot(_ app: Application) throws {
        let logger = app.logger
        logger.notice("[TempHoldReclassification] Scheduler starting — 6-hour cycle.")

        Task {
            while !Task.isCancelled {
                let service = TempHoldReclassificationService(db: app.db, logger: logger)
                await service.runCycle()
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
            }
        }
    }
}
