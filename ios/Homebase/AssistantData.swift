import Foundation

typealias HouseholdRecord = Item

struct AssistantError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Shared validation and read-only retrieval used by Siri and the on-device assistant.
enum AssistantData {
    static func validate(_ item: Item) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.title.count <= 300,
              item.notes.count <= 10000, item.store.count <= 100, item.quantity.count <= 100, (item.location?.count ?? 0) <= 1000 else {
            throw AssistantError(message: "Use a title of 1–300 characters and shorter notes, store, or quantity.")
        }
        guard [.task, .grocery, .dinner, .event].contains(item.kind), !item.deleted else {
            throw AssistantError(message: "This item must be edited in Homebase.")
        }
        guard [item.date, item.endDate, item.reminderAt].compactMap({ $0 }).allSatisfy(\.isFinite),
              item.assignedOwner.map({ ["Alex", "Laura"].contains($0) }) ?? true else { throw AssistantError(message: "Use a valid date and an owner of Alex, Laura, or Unassigned.") }
        if item.kind == .dinner || item.kind == .event {
            guard let date = item.date, date.isFinite else { throw AssistantError(message: "Please include a date.") }
        }
        if item.kind == .event {
            guard let end = item.endDate, end.isFinite, end > (item.date ?? 0) else { throw AssistantError(message: "The event must end after it starts.") }
        }
    }

    static func update(_ original: Item, title: String? = nil, notes: String? = nil, date: Date? = nil,
                       end: Date? = nil, owner: String? = nil, store: String? = nil, quantity: String? = nil,
                       completed: Bool? = nil, actor: String? = nil, device: String? = nil) throws -> Item {
        var item = original
        if let title { item.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let notes { item.notes = notes }
        if let date {
            if let previous = item.date {
                let delta = date.timeIntervalSince1970 - previous
                if let alert = item.reminderAt { item.reminderAt = alert + delta }
                if item.kind == .event, end == nil, let previousEnd = item.endDate { item.endDate = previousEnd + delta }
            }
            item.date = date.timeIntervalSince1970
        }
        if let end { guard item.kind == .event else { throw AssistantError(message: "Only calendar events have an end time.") }; item.endDate = end.timeIntervalSince1970 }
        if let owner {
            guard item.kind == .task, ["Alex", "Laura", "Unassigned"].contains(owner) else { throw AssistantError(message: "Assign tasks to Alex, Laura, or Unassigned.") }
            item.assignedOwner = owner == "Unassigned" ? nil : owner
        }
        if let store { guard item.kind == .grocery else { throw AssistantError(message: "Stores apply to shopping items.") }; item.store = store.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let quantity { guard item.kind == .grocery else { throw AssistantError(message: "Quantities apply to shopping items.") }; item.quantity = quantity }
        if let completed, completed != item.done {
            if item.kind == .task || item.kind == .grocery {
                if item.kind == .task && completed && !["Alex", "Laura"].contains(actor ?? "") { throw AssistantError(message: "Assign this phone to Alex or Laura in Homebase before completing tasks.") }
                item.complete(owner: actor, deviceID: device)
            } else if item.kind == .dinner { item.done = completed }
            else { throw AssistantError(message: "Calendar events cannot be checked off.") }
        }
        try validate(item)
        return item
    }

    struct Filter: Codable {
        var kind: String = "all"
        var text: String = ""
        var owner: String = ""
        var store: String = ""
        var startDay: String = ""
        var endDay: String = ""
        var completion: String = "all"
        var dateField: String = "scheduled"
        var offset: Int = 0
    }
    static func day(_ string: String, calendar: Calendar) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: string)
    }
    static func matches(_ items: [Item], filter: Filter, calendar: Calendar = .current) throws -> [Item] {
        guard filter.kind == "all" || Kind(rawValue: filter.kind) != nil,
              ["all", "active", "completed"].contains(filter.completion), ["scheduled", "completed"].contains(filter.dateField) else { throw AssistantError(message: "Invalid search category or completion filter.") }
        let start = filter.startDay.isEmpty ? nil : day(filter.startDay, calendar: calendar)
        let last = filter.endDay.isEmpty ? nil : day(filter.endDay, calendar: calendar)
        guard (filter.startDay.isEmpty || start != nil), (filter.endDay.isEmpty || last != nil) else { throw AssistantError(message: "Dates must use YYYY-MM-DD.") }
        let end = last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        return items.filter { item in
            guard !item.deleted, filter.kind == "all" || item.kind.rawValue == filter.kind else { return false }
            if filter.completion == "active" && item.done || filter.completion == "completed" && !item.done { return false }
            if !filter.owner.isEmpty && (item.kind != .task || (item.assignedOwner ?? "Unassigned").localizedCaseInsensitiveCompare(filter.owner) != .orderedSame) { return false }
            if !filter.store.isEmpty && (item.kind != .grocery || (item.store.isEmpty ? "General" : item.store).localizedCaseInsensitiveCompare(filter.store) != .orderedSame) { return false }
            let queryDate = filter.dateField == "completed" ? item.completedAt.map { Date(timeIntervalSince1970: $0) } : item.when
            if let start { guard let when = queryDate, (item.kind == .event && filter.dateField == "scheduled" ? (item.endDate ?? when.timeIntervalSince1970) > start.timeIntervalSince1970 : when >= start) else { return false } }
            if let end { guard let when = queryDate, when < end else { return false } }
            let searchable = [item.title, item.notes, item.store, item.assignedOwner ?? "", item.location ?? ""] + item.ingredients + (item.prepSteps ?? []) + (item.cookingSteps ?? [])
            return filter.text.isEmpty || searchable.joined(separator: "\n").localizedCaseInsensitiveContains(filter.text)
        }.sorted {
            if $0.date != $1.date { return ($0.date ?? .greatestFiniteMagnitude) < ($1.date ?? .greatestFiniteMagnitude) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func result(_ items: [Item], filter: Filter, calendar: Calendar = .current) throws -> String {
        let matches = try matches(items, filter: filter, calendar: calendar)
        let offset = max(0, filter.offset), limit = 6
        var records: [[String: Any]] = matches.dropFirst(offset).prefix(limit).map { item in
            var record: [String: Any] = ["id": item.id.uuidString, "kind": item.kind.rawValue, "title": item.title,
                "notes": String(item.notes.prefix(500)), "notesTruncated": item.notes.count > 500,
                "owner": item.assignedOwner ?? "Unassigned", "store": item.store.isEmpty ? "General" : item.store,
                "quantity": item.quantity, "completed": item.done, "ingredients": item.ingredients.prefix(20).map { String($0.prefix(120)) },
                "prep": (item.prepSteps ?? []).prefix(10).map { String($0.prefix(120)) }, "cooking": (item.cookingSteps ?? []).prefix(10).map { String($0.prefix(120)) },
                "recipeMayBeTruncated": item.ingredients.count > 20 || (item.prepSteps ?? []).count > 10 || (item.cookingSteps ?? []).count > 10 || (item.ingredients + (item.prepSteps ?? []) + (item.cookingSteps ?? [])).contains { $0.count > 120 }, "recurrence": item.recurrence]
            if let when = item.when { record["date"] = when.formatted(.iso8601.timeZone(separator: .colon)) }
            if let completedAt = item.completedAt { record["completedAt"] = Date(timeIntervalSince1970: completedAt).formatted(.iso8601.timeZone(separator: .colon)) }
            if let completedBy = item.completedBy { record["completedBy"] = completedBy }
            if let end = item.endDate { record["end"] = Date(timeIntervalSince1970: end).formatted(.iso8601.timeZone(separator: .colon)) }
            if let amount = item.amountCents { record["amountCents"] = amount; record["currency"] = item.currency; record["budgetType"] = item.budgetType?.rawValue ?? "expense" }
            return record
        }
        while records.count > 1 {
            guard try JSONSerialization.data(withJSONObject: records).count > 9000 else { break }
            records.removeLast()
        }
        var totals: [String: Int] = [:]
        for item in matches where item.kind == .bill {
            if let amount = item.amountCents { totals[item.currency + " " + (item.budgetType?.rawValue ?? "expense"), default: 0] += amount }
        }
        let result: [String: Any] = ["budgetTotalsInCents": totals, "totalMatches": matches.count, "offset": offset, "hasMore": offset + records.count < matches.count, "records": records]
        return String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!
    }
}
