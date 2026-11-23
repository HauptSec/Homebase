// Xcode 27 schemas extend Siri AI while older SDKs retain the App Shortcuts implementation.
#if compiler(>=6.3)
import AppIntents
import CoreSpotlight
import GeoToolbox
import Foundation

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum HouseholdListType: String {
    case standard
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Standard"]
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct HouseholdList {
    static let defaultQuery = HouseholdListQuery()
    let id: String
    var name: String
    var type: HouseholdListType
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(id: String, name: String) { self.id = id; self.name = name; self.type = .standard }
    static func forItem(_ item: Item) -> HouseholdList {
        switch item.kind {
        case .grocery: return HouseholdList(id: "grocery:" + item.store, name: item.store.isEmpty ? "Shopping list" : "Shopping at " + item.store)
        case .dinner: return HouseholdList(id: "dinner:", name: "Dinners")
        default: return HouseholdList(id: "task:" + (item.assignedOwner ?? ""), name: item.assignedOwner.map { $0 + " tasks" } ?? "Tasks")
        }
    }
    func apply(to item: inout Item) throws {
        let pieces = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2, pieces[0] == item.kind.rawValue else { throw AssistantError(message: "Items must stay in the same category. Use a task, dinner, or shopping list of the matching kind.") }
        if item.kind == .task {
            guard ["", "Alex", "Laura"].contains(pieces[1]) else { throw AssistantError(message: "Choose Alex, Laura, or unassigned tasks.") }
            item.assignedOwner = pieces[1].isEmpty ? nil : pieces[1]
        }
        if item.kind == .grocery { item.store = pieces[1] }
    }
}
@available(iOS 27.0, *)
struct HouseholdListQuery: EntityStringQuery {
    @MainActor func all() async throws -> [HouseholdList] {
        let store = Store.shared; try await store.prepareAssistant()
        var lists = [HouseholdList(id: "task:", name: "Tasks"), HouseholdList(id: "task:Alex", name: "Alex tasks"), HouseholdList(id: "task:Laura", name: "Laura tasks"), HouseholdList(id: "grocery:", name: "Shopping list"), HouseholdList(id: "dinner:", name: "Dinners")]
        lists += Set(store.items.filter { $0.kind == .grocery && !$0.store.isEmpty }.map(\.store)).sorted().map { HouseholdList(id: "grocery:" + $0, name: "Shopping at " + $0) }
        return lists
    }
    func entities(for identifiers: [String]) async throws -> [HouseholdList] { try await all().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [HouseholdList] { try await all().filter { $0.name.localizedCaseInsensitiveContains(string) } }
    func suggestedEntities() async throws -> [HouseholdList] { try await all() }
}

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct HouseholdReminder: IndexedEntity {
    static let defaultQuery = HouseholdReminderQuery()
    let id: UUID
    var title: String
    var note: AttributedString?
    var dueDate: DateComponents?
    var isCompleted: Bool
    var creationDate: Date?
    var completionDate: Date?
    var list: HouseholdList
    var tags: Set<String> { [] }
    var urls: [URL] { [] }
    var recurrence: Calendar.RecurrenceRule? { nil }
    var isFlagged: Bool? { nil }
    var locationTrigger: HouseholdLocationTrigger? { nil }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(list.name)") }
    init(_ item: Item) {
        id = item.id; title = item.title; note = AttributedString(item.notes)
        dueDate = item.when.map { Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: $0) }
        isCompleted = item.done; creationDate = item.createdAt.map { Date(timeIntervalSince1970: $0) }
        completionDate = item.completedAt.map { Date(timeIntervalSince1970: $0) }; list = .forItem(item)
    }
}
@available(iOS 27.0, *)
struct HouseholdReminderQuery: EntityStringQuery {
    @MainActor func all() async throws -> [HouseholdRecord] {
        let store = Store.shared; try await store.prepareAssistant()
        return store.items.filter { [.task, .grocery, .dinner].contains($0.kind) }
    }
    func entities(for identifiers: [UUID]) async throws -> [HouseholdReminder] { try await all().filter { identifiers.contains($0.id) }.map(HouseholdReminder.init) }
    func entities(matching string: String) async throws -> [HouseholdReminder] { try await all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.notes.localizedCaseInsensitiveContains(string) }.map(HouseholdReminder.init) }
    func suggestedEntities() async throws -> [HouseholdReminder] { try await all().filter { !$0.done }.prefix(100).map(HouseholdReminder.init) }
}

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct CreateHouseholdReminder {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    var title: String
    var list: HouseholdList?
    var note: AttributedString?
    var dueDate: DateComponents?
    var isFlagged: Bool?
    var images: [IntentFile]
    var tags: Set<String>
    var urls: [URL]
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: HouseholdLocationTrigger?
    var section: HouseholdSection?
    @MainActor func perform() async throws -> some ReturnsValue<HouseholdReminder> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        guard isFlagged != true, images.isEmpty, tags.isEmpty, urls.isEmpty, recurrence == nil, locationTrigger == nil, section == nil else {
            throw AssistantError(message: "Homebase supports titles, notes, lists, and dates here. Configure other reminder options in the app.")
        }
        let selected = list ?? HouseholdList(id: "task:", name: "Tasks")
        guard let kind = Kind(rawValue: String(selected.id.prefix(while: { $0 != ":" }))), [.task, .grocery, .dinner].contains(kind) else { throw AssistantError(message: "Choose a Homebase list.") }
        var item = Item(kind: kind); item.title = title; item.notes = note.map { String($0.characters) } ?? ""
        item.date = dueDate.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }?.timeIntervalSince1970
        try selected.apply(to: &item)
        let message = try await store.saveFromAssistant(item)
        return .result(value: HouseholdReminder(item), dialog: "\(message)")
    }
}
@available(iOS 27.0, *)
@AppIntent(schema: .reminders.updateReminder)
struct UpdateHouseholdReminder {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    var target: HouseholdReminder
    var title: String?
    var note: AttributedString?
    var dueDate: DateComponents?
    var isCompleted: Bool?
    var list: HouseholdList?
    var tags: Set<String>?
    var urls: [URL]?
    var recurrence: Calendar.RecurrenceRule?
    var isFlagged: Bool?
    var locationTrigger: HouseholdLocationTrigger?
    @MainActor func perform() async throws -> some ReturnsValue<HouseholdReminder> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        guard tags?.isEmpty != false, urls?.isEmpty != false, recurrence == nil, isFlagged != true, locationTrigger == nil else { throw AssistantError(message: "Those reminder options must be changed in the app.") }
        let original = try store.assistantItem(target.id)
        guard [.task, .grocery, .dinner].contains(original.kind) else { throw AssistantError(message: "Choose a task, dinner, or shopping item.") }
        var item = try AssistantData.update(original, title: title, notes: note.map { String($0.characters) }, date: dueDate.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }, completed: isCompleted, actor: UserDefaults.standard.string(forKey: "ownerName"), device: UserDefaults.standard.string(forKey: "deviceId"))
        if let list { try list.apply(to: &item) }
        let message = try await store.saveFromAssistant(item)
        return .result(value: HouseholdReminder(item), dialog: "\(message)")
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .calendar.calendar)
struct HouseholdCalendar {
    static let defaultQuery = HouseholdCalendarQuery()
    let id: String = "homebase"
    var title: String
    init() { title = "Homebase" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Homebase") }
}
@available(iOS 27.0, *)
struct HouseholdCalendarQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HouseholdCalendar] { identifiers.contains("homebase") ? [HouseholdCalendar()] : [] }
    func entities(matching string: String) async throws -> [HouseholdCalendar] { "Homebase".localizedCaseInsensitiveContains(string) ? [HouseholdCalendar()] : [] }
    func suggestedEntities() async throws -> [HouseholdCalendar] { [HouseholdCalendar()] }
}
@available(iOS 27.0, *)
@AppEntity(schema: .calendar.event)
struct HouseholdEvent: IndexedEntity {
    static let defaultQuery = HouseholdEventQuery()
    let id: UUID
    var calendar: HouseholdCalendar
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var note: AttributedString?
    var recurrence: Calendar.RecurrenceRule? { nil }
    var travelTime: Duration? { nil }
    var location: HouseholdEventLocation?
    var virtualLocation: URL? { nil }
    var status: HouseholdEventStatus? { nil }
    var alarms: [HouseholdEventAlarm]
    var organizers: [IntentPerson] { [] }
    var attendees: [HouseholdAttendee] { [] }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(startDate.formatted())") }
    init(_ item: Item) {
        id = item.id; calendar = HouseholdCalendar(); title = item.title
        startDate = item.when ?? Date(); endDate = Date(timeIntervalSince1970: item.endDate ?? item.date ?? 0)
        isAllDay = item.allDay; note = AttributedString(item.notes)
        location = item.location.map { .address($0) }
        alarms = (item.alertOffsets ?? []).map { .duration(.seconds($0)) }
    }
}
@available(iOS 27.0, *)
struct HouseholdEventQuery: EntityStringQuery {
    @MainActor func all() async throws -> [HouseholdRecord] {
        let store = Store.shared; try await store.prepareAssistant()
        return store.items.filter { $0.kind == .event }
    }
    func entities(for identifiers: [UUID]) async throws -> [HouseholdEvent] { try await all().filter { identifiers.contains($0.id) }.map(HouseholdEvent.init) }
    func entities(matching string: String) async throws -> [HouseholdEvent] { try await all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.notes.localizedCaseInsensitiveContains(string) }.map(HouseholdEvent.init) }
    func suggestedEntities() async throws -> [HouseholdEvent] { try await all().filter { ($0.endDate ?? 0) > Date().timeIntervalSince1970 }.sorted(by: HouseholdRecord.taskOrder).prefix(50).map(HouseholdEvent.init) }
}
@available(iOS 27.0, *)
@AppIntent(schema: .calendar.createEvent)
struct CreateHouseholdEvent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    var title: String
    var startDate: Date
    var endDate: Date?
    var calendar: HouseholdCalendar
    var isAllDay: Bool
    var note: AttributedString?
    var location: HouseholdEventLocation?
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [HouseholdAttendee]
    @MainActor func perform() async throws -> some ReturnsValue<HouseholdEvent> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        guard recurrence == nil, attendees.isEmpty else { throw AssistantError(message: "Create repeating events or manage attendees in the app.") }
        var item = Item(kind: .event); item.title = title; item.notes = note.map { String($0.characters) } ?? ""; item.allDay = isAllDay
        if case .address(let address) = location { item.location = address }
        let start = isAllDay ? Calendar.current.startOfDay(for: startDate) : startDate
        item.date = start.timeIntervalSince1970
        item.endDate = (endDate ?? (isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600))).timeIntervalSince1970
        let message = try await store.saveFromAssistant(item)
        return .result(value: HouseholdEvent(item), dialog: "\(message)")
    }
}
@available(iOS 27.0, *)
@AppIntent(schema: .calendar.updateEvent)
struct UpdateHouseholdEvent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    var event: HouseholdEvent
    var title: String?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var note: String?
    var location: HouseholdEventLocation?
    var calendar: HouseholdCalendar?
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [HouseholdAttendee]?
    var span: HouseholdEventSpan?
    @MainActor func perform() async throws -> some ReturnsValue<HouseholdEvent> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        guard recurrence == nil, attendees?.isEmpty != false else { throw AssistantError(message: "Change recurrence or attendees in the app.") }
        let original = try store.assistantItem(event.id)
        guard original.kind == .event, !original.isRecurringSeries, original.seriesID == nil else { throw AssistantError(message: "Choose a non-repeating event, or edit the recurring event in Homebase.") }
        var item = try AssistantData.update(original, title: title, notes: note, date: startDate, end: endDate)
        if case .address(let address) = location { item.location = address }
        if let isAllDay { item.allDay = isAllDay }
        if item.allDay {
            item.date = Calendar.current.startOfDay(for: item.when!).timeIntervalSince1970
            let end = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: item.endDate!))
            item.endDate = (end.timeIntervalSince1970 > item.date! ? end : Calendar.current.date(byAdding: .day, value: 1, to: item.when!)!).timeIntervalSince1970
        }
        let message = try await store.saveFromAssistant(item)
        return .result(value: HouseholdEvent(item), dialog: "\(message)")
    }
}

@available(iOS 27.0, *)
@UnionValue enum HouseholdEventLocation { case address(String) }
@available(iOS 27.0, *)
@UnionValue enum HouseholdEventAlarm { case duration(Duration); case date(Date) }
@available(iOS 27.0, *)
@AppEnum(schema: .calendar.eventStatus)
enum HouseholdEventStatus: String {
    case confirmed, tentative, cancelled
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.confirmed: "Confirmed", .tentative: "Tentative", .cancelled: "Cancelled"]
}
@available(iOS 27.0, *)
@AppEnum(schema: .calendar.eventSpan)
enum HouseholdEventSpan: String {
    case this, future, all
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.this: "This event", .future: "Future events", .all: "All events"]
}
@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeStatus)
enum HouseholdAttendeeStatus: String {
    case accepted, declined, tentative
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.accepted: "Accepted", .declined: "Declined", .tentative: "Tentative"]
}
@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeType)
enum HouseholdAttendeeType: String {
    case person
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.person: "Person"]
}
@available(iOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum HouseholdTriggerEvent: String {
    case arrive, depart
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Depart"]
}
// These schemas are required by Apple's contracts; Homebase doesn't expose or mutate
// attendees, location triggers, or custom sections. Unsupported inputs are rejected above.
@available(iOS 27.0, *)
@AppEntity(schema: .calendar.attendee)
struct HouseholdAttendee {
    static let defaultQuery = HouseholdAttendeeQuery()
    let id: String
    var person: IntentPerson
    var status: HouseholdAttendeeStatus?
    var isAttendanceOptional: Bool
    var type: HouseholdAttendeeType?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Attendee") }
}
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct HouseholdLocationTrigger {
    static let defaultQuery = HouseholdLocationTriggerQuery()
    let id: String
    var place: PlaceDescriptor
    var event: HouseholdTriggerEvent
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Location reminder") }
}
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct HouseholdSection {
    static let defaultQuery = HouseholdSectionQuery()
    let id: String
    var name: String
    var list: HouseholdList
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 27.0, *)
struct HouseholdAttendeeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HouseholdAttendee] { [] }
    func entities(matching string: String) async throws -> [HouseholdAttendee] { [] }
}

@available(iOS 27.0, *)
struct HouseholdLocationTriggerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HouseholdLocationTrigger] { [] }
    func entities(matching string: String) async throws -> [HouseholdLocationTrigger] { [] }
}

@available(iOS 27.0, *)
struct HouseholdSectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HouseholdSection] { [] }
    func entities(matching string: String) async throws -> [HouseholdSection] { [] }
}

#endif
