import Vapor

extension Request {
    /// Best-effort client IP (X-Forwarded-For > Forwarded > remoteAddress)
    var clientIP: String {
        if let xff = headers.first(name: "X-Forwarded-For")?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespaces)
        {
            return xff
        }
        if let fwd = headers.first(name: "Forwarded") {
            // e.g. "for=1.2.3.4"
            if let forPart = fwd
                .split(separator: ";")
                .first(where: { $0.lowercased().starts(with: "for=") }) {
                return forPart.replacingOccurrences(of: "for=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}
