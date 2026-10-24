import XCTVapor
@testable import App

/// Covers extractStampedLessonID(from:), the parsing logic added to fix the
/// 2026-10-24 duplicate-booking incident: `/instructor/sync/available` was
/// matching slots by exact start/end time only, so resizing an already-booked
/// lesson's calendar event (to show a student's adjusted duration) looked like
/// a brand-new slot and spawned a phantom duplicate lesson + booking. The fix
/// makes the sync match by the event's stamped MSM_LESSON_ID first, falling
/// back to time only for genuinely new/unstamped slots.
final class CalendarSyncMatchingTests: XCTestCase {

    func testExtractsSimpleStamp() {
        let id = UUID()
        let notes = "MSM_LESSON_ID=\(id.uuidString)"
        XCTAssertEqual(extractStampedLessonID(from: notes), id)
    }

    func testExtractsStampAmongOtherNoteLines() {
        let id = UUID()
        let notes = "Pickup: 12 High Street\nMSM_LESSON_ID=\(id.uuidString)\nSome other note"
        XCTAssertEqual(extractStampedLessonID(from: notes), id)
    }

    func testExtractsStampWithSurroundingWhitespace() {
        let id = UUID()
        let notes = "  MSM_LESSON_ID=\(id.uuidString)  \n"
        XCTAssertEqual(extractStampedLessonID(from: notes), id)
    }

    func testReturnsNilForNilNotes() {
        XCTAssertNil(extractStampedLessonID(from: nil))
    }

    func testReturnsNilForEmptyNotes() {
        XCTAssertNil(extractStampedLessonID(from: ""))
    }

    func testReturnsNilWhenNoStampPresent() {
        XCTAssertNil(extractStampedLessonID(from: "Just a regular note, no stamp here."))
    }

    func testReturnsNilForMalformedUUID() {
        XCTAssertNil(extractStampedLessonID(from: "MSM_LESSON_ID=not-a-real-uuid"))
    }

    func testIsCaseSensitiveToThePrefixAsWritten() {
        // MSMAgent always writes the exact uppercase-ish "MSM_LESSON_ID=" prefix.
        // A different casing is deliberately NOT matched — guards against
        // accidentally matching unrelated text that merely resembles it.
        let id = UUID()
        let notes = "msm_lesson_id=\(id.uuidString)"
        XCTAssertNil(extractStampedLessonID(from: notes))
    }

    func testFindsStampEvenWhenNotOnFirstLine() {
        let id = UUID()
        let notes = String(repeating: "filler line\n", count: 5) + "MSM_LESSON_ID=\(id.uuidString)"
        XCTAssertEqual(extractStampedLessonID(from: notes), id)
    }

    func testIgnoresLineThatOnlyContainsPrefixAsSubstring() {
        // Must match the line prefix exactly (after trimming), not merely contain it,
        // so a note that mentions the key mid-sentence doesn't falsely match.
        XCTAssertNil(extractStampedLessonID(from: "See MSM_LESSON_ID=not-at-start"))
    }
}
