import Vapor
import Fluent
import Foundation

struct FuelController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - DTOs

    struct FuelEntryDTO: Content {
        let id: UUID
        let date: Date
        let vendor: String
        let totalCost: Double
        let pencePerLitre: Double
        let litres: Double
        let odometerReading: Double
        let isFullTank: Bool
        let milesSinceLastFill: Double?
        let mpg: Double?
        let costPerMile: Double?
        let createdAt: Date?
    }

    struct FuelStatsResponse: Content {
        let entries: [FuelEntryDTO]
        let averageMPG: Double?
        let totalSpendThisMonth: Double
        let totalSpendThisYear: Double
        let cheapestVendor: String?
    }

    struct LogFuelRequest: Content {
        let date: Date
        let vendor: String
        let totalCost: Double
        let pencePerLitre: Double
        let litres: Double
        let odometerReading: Double
        let isFullTank: Bool
    }

    // MARK: - GET /instructor/fuel

    func list(_ req: Request) async throws -> FuelStatsResponse {
        let all = try await FuelEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .all()

        let now = Date()
        var londonCal = Calendar(identifier: .gregorian)
        londonCal.timeZone = TimeZone(identifier: "Europe/London")!

        let monthStart = londonCal.date(from: londonCal.dateComponents([.year, .month], from: now))!
        let yearStart  = londonCal.date(from: londonCal.dateComponents([.year], from: now))!

        let monthEntries = all.filter { $0.date >= monthStart }
        let yearEntries  = all.filter { $0.date >= yearStart }

        let validMPGs = all.compactMap { $0.mpg }.filter { $0 > 0 }
        let averageMPG: Double? = validMPGs.isEmpty ? nil : validMPGs.reduce(0, +) / Double(validMPGs.count)

        let totalSpendThisMonth = monthEntries.reduce(0) { $0 + $1.totalCost }
        let totalSpendThisYear  = yearEntries.reduce(0)  { $0 + $1.totalCost }

        // Cheapest vendor by average pence per litre
        var vendorTotals: [String: (total: Double, count: Int)] = [:]
        for entry in all {
            let existing = vendorTotals[entry.vendor] ?? (0, 0)
            vendorTotals[entry.vendor] = (existing.total + entry.pencePerLitre, existing.count + 1)
        }
        let cheapestVendor = vendorTotals
            .mapValues { $0.total / Double($0.count) }
            .min(by: { $0.value < $1.value })?.key

        let rows = all.map { toDTO($0) }

        return FuelStatsResponse(
            entries: rows,
            averageMPG: averageMPG,
            totalSpendThisMonth: totalSpendThisMonth,
            totalSpendThisYear: totalSpendThisYear,
            cheapestVendor: cheapestVendor
        )
    }

    // MARK: - POST /instructor/fuel

    func log(_ req: Request) async throws -> FuelEntryDTO {
        let body = try req.content.decode(LogFuelRequest.self)

        // Find previous fill-up for derived calculations
        let previous = try await FuelEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .first()

        var milesSinceLastFill: Double? = nil
        var mpg: Double? = nil
        var costPerMile: Double? = nil

        if let prev = previous {
            let miles = body.odometerReading - prev.odometerReading
            if miles > 0 {
                milesSinceLastFill = miles
                costPerMile = (body.totalCost * 100) / miles

                // MPG only reliable if both this fill and the previous were full tanks
                if body.isFullTank && prev.isFullTank {
                    let litresPerGallon = 4.54609
                    let gallons = body.litres / litresPerGallon
                    mpg = gallons > 0 ? miles / gallons : nil
                }
            }
        }

        let entry = FuelEntry(
            date: body.date,
            vendor: body.vendor,
            totalCost: body.totalCost,
            pencePerLitre: body.pencePerLitre,
            litres: body.litres,
            odometerReading: body.odometerReading,
            isFullTank: body.isFullTank,
            milesSinceLastFill: milesSinceLastFill,
            mpg: mpg,
            costPerMile: costPerMile
        )
        try await entry.save(on: req.db)
        return toDTO(entry)
    }

    // MARK: - DELETE /instructor/fuel/:entryID

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid entry ID")
        }
        guard let entry = try await FuelEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await entry.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func toDTO(_ e: FuelEntry) -> FuelEntryDTO {
        FuelEntryDTO(
            id: e.id!,
            date: e.date,
            vendor: e.vendor,
            totalCost: e.totalCost,
            pencePerLitre: e.pencePerLitre,
            litres: e.litres,
            odometerReading: e.odometerReading,
            isFullTank: e.isFullTank,
            milesSinceLastFill: e.milesSinceLastFill,
            mpg: e.mpg,
            costPerMile: e.costPerMile,
            createdAt: e.createdAt
        )
    }
}
