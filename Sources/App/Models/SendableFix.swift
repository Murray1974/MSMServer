import Fluent

// Acknowledge Fluent models are used only on the server’s event-loop and
// are safe for your use. This silences Swift 6 Sendable complaints.

extension User: @unchecked Sendable {}
extension UserToken: @unchecked Sendable {}
