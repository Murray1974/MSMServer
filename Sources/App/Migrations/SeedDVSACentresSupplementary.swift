import Fluent
import Vapor

// Fills gaps in Scotland and Wales not captured by the initial seed.
struct SeedDVSACentresSupplementary: AsyncMigration {

    private final class DVSACentreRow: Model, @unchecked Sendable {
        static let schema = "dvsa_centres"
        @ID(key: .id) var id: UUID?
        @Field(key: "name")   var name: String
        @Field(key: "region") var region: String
        init() {}
        init(name: String, region: String) { self.name = name; self.region = region }
    }

    func prepare(on database: Database) async throws {
        let centres: [(name: String, region: String)] = [
            // Scotland — missed by initial seed
            ("Callander",                "Scotland"),
            ("Dunfermline",              "Scotland"),
            ("Falkirk",                  "Scotland"),
            ("Girvan",                   "Scotland"),
            ("Glasgow (Springburn Park)","Scotland"),
            ("Kilmarnock",               "Scotland"),
            ("Lairg",                    "Scotland"),
            ("Newton Stewart",           "Scotland"),
            ("Wigtown",                  "Scotland"),

            // Wales — missed by initial seed
            ("Cardiff (Fairwater)",      "Wales"),
            ("Lampeter",                 "Wales"),
            ("Llandrindod Wells",        "Wales"),
            ("Welshpool",                "Wales"),
        ]

        // Only insert if not already present (safe to re-run)
        let existing = try await DVSACentreRow.query(on: database).all()
        let existingNames = Set(existing.map { $0.name })

        for (name, region) in centres where !existingNames.contains(name) {
            try await DVSACentreRow(name: name, region: region).save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        let names: [String] = [
            "Callander", "Dunfermline", "Falkirk", "Girvan",
            "Glasgow (Springburn Park)", "Kilmarnock", "Lairg",
            "Newton Stewart", "Wigtown",
            "Cardiff (Fairwater)", "Lampeter", "Llandrindod Wells", "Welshpool",
        ]
        try await DVSACentreRow.query(on: database)
            .filter(\.$name ~~ names)
            .delete()
    }
}
