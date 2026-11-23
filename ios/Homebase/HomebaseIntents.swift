import AppIntents
import Foundation

// App Shortcuts work without Apple Intelligence; the free-form answer uses it when available.
enum HomebaseItemType: String, AppEnum {
    case shopping, dinner, event, task
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Item type")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.shopping: "Shopping item", .dinner: "Dinner", .event: "Calendar event", .task: "Task"]
    var kind: Kind { switch self { case .shopping: .grocery; case .dinner: .dinner; case .event: .event; case .task: .task } }
}
enum HomebaseOwner: String, AppEnum {
    case alex = "Alex", laura = "Laura", unassigned = "Unassigned"
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Owner")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.alex: "Alex", .laura: "Laura", .unassigned: "Unassigned"]
}

struct HomebaseEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Homebase item")
    static var defaultQuery = HomebaseEntityQuery()
    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Category") var category: String
    @Property(title: "Date") var date: Date?
    @Property(title: "Notes") var notes: String
    @Property(title: "Assigned owner") var owner: String
    @Property(title: "Store") var storeName: String
    @Property(title: "Completed") var completed: Bool
    var displayRepresentation: DisplayRepresentation {
        let detail = [category, owner == "Unassigned" ? "" : owner, storeName, date?.formatted(date: .abbreviated, time: .shortened) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }
    init(_ item: Item) {
        id = item.id; title = item.title; category = item.kind.title; date = item.when
        notes = item.notes; owner = item.assignedOwner ?? "Unassigned"; storeName = item.store; completed = item.done
    }
}
struct HomebaseEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [HomebaseEntity] {
        let store = Store.shared; try await store.prepareAssistant()
        return store.items.filter { identifiers.contains($0.id) && !$0.deleted }.map(HomebaseEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [HomebaseEntity] {
        let store = Store.shared; try await store.prepareAssistant()
        return try AssistantData.matches(store.items, filter: .init(text: string)).prefix(100).map(HomebaseEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [HomebaseEntity] {
        let store = Store.shared; try await store.prepareAssistant()
        return store.items.filter { !$0.done && !$0.deleted && !$0.isHoliday }.sorted(by: HouseholdRecord.taskOrder).prefix(30).map(HomebaseEntity.init)
    }
}

struct AddHomebaseItem: AppIntent {
    static var title: LocalizedStringResource = "Add Homebase item"
    static var description = IntentDescription("Add a shopping item, dinner, calendar event, or task to your shared household.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Type", default: .task) var kind: HomebaseItemType
    @Parameter(title: "Title", requestValueDialog: "What would you like to add?") var name: String
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "End time") var end: Date?
    @Parameter(title: "Notes") var notes: String?
    @Parameter(title: "Store") var storeName: String?
    @Parameter(title: "Quantity") var quantity: String?
    @Parameter(title: "Owner") var owner: HomebaseOwner?
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$name) as a \(\.$kind)") { \.$date; \.$end; \.$notes; \.$storeName; \.$quantity; \.$owner } }
    init() {}
    init(kind: HomebaseItemType) { self.kind = kind }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<HomebaseEntity> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        var scheduled = date
        if scheduled == nil && (kind == .dinner || kind == .event) { scheduled = try await $date.requestValue("When is it planned?") }
        var item = Item(kind: kind.kind); item.title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.date = scheduled?.timeIntervalSince1970; item.notes = notes ?? ""
        if kind == .event { item.endDate = end?.timeIntervalSince1970 ?? scheduled?.addingTimeInterval(3600).timeIntervalSince1970 }
        if kind == .shopping { item.store = storeName ?? UserDefaults.standard.string(forKey: "lastShoppingStore") ?? ""; item.quantity = quantity ?? "" }
        if kind == .task { item.assignedOwner = owner == .unassigned ? nil : owner?.rawValue }
        let message = try await store.saveFromAssistant(item)
        if kind == .shopping { UserDefaults.standard.set(item.store, forKey: "lastShoppingStore") }
        return .result(value: HomebaseEntity(item), dialog: "\(message) \(item.title)")
    }
}

enum HouseholdEditField: String, AppEnum {
    case title, date, endTime, notes, owner, store, quantity, completed
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Field to change")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.title: "Title", .date: "Date", .endTime: "End time", .notes: "Notes", .owner: "Owner", .store: "Store", .quantity: "Quantity", .completed: "Completion"]
}

struct UpdateHomebaseItem: AppIntent {
    static var title: LocalizedStringResource = "Update Homebase item"
    static var description = IntentDescription("Change a saved item's title, date, notes, owner, store, quantity, or completion.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item", requestValueDialog: "Which Homebase item?") var item: HomebaseEntity
    @Parameter(title: "Field to change") var field: HouseholdEditField?
    @Parameter(title: "New title") var name: String?
    @Parameter(title: "New date") var date: Date?
    @Parameter(title: "New end time") var end: Date?
    @Parameter(title: "New notes") var notes: String?
    @Parameter(title: "Owner") var owner: HomebaseOwner?
    @Parameter(title: "Store") var storeName: String?
    @Parameter(title: "Quantity") var quantity: String?
    @Parameter(title: "Completed") var completed: Bool?
    static var parameterSummary: some ParameterSummary { Summary("Update \(\.$item)") { \.$name; \.$date; \.$end; \.$notes; \.$owner; \.$storeName; \.$quantity; \.$completed } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<HomebaseEntity> & ProvidesDialog {
        var newName = name, newNotes = notes, newStore = storeName, newQuantity = quantity
        var newDate = date, newEnd = end
        var newOwner = owner
        var newCompleted = completed
        if name == nil && date == nil && end == nil && notes == nil && owner == nil && storeName == nil && quantity == nil && completed == nil {
            let choice: HouseholdEditField
            if let field { choice = field } else { choice = try await $field.requestValue("What would you like to change?") }
            switch choice {
            case .title: newName = try await $name.requestValue("What is the new title?")
            case .date: newDate = try await $date.requestValue("What is the new date?")
            case .endTime: newEnd = try await $end.requestValue("When should the event end?")
            case .notes: newNotes = try await $notes.requestValue("What should the notes say?")
            case .owner: newOwner = try await $owner.requestValue("Who should own this task?")
            case .store: newStore = try await $storeName.requestValue("Which store?")
            case .quantity: newQuantity = try await $quantity.requestValue("What quantity?")
            case .completed: newCompleted = try await $completed.requestValue("Should this item be marked complete?")
            }
        }
        let store = Store.shared; try await store.prepareAssistant()
        let original = try store.assistantItem(item.id)
        guard !original.isRecurringSeries && original.seriesID == nil else { throw AssistantError(message: "Open Homebase to choose how to edit this recurring event.") }
        let changed = try AssistantData.update(original, title: newName, notes: newNotes, date: newDate, end: newEnd,
            owner: newOwner?.rawValue, store: newStore, quantity: newQuantity, completed: newCompleted,
            actor: UserDefaults.standard.string(forKey: "ownerName"), device: UserDefaults.standard.string(forKey: "deviceId"))
        let message = try await store.saveFromAssistant(changed)
        return .result(value: HomebaseEntity(changed), dialog: "\(message) \(changed.title)")
    }
}

struct AskHomebase: AppIntent {
    static var title: LocalizedStringResource = "Ask Homebase"
    static var description = IntentDescription("Ask any question about your saved household plans, tasks, groceries, meals, and budget using Apple Intelligence.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Question", requestValueDialog: "What would you like to know about your household?") var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask Homebase \(\.$question)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await HomebaseQuestions.answer(question)
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct HomebaseDayPlan: AppIntent {
    static var title: LocalizedStringResource = "Homebase day plan"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Day") var day: Date?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = Store.shared; try await store.prepareAssistant()
        let selected = day ?? Date()
        let items = store.items.filter { $0.appearsOnHome(on: selected, isToday: Calendar.current.isDateInToday(selected)) }.sorted(by: HouseholdRecord.taskOrder)
        let summary = items.isEmpty ? "Nothing is planned in Homebase for that day." : items.map { "\($0.kind.title): \($0.title)" }.joined(separator: ". ")
        let answer = (store.status == "Up to date" ? "" : "Based on this phone's saved data; sync is pending. ") + summary
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct HomebaseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskHomebase(), phrases: ["Ask \(.applicationName)"], shortTitle: "Ask Homebase", systemImageName: "sparkles")
        AppShortcut(intent: AddHomebaseItem(kind: .shopping), phrases: ["Add to my shopping list in \(.applicationName)"], shortTitle: "Add shopping item", systemImageName: "basket")
        AppShortcut(intent: AddHomebaseItem(kind: .dinner), phrases: ["Plan dinner in \(.applicationName)"], shortTitle: "Plan dinner", systemImageName: "fork.knife")
        AppShortcut(intent: AddHomebaseItem(kind: .event), phrases: ["Add a calendar event in \(.applicationName)"], shortTitle: "Add event", systemImageName: "calendar")
        AppShortcut(intent: AddHomebaseItem(kind: .task), phrases: ["Add a task in \(.applicationName)"], shortTitle: "Add task", systemImageName: "checkmark.circle")
        AppShortcut(intent: UpdateHomebaseItem(), phrases: ["Update an item in \(.applicationName)"], shortTitle: "Update item", systemImageName: "pencil")
        AppShortcut(intent: HomebaseDayPlan(), phrases: ["What's planned today in \(.applicationName)"], shortTitle: "Day plan", systemImageName: "sun.max")
    }
}
