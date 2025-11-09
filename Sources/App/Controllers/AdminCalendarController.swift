import Vapor

struct AdminCalendarController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin", "calendar")
        admin.get("resync", use: resync) // GET /admin/calendar/resync
    }

    func resync(_ req: Request) async throws -> Response {
        let svc = try CalendarSyncService(app: req.application)
        let slots = try await svc.syncAndLog(req)
        let payload = slots.map { s in
            [
                "startsAt": ISO8601DateFormatter().string(from: s.start),
                "endsAt":   ISO8601DateFormatter().string(from: s.end),
                "title":    s.summary
            ]
        }
        return try await payload.encodeResponse(status: .ok, for: req)
    }
}
