import Vapor
import Fluent

/// Public lessons listing + protected "book"
struct LessonsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let lessons = routes.grouped("lessons")

        // Public reads (upcoming by default, supports ?start=&end= and ?page=&per=)
        lessons.get(use: list)
        lessons.get(":id", use: detail)
        lessons.get("search", use: searchLessons)

        // Protected actions (requires valid bearer token)
        let protected = lessons.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        protected.post(":id", "book", use: book)
        protected.get("capacity", "remaining-this-week", use: remainingCapacityThisWeek)
        protected.get("slot", "availability", use: slotAvailability)
    }

    struct PageQuery: Content {
        var page: Int?
        var per: Int?
        var start: String?  // ISO8601 datetime (e.g., 2025-10-26T10:00:00Z)
        var end: String?    // ISO8601 datetime
    }

    // GET /lessons?page=1&per=20&start=...&end=...
    // Defaults to upcoming-only if no start/end provided.
    func list(req: Request) async throws -> [Lesson.Public] {
        let q = try? req.query.decode(PageQuery.self)
        let page = max(q?.page ?? 1, 1)
        let per  = min(max(q?.per ?? 20, 1), 100)
        let offset = (page - 1) * per

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate: Date? = {
            if let s = q?.start {
                return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            return nil
        }()

        let endDate: Date? = {
            if let e = q?.end {
                return iso.date(from: e) ?? ISO8601DateFormatter().date(from: e)
            }
            return nil
        }()

        // Base query
        var query = Lesson.query(on: req.db)

        // If no range supplied, default to upcoming-only
        if startDate == nil && endDate == nil {
            query = query.filter(\.$startsAt >= Date())
        } else {
            if let s = startDate {
                query = query.filter(\.$startsAt >= s)
            }
            if let e = endDate {
                query = query.filter(\.$startsAt <= e)
            }
        }

        // Order + pagination
        let items = try await query
            .sort(\.$startsAt, .ascending)
            .range(offset..<(offset + per))
            .all()

        guard !items.isEmpty else { return [] }

        // Compute availability for the page efficiently
        let ids: [UUID] = items.compactMap { $0.id }
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ ids)
            .all()

        var countByLesson: [UUID: Int] = [:]
        for b in bookings {
            let lid = b.$lesson.id
            countByLesson[lid, default: 0] += 1
        }

        return items.map { lesson in
            let used = countByLesson[lesson.id ?? UUID()] ?? 0
            let available = max(lesson.capacity - used, 0)
            return lesson.asPublic(available: available)
        }
    }

    // GET /lessons/:id  (includes availability)
    func detail(req: Request) async throws -> Lesson.Public {
        guard let id = req.parameters.get("id", as: UUID.self),
              let lesson = try await Lesson.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let used = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == id)
            .count()
        let available = max(lesson.capacity - used, 0)
        return lesson.asPublic(available: available)
    }

    // POST /lessons/:id/book  → creates a booking with capacity + duplicate checks
    func book(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let uid = try user.requireID()

        guard let lessonID = req.parameters.get("id", as: UUID.self),
              let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        // Duplicate booking guard (only count active bookings)
        if try await Booking.query(on: req.db)
            .filter(\.$user.$id == uid)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .first() != nil
        {
            throw Abort(.conflict, reason: "You have already booked this lesson.")
        }

        // Capacity check (active bookings only)
        let current = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .count()
        if current >= lesson.capacity {
            throw Abort(.conflict, reason: "Lesson is full.")
        }

        // Create booking, catch partial-unique / duplicate races as 409
        do {
            let booking = Booking(userID: uid, lessonID: try lesson.requireID())
            try await booking.save(on: req.db)
            return .created
        } catch {
            // If DB unique index still trips (race etc), convert to 409 Conflict
            if String(reflecting: error).contains("uq_bookings_user_lesson_active")
                || String(reflecting: error).contains("23505")
            {
                throw Abort(.conflict, reason: "You have already booked this lesson.")
            }
            throw error
        }
    }

    struct FilteredLessonRow: Content {
        var id: UUID?
        var title: String?
        var startsAt: Date?
        var endsAt: Date?
        var capacity: Int
        var booked: Int
        var available: Int
    }

    struct LessonSearchResponse: Content {
        var page: Int
        var per: Int
        var total: Int
        var hasNext: Bool
        var items: [FilteredLessonRow]
    }

    struct RemainingCapacityResponse: Content {
        var from: Date
        var to: Date
        var availableSlots: Int
    }

    struct SlotAvailabilityQuery: Content {
        var weekday: Int?
        var startHour: Int?
        var endHour: Int?
        var lessonID: UUID?
    }

    struct SlotAvailabilityResponse: Content {
        var isAvailable: Bool
    }
    // MARK: GET /lessons/capacity/remaining-this-week
    func remainingCapacityThisWeek(_ req: Request) async throws -> RemainingCapacityResponse {
        _ = try req.auth.require(User.self)

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        calendar.firstWeekday = 2 // Monday

        let now = Date()
        let start = now
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now

        let lessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= start)
            .filter(\.$startsAt < end)
            .filter(\.$state == "available")
            .sort(\.$startsAt, .ascending)
            .all()

        guard !lessons.isEmpty else {
            return RemainingCapacityResponse(from: start, to: end, availableSlots: 0)
        }

        let ids = lessons.compactMap { $0.id }
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ ids)
            .all()

        var countByLesson: [UUID: Int] = [:]
        for booking in bookings {
            let lessonID = booking.$lesson.id
            countByLesson[lessonID, default: 0] += 1
        }

        let availableSlots = lessons.reduce(0) { partial, lesson in
            guard let lessonID = lesson.id else { return partial }
            let booked = countByLesson[lessonID, default: 0]
            let available = max(lesson.capacity - booked, 0)
            return partial + available
        }

        return RemainingCapacityResponse(from: start, to: end, availableSlots: availableSlots)
    }

    // MARK: GET /lessons/slot/availability?weekday=1&startHour=16&endHour=18&lessonID=UUID
    func slotAvailability(_ req: Request) async throws -> SlotAvailabilityResponse {
        _ = try req.auth.require(User.self)
        let q = try req.query.decode(SlotAvailabilityQuery.self)

        // If lessonID is provided, treat that as the source of truth.
        if let lessonID = q.lessonID {
            guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
                return SlotAvailabilityResponse(isAvailable: false)
            }

            let activeBookings = try await Booking.query(on: req.db)
                .filter(\.$lesson.$id == lessonID)
                .filter(\.$deletedAt == nil)
                .count()

            let isAvailable = lesson.state == "available" && activeBookings < lesson.capacity
            return SlotAvailabilityResponse(isAvailable: isAvailable)
        }

        // Fallback to the older slot-pattern lookup if no specific lessonID is supplied.
        guard let weekday = q.weekday,
              let startHour = q.startHour,
              let endHour = q.endHour else {
            return SlotAvailabilityResponse(isAvailable: true)
        }

        let lessons = try await Lesson.query(on: req.db)
            .filter(\.$state == "available")
            .filter(\.$startsAt >= Date())
            .all()

        let cal = Calendar.current
        let matchingLessons = lessons.filter { lesson in
            let lessonWeekday = cal.component(.weekday, from: lesson.startsAt)
            let lessonStartHour = cal.component(.hour, from: lesson.startsAt)
            let lessonEndHour = cal.component(.hour, from: lesson.endsAt)
            return lessonWeekday == weekday && lessonStartHour == startHour && lessonEndHour == endHour
        }

        guard !matchingLessons.isEmpty else {
            return SlotAvailabilityResponse(isAvailable: false)
        }

        let ids = matchingLessons.compactMap { $0.id }
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ ids)
            .filter(\.$deletedAt == nil)
            .all()

        var countByLesson: [UUID: Int] = [:]
        for booking in bookings {
            let lessonID = booking.$lesson.id
            countByLesson[lessonID, default: 0] += 1
        }

        let anyAvailable = matchingLessons.contains { lesson in
            guard let lessonID = lesson.id else { return false }
            let booked = countByLesson[lessonID, default: 0]
            return booked < lesson.capacity
        }

        return SlotAvailabilityResponse(isAvailable: anyAvailable)
    }

    // MARK: GET /lessons/search?from=YYYY-MM-DD&to=YYYY-MM-DD&availableOnly=true&page=1&per=10
    func searchLessons(_ req: Request) async throws -> LessonSearchResponse {
        struct Q: Decodable {
            var from: String?
            var to: String?
            var availableOnly: Bool?
            var page: Int?
            var per: Int?
            // can be "2" or "1,3,5"
            var weekday: String?
            var startHour: Int?
            var endHour: Int?
        }
        let q = try req.query.decode(Q.self)

        let page = max(q.page ?? 1, 1)
        let per  = min(max(q.per ?? 20, 1), 100)
        let offset = (page - 1) * per

        var query = Lesson.query(on: req.db)

        // Date-only ISO (yyyy-MM-dd)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]

        if let fromStr = q.from, let fromDate = iso.date(from: fromStr) {
            query = query.filter(\.$startsAt >= fromDate)
        }
        if let toStr = q.to, let toDate = iso.date(from: toStr) {
            query = query.filter(\.$endsAt <= toDate)
        }

        let total = try await query.count()

        // Fetch a page of lessons
        let items = try await query
            .sort(\.$startsAt, .ascending)
            .range(offset..<(offset + per))
            .all()

        guard !items.isEmpty else {
            return LessonSearchResponse(
                page: page,
                per: per,
                total: total,
                hasNext: false,
                items: []
            )
        }

        let cal = Calendar.current
        var filteredItems = items

        if let wdRaw = q.weekday, !wdRaw.isEmpty {
            let wantedDays: [Int] = wdRaw
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { (1...7).contains($0) }

            if !wantedDays.isEmpty {
                filteredItems = filteredItems.filter { lesson in
                    let s = lesson.startsAt
                    let day = cal.component(.weekday, from: s)
                    return wantedDays.contains(day)
                }
            }
        }

        // Optional time-of-day filtering (e.g., ?startHour=9&endHour=12)
        if let startHour = q.startHour, let endHour = q.endHour {
            filteredItems = filteredItems.filter { lesson in
                let start = Calendar.current.component(.hour, from: lesson.startsAt)
                let end = Calendar.current.component(.hour, from: lesson.endsAt)
                return start >= startHour && end <= endHour
            }
        } else if let startHour = q.startHour {
            filteredItems = filteredItems.filter { lesson in
                let start = Calendar.current.component(.hour, from: lesson.startsAt)
                return start >= startHour
            }
        } else if let endHour = q.endHour {
            filteredItems = filteredItems.filter { lesson in
                let end = Calendar.current.component(.hour, from: lesson.endsAt)
                return end <= endHour
            }
        }

        // Preload booking counts for these lessons (active only – soft-deleted excluded by default)
        let ids: [UUID] = filteredItems.compactMap { $0.id }
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id ~~ ids)
            .all()

        var countByLesson: [UUID: Int] = [:]
        for b in bookings {
            let lid = b.$lesson.id
            countByLesson[lid, default: 0] += 1
        }

        var rows: [FilteredLessonRow] = []
        rows.reserveCapacity(filteredItems.count)

        for lesson in filteredItems {
            guard let lid = lesson.id else { continue }
            let booked = countByLesson[lid, default: 0]
            let capacity = lesson.capacity
            let available = max(0, capacity - booked)

            if q.availableOnly == true && (available <= 0 || lesson.endsAt < Date()) {
                continue
            }

            rows.append(FilteredLessonRow(
                id: lesson.id,
                title: lesson.title,
                startsAt: lesson.startsAt,
                endsAt: lesson.endsAt,
                capacity: capacity,
                booked: booked,
                available: available
            ))
        }

        // Sort: available first, then by start time ascending
        rows.sort { lhs, rhs in
            // 1) lessons with availability should come before full ones
            if lhs.available > 0 && rhs.available == 0 { return true }
            if lhs.available == 0 && rhs.available > 0 { return false }
            // 2) otherwise sort by start date
            let lDate = lhs.startsAt ?? .distantFuture
            let rDate = rhs.startsAt ?? .distantFuture
            return lDate < rDate
        }

        return LessonSearchResponse(
            page: page,
            per: per,
            total: total,
            hasNext: (offset + rows.count) < total,
            items: rows
        )
    }
}
