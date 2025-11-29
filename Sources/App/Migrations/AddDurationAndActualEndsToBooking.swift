//
//  AddDurationAndActualEndsToBooking.swift
//  MSMServer
//
//  Created by Michael Murray on 20/11/2025.
//

import Fluent

struct AddDurationAndActualEndsToBooking: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Booking.schema)
            .field("duration_minutes", .int)
            .field("actual_ends_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Booking.schema)
            .deleteField("duration_minutes")
            .deleteField("actual_ends_at")
            .update()
    }
}
