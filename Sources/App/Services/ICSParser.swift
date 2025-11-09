import Foundation

struct ICSParsedEvent: Equatable, Hashable {
    let start: Date
    let end: Date
    let summary: String
}

enum ICSParser {
    /// Minimal .ics parser: extracts VEVENT { DTSTART, DTEND, SUMMARY }
    static func parseEvents(_ ics: String, tz: TimeZone) -> [ICSParsedEvent] {
        var events: [ICSParsedEvent] = []
        var cur: [String:String] = [:]
        var inEvent = false
        var lastKeyParsed: String? = nil

        func flush() {
            guard let ds = cur["DTSTART"], let de = cur["DTEND"] else { return }
            let sum = cur["SUMMARY"] ?? "Unassigned"

            guard let start = parseDate(ds, tz: tz),
                  let end = parseDate(de, tz: tz) else { return }

            events.append(.init(start: start, end: end, summary: sum))
            cur.removeAll()
        }

        for raw in ics.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "BEGIN:VEVENT" { inEvent = true; cur.removeAll(); continue }
            if line == "END:VEVENT" { if inEvent { flush() }; inEvent = false; continue }
            guard inEvent else { continue }

            // Handle folded lines (begins with space)
            if line.hasPrefix(" ") {
                // append to the last parsed key (ICS line folding)
                if let lk = lastKeyParsed, var v = cur[lk] {
                    v += line.trimmingCharacters(in: .whitespaces)
                    cur[lk] = v
                }
                continue
            }

            // Split key:value, also drop parameters like DTSTART;TZID=Europe/London:
            if let idx = line.firstIndex(of: ":") {
                let keyPart = String(line[..<idx])
                let value = String(line[line.index(after: idx)...])
                let key = keyPart.contains(";") ? String(keyPart.split(separator: ";").first!) : keyPart
                cur[key] = value
                lastKeyParsed = key
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    /// Supports Zulu (UTC) or local-like `YYYYMMDDTHHMMSS` (treat as tz)
    private static func parseDate(_ s: String, tz: TimeZone) -> Date? {
        // Support common ICS date/time shapes:
        //  • 20251108T140000Z   (UTC)
        //  • 20251108T140000    (local tz)
        //  • 20251108T1400      (no seconds)
        //  • 20251108           (all-day)
        var raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var isZulu = false
        if raw.hasSuffix("Z") {
            isZulu = true
            raw.removeLast()
        }

        let fmts = [
            "yyyyMMdd'T'HHmmss",
            "yyyyMMdd'T'HHmm",
            "yyyyMMdd" // all-day
        ]

        for fmtStr in fmts {
            let fmt = DateFormatter()
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.timeZone = isZulu ? TimeZone(secondsFromGMT: 0) : tz
            fmt.dateFormat = fmtStr
            if let d = fmt.date(from: raw) {
                // If all-day (date-only), normalize to start of day in tz
                if fmtStr == "yyyyMMdd" {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = tz
                    let comps = cal.dateComponents([.year, .month, .day], from: d)
                    return cal.date(from: comps)
                }
                return d
            }
        }

        return nil
    }
}
