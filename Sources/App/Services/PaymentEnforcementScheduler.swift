import Vapor

/// Runs the payment enforcement cycle on a 15-minute loop.
/// Registered in configure.swift via `app.lifecycle.use(PaymentEnforcementLifecycle())`.
final class PaymentEnforcementLifecycle: LifecycleHandler {

    func didBoot(_ app: Application) throws {
        let logger = app.logger
        logger.notice("[PaymentEnforcement] Scheduler starting — 15-minute cycle.")

        Task {
            while !Task.isCancelled {
                let service = PaymentEnforcementService(db: app.db, app: app, logger: logger)
                await service.runCycle()
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            }
        }
    }
}
