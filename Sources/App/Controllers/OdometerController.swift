import Vapor
import Fluent
import Foundation

struct OdometerController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - DTOs

    struct OdometerEntryDTO: Content {
        let id: UUID
        let date: Date
        let odometer: Double?
        let dailyMiles: Double
        let isGapEntry: Bool
        let createdAt: Date?
    }

    struct OdometerStatsResponse: Content {
        let entries: [OdometerEntryDTO]
        let sevenDayAvg: Double
        let thirtyDayAvg: Double
        let weekTotal: Double
        let lastOdometer: Double?
    }

    struct LogReadingRequest: Content {
        let date: Date       // the day being logged (yesterday from the caller's perspective)
        let odometer: Double // total odometer reading
    }

    struct GapEntryItem: Content {
        let date: Date
        let dailyMiles: Double
    }

    struct LogGapEntriesRequest: Content {
        let entries: [GapEntryItem]
    }

    // MARK: - GET /instructor/odometer

    func list(_ req: Request) async throws -> OdometerStatsResponse {
        let all = try await OdometerEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .all()

        let now = Date()
        var londonCal = Calendar(identifier: .gregorian)
        londonCal.timeZone = TimeZone(identifier: "Europe/London")!
        londonCal.firstWeekday = 2  // Monday
        let sevenAgo  = londonCal.date(byAdding: .day, value: -7,  to: now)!
        let thirtyAgo = londonCal.date(byAdding: .day, value: -30, to: now)!
        let weekStart = londonCal.date(from: londonCal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: now))!

        let sevenDayMiles  = all.filter { $0.date >= sevenAgo  }.reduce(0) { $0 + $1.dailyMiles }
        let thirtyDayMiles = all.filter { $0.date >= thirtyAgo }.reduce(0) { $0 + $1.dailyMiles }
        let weekMiles      = all.filter { $0.date >= weekStart  }.reduce(0) { $0 + $1.dailyMiles }
        let lastOdometer   = all.first(where: { $0.odometer != nil })?.odometer

        let rows = all.map { e in
            OdometerEntryDTO(id: e.id!, date: e.date, odometer: e.odometer,
                             dailyMiles: e.dailyMiles, isGapEntry: e.isGapEntry,
                             createdAt: e.createdAt)
        }

        return OdometerStatsResponse(
            entries: rows,
            sevenDayAvg:  sevenDayMiles  / 7,
            thirtyDayAvg: thirtyDayMiles / 30,
            weekTotal:    weekMiles,
            lastOdometer: lastOdometer
        )
    }

    // MARK: - GET /instructor/odometer/last

    func lastEntry(_ req: Request) async throws -> Response {
        let entry = try await OdometerEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .first()
        guard let entry else {
            return Response(status: .noContent)
        }
        let dto = OdometerEntryDTO(id: entry.id!, date: entry.date, odometer: entry.odometer,
                                   dailyMiles: entry.dailyMiles, isGapEntry: entry.isGapEntry,
                                   createdAt: entry.createdAt)
        return try await dto.encodeResponse(for: req)
    }

    // MARK: - POST /instructor/odometer

    func logReading(_ req: Request) async throws -> OdometerEntryDTO {
        let body = try req.content.decode(LogReadingRequest.self)

        // Find last entry with a full odometer reading to calculate delta
        let lastFull = try await OdometerEntry.query(on: req.db)
            .filter(\.$odometer != nil)
            .sort(\.$date, .descending)
            .first()

        var dailyMiles: Double = 0
        if let last = lastFull, let lastOdo = last.odometer {
            // Sum any gap entries between the last full reading and this entry
            let gapMiles = try await OdometerEntry.query(on: req.db)
                .filter(\.$isGapEntry == true)
                .filter(\.$date > last.date)
                .filter(\.$date < body.date)
                .all()
                .reduce(0.0) { $0 + $1.dailyMiles }
            dailyMiles = max(0, body.odometer - lastOdo - gapMiles)
        }

        let entry = OdometerEntry(date: body.date, odometer: body.odometer,
                                  dailyMiles: dailyMiles, isGapEntry: false)
        try await entry.save(on: req.db)

        return OdometerEntryDTO(id: entry.id!, date: entry.date, odometer: entry.odometer,
                                dailyMiles: entry.dailyMiles, isGapEntry: entry.isGapEntry,
                                createdAt: entry.createdAt)
    }

    // MARK: - POST /instructor/odometer/gap

    func logGapEntries(_ req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(LogGapEntriesRequest.self)
        for item in body.entries {
            let entry = OdometerEntry(date: item.date, odometer: nil,
                                      dailyMiles: item.dailyMiles, isGapEntry: true)
            try await entry.save(on: req.db)
        }
        return .ok
    }

    // MARK: - DELETE /instructor/odometer/:entryID

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid entry ID")
        }
        guard let entry = try await OdometerEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await entry.delete(on: req.db)
        return .noContent
    }
}
