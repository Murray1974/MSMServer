import Fluent

struct CreateSyllabusTopic: AsyncMigration {

    // The 27 DVSA Essential Skills topics: (name, category, displayOrder)
    static let topics: [(String, String, Int)] = [
        // The Basics
        ("Cockpit Drill & Safety Checks",     "The Basics",                   1),
        ("Controls & Instruments",             "The Basics",                   2),
        // Moving Off & Stopping
        ("Moving Off Normally",                "Moving Off & Stopping",        3),
        ("Moving Off at an Angle",             "Moving Off & Stopping",        4),
        ("Moving Off on a Gradient",           "Moving Off & Stopping",        5),
        ("Stopping Normally",                  "Moving Off & Stopping",        6),
        // Mirrors, Signals & Manoeuvre
        ("MSM / PSL Routine",                  "Mirrors, Signals & Manoeuvre", 7),
        ("Signalling",                         "Mirrors, Signals & Manoeuvre", 8),
        // Junctions
        ("Turning Left at Junctions",          "Junctions",                    9),
        ("Turning Right at Junctions",         "Junctions",                   10),
        ("Emerging Left at Junctions",         "Junctions",                   11),
        ("Emerging Right at Junctions",        "Junctions",                   12),
        ("Crossroads",                         "Junctions",                   13),
        // Roundabouts
        ("Roundabouts",                        "Roundabouts",                 14),
        ("Mini-Roundabouts",                   "Roundabouts",                 15),
        // Road Position & Progress
        ("Road Positioning",                   "Road Position & Progress",    16),
        ("Lane Discipline",                    "Road Position & Progress",    17),
        ("Making Progress",                    "Road Position & Progress",    18),
        // Pedestrian Crossings
        ("Pedestrian Crossings",               "Pedestrian Crossings",        19),
        // Dual Carriageways
        ("Dual Carriageways & High-Speed Roads","Dual Carriageways",          20),
        // Emergency Situations
        ("Emergency Stop",                     "Emergency Situations",        21),
        ("Adverse Weather & Conditions",       "Emergency Situations",        22),
        // Manoeuvres
        ("Forward Bay Parking",                "Manoeuvres",                  23),
        ("Reverse Bay Parking",                "Manoeuvres",                  24),
        ("Parallel Parking",                   "Manoeuvres",                  25),
        ("Pulling Up on the Right",            "Manoeuvres",                  26),
        // Independent Driving
        ("Independent Driving & Navigation",   "Independent Driving",         27),
    ]

    func prepare(on database: Database) async throws {
        try await database.schema("syllabus_topics")
            .id()
            .field("name",          .string,  .required)
            .field("category",      .string,  .required)
            .field("display_order", .int,     .required)
            .unique(on: "display_order")
            .create()

        for (name, category, order) in Self.topics {
            let topic = SyllabusTopic(name: name, category: category, displayOrder: order)
            try await topic.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("syllabus_topics").delete()
    }
}
