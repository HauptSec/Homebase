import EventKit
import CryptoKit
import Foundation

/// Each list has independent connection state, links, and exclusive bridge ownership.
@MainActor final class RemindersBridge: ObservableObject {
    static let shared = RemindersBridge(kind: .task)
    static let dinners = RemindersBridge(kind: .dinner)
    let kind: Kind
    var listName: String { kind == .dinner ? "Homebase - Dinners" : "Homebase - Tasks" }
    private var selectionKey: String { kind == .dinner ? "bridgeDinnerReminders" : "bridgeReminders" }
    private var linksKey: String { kind == .dinner ? "dinnerReminderLinks" : "reminderLinks" }
    private var route: String { kind == .dinner ? "dinner-reminders" : "reminders" }
    static func runAll(store: Store) async {
        await shared.run(store: store)
        await dinners.run(store: store)
    }
    let events = EKEventStore()
    @Published var calendars: [EKCalendar] = []
    @Published var selected = ""
    @Published var status = "Not connected"
    @Published var issues: [CalendarIssue] = []
    private var busy = false
    private var links: [String: CalendarLink] = [:]
    private init(kind: Kind) {
        self.kind = kind
        selected = UserDefaults.standard.string(forKey: selectionKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: linksKey), let saved = try? JSONDecoder().decode([String: CalendarLink].self, from: data) { links = saved }
    }
    func load() async {
        do {
            guard try await events.requestFullAccessToReminders() else { status = "Reminders permission is required."; return }
            calendars = events.calendars(for: .reminder).filter { $0.allowsContentModifications && $0.source.sourceType == .calDAV && $0.title == listName }
            if calendars.isEmpty { status = "Create and share an iCloud list named \(listName) in Reminders, then try again." }
        } catch { status = error.localizedDescription }
    }
    private func claim(store: Store, release: Bool = false) async throws {
        let (_, response) = try await URLSession.shared.data(for: store.request("/v1/\(route)/\(release ? "release" : "claim")", method: "POST", body: Data("{}".utf8)))
        try store.checked(response)
    }
    func connect(_ calendar: EKCalendar, store: Store) async {
        do {
            try await claim(store: store)
            selected = calendar.calendarIdentifier
            UserDefaults.standard.set(selected, forKey: selectionKey)
            await run(store: store)
        } catch { status = "Could not connect reminders: \(error.localizedDescription)" }
    }
    func disconnect(store: Store) async {
        do {
            try await claim(store: store, release: true)
            selected = ""; issues = []
            UserDefaults.standard.removeObject(forKey: selectionKey)
            status = "Disconnected"
        } catch { status = error.localizedDescription }
    }
    private func key(_ reminder: EKReminder) -> String { reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier }
    private func marker(_ item: Item) -> URL { URL(string: "homebase://\(kind.rawValue)/\(item.id.uuidString)")! }
    private func read(_ reminder: EKReminder, into item: inout Item) { ReminderFields.read(reminder, into: &item) }
    private func write(_ item: Item, to reminder: EKReminder) { ReminderFields.write(item, to: reminder) }
    private func stamp(_ item: Item) -> String {
        // JSON avoids delimiter collisions in titles and notes.
        let fields = [item.title, item.notes, item.assignedOwner ?? "", String(item.date ?? 0), String(item.reminderAt ?? 0), String(item.done), String(item.deleted)]
        return String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
    }
    private func stamp(_ reminder: EKReminder) -> String {
        var item = Item(kind: kind); read(reminder, into: &item); return stamp(item)
    }
    private func stableID(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(((kind == .dinner ? "dinner-reminder:" : "reminder:") + value).utf8)).prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    func resolve(_ issue: CalendarIssue, useHomebase: Bool, store: Store) async {
        guard !busy, useHomebase ? issue.allowHome : issue.allowApple else { return }
        guard store.cache.items.first(where: { $0.id == issue.item.id }) == issue.item else { await run(store: store); return }
        let id = issue.item.id.uuidString
        if issue.missing {
            if useHomebase { var item = issue.item; item.reminderKey = nil; store.save(item) }
            else { store.remove(issue.item) }
            links.removeValue(forKey: id)
        } else if var link = links[id] {
            if useHomebase {
                guard let apple = events.calendarItem(withIdentifier: link.eventIdentifier) as? EKReminder else { return }
                link.lastApple = stamp(apple); link.lastHome = ""
            } else { link.lastHome = stamp(issue.item); link.lastApple = "" }
            links[id] = link
        }
        await store.sync(); await run(store: store)
    }
    func run(store: Store) async {
        guard !selected.isEmpty, !busy, store.paired, !store.demo else { return }
        busy = true; defer { busy = false }
        do {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { status = "Enable Reminders access in iOS Settings."; return }
            try await claim(store: store)
            await store.sync()
            guard !store.syncing, store.status == "Up to date", store.cache.queue.isEmpty, store.cache.conflicts.isEmpty else { status = "Waiting for Homebase edits to sync."; return }
            guard let calendar = events.calendar(withIdentifier: selected), calendar.allowsContentModifications else { status = "Shared list unavailable. Reconnect it in Settings."; return }
            let fetched: [EKReminder]? = await withCheckedContinuation { continuation in
                events.fetchReminders(matching: events.predicateForReminders(in: [calendar])) { continuation.resume(returning: $0) }
            }
            guard let reminders = fetched else { status = "Could not read reminders. Try again."; return }
            issues = []
            var consumed = Set<String>()
            var undatedCount = 0
            for item in store.cache.items where item.kind == kind {
                let id = item.id.uuidString
                let link = links[id]
                let apple = reminders.first { $0.url == marker(item) || key($0) == item.reminderKey || $0.calendarItemIdentifier == link?.eventIdentifier }
                if let apple {
                    consumed.insert(apple.calendarItemIdentifier)
                    let appleChanged = link.map { $0.lastApple != stamp(apple) } ?? false
                    let homeChanged = link.map { $0.lastHome != stamp(item) } ?? false
                    if kind == .dinner && !item.deleted && apple.dueDateComponents.flatMap({ ($0.calendar ?? Calendar.current).date(from: $0) }) == nil {
                        // A Homebase resolution explicitly requests restoring the missing date.
                        if link?.lastHome != "" {
                            // Keep a baseline even when reconnecting on a new bridge phone,
                            // so the review action can restore this undated reminder.
                            if link == nil {
                                links[id] = CalendarLink(eventIdentifier: apple.calendarItemIdentifier, lastApple: stamp(apple), lastHome: stamp(item))
                            }
                            issues.append(CalendarIssue(item: item, missing: false, message: "This dinner needs a due date in Reminders. Add one there, or restore the Homebase version.", allowApple: false))
                            continue
                        }
                    }
                    if appleChanged && homeChanged { issues.append(CalendarIssue(item: item, missing: false)); continue }
                    if item.deleted {
                        try events.remove(apple, commit: true); links.removeValue(forKey: id); continue
                    }
                    var updated = item
                    if appleChanged || link == nil {
                        read(apple, into: &updated)
                    } else if homeChanged {
                        write(item, to: apple); try events.save(apple, commit: true)
                    }
                    updated.reminderKey = key(apple)
                    if updated != item { store.save(updated, source: route) }
                    links[id] = CalendarLink(eventIdentifier: apple.calendarItemIdentifier, lastApple: stamp(apple), lastHome: stamp(updated))
                } else if !item.deleted && item.reminderKey == nil {
                    let apple = EKReminder(eventStore: events); apple.calendar = calendar; write(item, to: apple)
                    try events.save(apple, commit: true)
                    var updated = item; updated.reminderKey = key(apple); store.save(updated, source: route)
                    links[id] = CalendarLink(eventIdentifier: apple.calendarItemIdentifier, lastApple: stamp(apple), lastHome: stamp(updated))
                } else if !item.deleted {
                    issues.append(CalendarIssue(item: item, missing: true))
                }
            }
            for apple in reminders where !consumed.contains(apple.calendarItemIdentifier) {
                if apple.url?.scheme == "homebase" { continue }
                let reminderKey = key(apple)
                if store.cache.items.contains(where: { $0.reminderKey == reminderKey }) { continue }
                var item = Item(kind: kind); item.id = stableID(reminderKey)
                item.createdAt = apple.creationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                read(apple, into: &item)
                if kind == .dinner && item.date == nil { undatedCount += 1; continue }
                store.save(item, source: route)
                links[item.id.uuidString] = CalendarLink(eventIdentifier: apple.calendarItemIdentifier, lastApple: stamp(apple), lastHome: stamp(item))
            }
            UserDefaults.standard.set(try JSONEncoder().encode(links), forKey: linksKey)
            await store.sync()
            status = !store.cache.queue.isEmpty || !store.cache.conflicts.isEmpty ? "Waiting for Homebase edits to sync." : issues.isEmpty ? "\(listName) synced" : "\(issues.count) reminder changes need review."
            if undatedCount > 0 { status += " \(undatedCount) dinner reminders need a due date before import." }
        } catch { status = "Reminders sync paused: \(error.localizedDescription)" }
    }
}
