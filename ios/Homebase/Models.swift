import Foundation

enum Kind: String, Codable, CaseIterable, Identifiable {
    case event, dinner, bill, task, grocery, meal
    var id: String { rawValue }
    var title: String { switch self { case .event: "Calendar"; case .dinner: "Dinners"; case .bill: "Budget"; case .task: "Tasks"; case .grocery: "Groceries"; case .meal: "Saved meals" } }
    var symbol: String { switch self { case .event: "calendar"; case .dinner: "fork.knife"; case .bill: "creditcard"; case .task: "checkmark.circle"; case .grocery: "basket"; case .meal: "book.closed" } }
}
enum BudgetType: String, Codable { case expense, income }

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: Kind
    var title = ""
    var notes = ""
    var date: Double?
    var endDate: Double?
    var reminderAt: Double?
    var store = ""
    var calendarKey = ""
    var quantity = ""
    var budgetType: BudgetType?
    var amountCents: Int?
    var currency = "USD"
    var recurrence = "none"
    var customFrequency: String?
    var customInterval: Int?
    var repeatWeekdays: [Int]?
    var location: String?
    var latitude: Double?
    var longitude: Double?
    var alertOffsets: [Int]?
    var recurrenceUntil: Double?
    var recurrenceTimeZone: String?
    var seriesID: UUID?
    var occurrenceDate: Double?
    var seriesVersion: UUID?
    var ingredients: [String] = []
    var prepSteps: [String]?
    var cookingSteps: [String]?
    var paidDates: [Double] = []
    var allDay = false
    var done = false
    var completedAt: Double?
    var completedBy: String?
    var completedByDevice: String?
    var deleted = false
    var revision = 0
    var updatedAt: Double = 0
    var updatedBy = ""
    enum CodingKeys: String, CodingKey {
        case id, kind, title, notes, date, endDate, reminderAt, store, calendarKey, quantity, budgetType, amountCents, currency, recurrence, customFrequency, customInterval, repeatWeekdays, location, latitude, longitude, alertOffsets, recurrenceUntil, recurrenceTimeZone, seriesID, occurrenceDate, seriesVersion, ingredients, prepSteps, cookingSteps, paidDates, allDay, done, completedAt, completedBy, completedByDevice, deleted, revision, updatedAt, updatedBy
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(notes, forKey: .notes)
        try container.encode(date, forKey: .date)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(reminderAt, forKey: .reminderAt)
        try container.encode(store, forKey: .store)
        try container.encode(calendarKey, forKey: .calendarKey)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(budgetType, forKey: .budgetType)
        try container.encode(amountCents, forKey: .amountCents)
        try container.encode(currency, forKey: .currency)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(customFrequency, forKey: .customFrequency)
        try container.encode(customInterval, forKey: .customInterval)
        try container.encode(repeatWeekdays, forKey: .repeatWeekdays)
        try container.encode(location, forKey: .location)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(alertOffsets, forKey: .alertOffsets)
        try container.encode(recurrenceUntil, forKey: .recurrenceUntil)
        try container.encode(recurrenceTimeZone, forKey: .recurrenceTimeZone)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encode(occurrenceDate, forKey: .occurrenceDate)
        try container.encode(seriesVersion, forKey: .seriesVersion)
        try container.encode(ingredients, forKey: .ingredients)
        try container.encode(prepSteps, forKey: .prepSteps)
        try container.encode(cookingSteps, forKey: .cookingSteps)
        try container.encode(paidDates, forKey: .paidDates)
        try container.encode(allDay, forKey: .allDay)
        try container.encode(done, forKey: .done)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(completedBy, forKey: .completedBy)
        try container.encode(completedByDevice, forKey: .completedByDevice)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(revision, forKey: .revision)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
    }
    var when: Date? { date.map { Date(timeIntervalSince1970: $0) } }
    static func homeDraft(kind: Kind, viewing day: Date, now: Date = Date(), calendar: Calendar = .current) -> Item {
        var item = Item(kind: kind)
        if kind == .event {
            let targetDay = calendar.startOfDay(for: day)
            if targetDay > calendar.startOfDay(for: now) {
                let time = calendar.dateComponents([.hour, .minute, .second], from: now)
                item.date = calendar.date(bySettingHour: time.hour!, minute: time.minute!, second: time.second!, of: targetDay)!.timeIntervalSince1970
            } else {
                item.date = now.timeIntervalSince1970
            }
        }
        return item
    }
    func appearsOnHome(on day: Date, isToday: Bool, calendar: Calendar = .current) -> Bool {
        guard kind != .meal, kind != .grocery, let when else { return false }
        if isToday && done { return false }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if kind == .event {
            let eventEnd = endDate ?? when.timeIntervalSince1970
            return when < end && (eventEnd > start.timeIntervalSince1970 || (eventEnd == when.timeIntervalSince1970 && when >= start))
        }
        // Dinner plans end with their calendar day; only bills and tasks carry forward.
        return calendar.isDate(when, inSameDayAs: start)
            || (isToday && (kind == .bill || kind == .task) && when < start)
    }
    var isIncome: Bool { kind == .bill && budgetType == .income }
    var completionLabel: String { done ? "Reopen" : isIncome ? "Received" : "Paid" }
    var recurrenceLabel: String {
        switch recurrence { case "daily": "Daily"; case "weekly": "Weekly"; case "biweekly": "Every 2 weeks"; case "monthly": "Monthly"; case "yearly": "Yearly"; case "custom": "Custom"; default: "One-time" }
    }
    func visibleOnGroceryList(on day: Date, calendar: Calendar = .current) -> Bool {
        guard done else { return true }
        guard let completedAt else { return false }
        return calendar.isDate(Date(timeIntervalSince1970: completedAt), inSameDayAs: day)
    }
    mutating func complete(now: Date = Date(), owner: String? = nil, deviceID: String? = nil) {
        if kind == .grocery {
            done.toggle()
            completedAt = done ? now.timeIntervalSince1970 : nil
            return
        }
        if kind == .task {
            done.toggle()
            completedAt = done ? now.timeIntervalSince1970 : nil
            completedBy = done ? owner : nil
            completedByDevice = done ? deviceID : nil
            return
        }
        if kind == .bill && !done { paidDates.append(Date().timeIntervalSince1970) }
        if recurrence != "none", let when {
            let component: Calendar.Component = ["weekly", "biweekly"].contains(recurrence) ? .weekOfYear : recurrence == "monthly" ? .month : .year
            if let next = Calendar.current.date(byAdding: component, value: recurrence == "biweekly" ? 2 : 1, to: when) {
                if let reminderAt { self.reminderAt = reminderAt + next.timeIntervalSince(when) }
                date = next.timeIntervalSince1970
                done = false
            }
        } else { done.toggle() }
    }
}
struct Mutation: Codable, Identifiable {
    var mutationId = UUID()
    var baseRevision: Int
    var item: Item
    var id: UUID { mutationId }
}
struct SyncPage: Codable { let cursor: Int; let items: [Item]; let hasMore: Bool; let ownerName: String? }
struct MutationResult: Codable { let item: Item }
struct PairResult: Codable { let token: String; let deviceId: String }
struct ConflictEnvelope: Codable { let detail: ConflictDetail }
struct ConflictDetail: Codable { let current: Item? }
struct Conflict: Codable, Identifiable {
    var id: UUID { local.id }
    let local: Item
    let remote: Item
}
struct Cache: Codable {
    var items: [Item] = []
    var queue: [Mutation] = []
    var conflicts: [Conflict] = []
    var cursor = 0
}

struct AppRelease: Codable {
    let build: Int
    let version: String
    let notes: String
    let expiresAt: Double
}
struct ReleaseEnvelope: Codable { let release: AppRelease? }
struct InstallLink: Codable { let url: String; let expiresAt: Double }
