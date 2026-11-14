import Fluent

/// Tags a recorded journey with which named Test Route (Resources > Mock Test > Test
/// Routes, `TestRoute` model) it was driven against — so results can later be grouped
/// by route and time-of-day. Nullable with no default: every journey recorded before
/// this (test or real lesson alike) just gets NULL, same as any journey an instructor
/// hasn't tagged yet. See `TestRouteDTO`/`TestRoute.swift` for the routes themselves —
/// deliberately a plain field, not `@Parent`, matching `bookingID`'s own pattern on this
/// model: every read site resolves the route itself rather than relying on a DB-level FK.
struct AddTestRouteIDToLessonJourney: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .field("test_route_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lesson_journeys")
            .deleteField("test_route_id")
            .update()
    }
}
