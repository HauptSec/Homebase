import Foundation

enum Kind: String, Codable, CaseIterable, Identifiable {
    case event, dinner, bill, task, grocery, meal
    var id: String { rawValue }
    var title: String { switch self { case .event: "Calendar"; case .dinner: "Dinners"; case .bill: "Bills"; case .task: "Tasks"; case .grocery: "Groceries"; case .meal: "Saved meals" } }
    var symbol: String { switch self { case .event: "calendar"; case .dinner: "fork.knife"; case .bill: "creditcard"; case .task: "checkmark.circle"; case .grocery: "basket"; case .meal: "book.closed" } }
}
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
    var amountCents: Int?
    var currency = "USD"
    var recurrence = "none"
    var ingredients: [String] = []
    var paidDates: [Double] = []
    var allDay = false
    var done = false
    var deleted = false
    var revision = 0
    var updatedAt: Double = 0
    var updatedBy = ""
    var when: Date? { date.map { Date(timeIntervalSince1970: $0) } }
    mutating func complete() {
        if kind == .bill { paidDates.append(Date().timeIntervalSince1970) }
        if recurrence != "none", let when {
            let component: Calendar.Component = recurrence == "weekly" ? .weekOfYear : recurrence == "monthly" ? .month : .year
            if let next = Calendar.current.date(byAdding: component, value: 1, to: when) {
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
struct SyncPage: Codable { let cursor: Int; let items: [Item]; let hasMore: Bool }
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
