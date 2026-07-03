import Vapor

struct ChargeLessonInput: Content {
    let lessonID: UUID
    let instructorID: UUID
    let durationMinutes: Int
    let hourlyRateSnapshot: Decimal
    let priceSnapshot: Decimal
    let note: String?
}
