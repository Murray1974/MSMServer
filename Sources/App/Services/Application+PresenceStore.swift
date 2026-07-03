import Vapor
import Foundation

private struct StudentLastSeenKey: StorageKey {
    typealias Value = [UUID: Date]
}

private struct InstructorLastSeenKey: StorageKey {
    typealias Value = Date
}

extension Application {
    var studentLastSeen: [UUID: Date] {
        get { storage[StudentLastSeenKey.self] ?? [:] }
        set { storage[StudentLastSeenKey.self] = newValue }
    }

    var instructorLastSeenAt: Date? {
        get { storage[InstructorLastSeenKey.self] }
        set { storage[InstructorLastSeenKey.self] = newValue }
    }
}
