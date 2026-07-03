import Fluent
import Vapor

struct SeedDVSACentresScotlandWales: AsyncMigration {

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
            // Scotland
            ("Aberdeen North",           "Scotland"),
            ("Aberdeen South (Cove)",    "Scotland"),
            ("Aberfeldy",                "Scotland"),
            ("Airdrie",                  "Scotland"),
            ("Alness",                   "Scotland"),
            ("Arbroath",                 "Scotland"),
            ("Ayr",                      "Scotland"),
            ("Ballater",                 "Scotland"),
            ("Banff",                    "Scotland"),
            ("Bishopbriggs",             "Scotland"),
            ("Buckie",                   "Scotland"),
            ("Campbeltown",              "Scotland"),
            ("Castle Douglas",           "Scotland"),
            ("Crieff",                   "Scotland"),
            ("Cumnock",                  "Scotland"),
            ("Dumbarton",                "Scotland"),
            ("Dumfries",                 "Scotland"),
            ("Dundee",                   "Scotland"),
            ("Dunoon",                   "Scotland"),
            ("Duns",                     "Scotland"),
            ("East Kilbride",            "Scotland"),
            ("Edinburgh (Currie)",       "Scotland"),
            ("Edinburgh (Musselburgh)",  "Scotland"),
            ("Elgin",                    "Scotland"),
            ("Forfar",                   "Scotland"),
            ("Fort William",             "Scotland"),
            ("Fraserburgh",              "Scotland"),
            ("Gairloch",                 "Scotland"),
            ("Galashiels",               "Scotland"),
            ("Glasgow (Anniesland)",     "Scotland"),
            ("Glasgow (Baillieston)",    "Scotland"),
            ("Glasgow (Shieldhall)",     "Scotland"),
            ("Golspie",                  "Scotland"),
            ("Grangemouth",              "Scotland"),
            ("Grantown-On-Spey",         "Scotland"),
            ("Greenock",                 "Scotland"),
            ("Haddington",               "Scotland"),
            ("Hamilton",                 "Scotland"),
            ("Hawick",                   "Scotland"),
            ("Huntly",                   "Scotland"),
            ("Inveraray",                "Scotland"),
            ("Inverness (Seafield Road)","Scotland"),
            ("Inverurie",                "Scotland"),
            ("Irvine",                   "Scotland"),
            ("Islay Island",             "Scotland"),
            ("Isle of Mull",             "Scotland"),
            ("Isle of Skye (Portree)",   "Scotland"),
            ("Kelso",                    "Scotland"),
            ("Kingussie",                "Scotland"),
            ("Kirkcaldy",                "Scotland"),
            ("Kyle of Lochalsh",         "Scotland"),
            ("Lanark",                   "Scotland"),
            ("Lerwick",                  "Scotland"),
            ("Livingston",               "Scotland"),
            ("Lochgilphead",             "Scotland"),
            ("Mallaig",                  "Scotland"),
            ("Montrose",                 "Scotland"),
            ("Oban",                     "Scotland"),
            ("Orkney",                   "Scotland"),
            ("Paisley",                  "Scotland"),
            ("Peebles",                  "Scotland"),
            ("Perth (Arran Road)",       "Scotland"),
            ("Peterhead",                "Scotland"),
            ("Pitlochry",                "Scotland"),
            ("Rothesay",                 "Scotland"),
            ("Stirling",                 "Scotland"),
            ("Stornoway",                "Scotland"),
            ("Stranraer",                "Scotland"),
            ("Thurso",                   "Scotland"),
            ("Ullapool",                 "Scotland"),
            ("Wick",                     "Scotland"),

            // Wales
            ("Abergavenny",              "Wales"),
            ("Aberystwyth (Park Avenue)","Wales"),
            ("Bala",                     "Wales"),
            ("Bangor",                   "Wales"),
            ("Barry",                    "Wales"),
            ("Brecon",                   "Wales"),
            ("Bridgend",                 "Wales"),
            ("Cardigan",                 "Wales"),
            ("Cardiff (Llanishen)",      "Wales"),
            ("Carmarthen",               "Wales"),
            ("Llanelli",                 "Wales"),
            ("Llantrisant",              "Wales"),
            ("Merthyr Tydfil",           "Wales"),
            ("Monmouth",                 "Wales"),
            ("Newport (Gwent)",          "Wales"),
            ("Newtown",                  "Wales"),
            ("Pembroke Dock",            "Wales"),
            ("Pwllheli",                 "Wales"),
            ("Rhyl",                     "Wales"),
            ("Swansea",                  "Wales"),
            ("Wrexham",                  "Wales"),
        ]

        for (name, region) in centres {
            try await DVSACentreRow(name: name, region: region).save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await DVSACentreRow.query(on: database)
            .filter(\.$region ~~ ["Scotland", "Wales"])
            .delete()
    }
}
