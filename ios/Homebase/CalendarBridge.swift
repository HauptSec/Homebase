import EventKit
import CryptoKit
import Foundation

struct CalendarLink: Codable {
    var eventIdentifier: String
    var lastApple: String
    var lastHome: String
}
struct CalendarIssue: Identifiable {
    var id: UUID { item.id }
    let item: Item
    let missing: Bool
}
@MainActor final class CalendarBridge: ObservableObject {
    static let shared = CalendarBridge()
    let events = EKEventStore()
    @Published var calendars: [EKCalendar] = []
    @Published var selected = UserDefaults.standard.string(forKey: "bridgeCalendar") ?? ""
    @Published var status = "Not connected"
    @Published var issues: [CalendarIssue] = []
    private var busy = false
    private var links: [String: CalendarLink] = [:]
    init() {
        if let data = UserDefaults.standard.data(forKey: "calendarLinks"), let saved = try? JSONDecoder().decode([String: CalendarLink].self, from: data) { links = saved }
    }
    func load() async {
        do {
            guard try await events.requestFullAccessToEvents() else { status = "Calendar permission is required."; return }
            calendars = events.calendars(for: .event).filter { $0.allowsContentModifications && $0.source.sourceType == .calDAV }
        } catch { status = error.localizedDescription }
    }
    func connect(_ calendar: EKCalendar, store: Store) async {
        do {
            let (_, response) = try await URLSession.shared.data(for: store.request("/v1/calendar/claim", method: "POST", body: Data("{}".utf8)))
            try store.checked(response)
            selected = calendar.calendarIdentifier
            UserDefaults.standard.set(selected, forKey: "bridgeCalendar")
            await run(store: store)
        } catch { status = "Could not claim calendar bridge: \(error.localizedDescription)" }
    }
    func disconnect(store: Store) async {
        do {
            let (_, response) = try await URLSession.shared.data(for: store.request("/v1/calendar/release", method: "POST", body: Data("{}".utf8)))
            try store.checked(response)
            selected = ""; UserDefaults.standard.removeObject(forKey: "bridgeCalendar"); status = "Disconnected"
        } catch { status = error.localizedDescription }
    }
    func resolve(_ issue: CalendarIssue, useHomebase: Bool, store: Store) async {
        let id = issue.item.id.uuidString
        if issue.missing {
            if useHomebase { var item = issue.item; item.calendarKey = ""; store.save(item); links.removeValue(forKey: id) }
            else { store.remove(issue.item); links.removeValue(forKey: id) }
        } else if var link = links[id] {
            if useHomebase { link.lastHome = ""; if let event = events.event(withIdentifier: link.eventIdentifier) { link.lastApple = stamp(event) } }
            else { link.lastApple = ""; link.lastHome = stamp(issue.item) }
            links[id] = link
        }
        await store.sync()
        await run(store: store)
    }
    private func stamp(_ event: EKEvent) -> String {
        "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.notes ?? "")|\(event.isAllDay)"
    }
    private func stamp(_ item: Item) -> String { "\(item.title)|\(item.date ?? 0)|\(item.endDate ?? 0)|\(item.notes)|\(item.deleted)|\(item.allDay)" }
    private func key(_ event: EKEvent) -> String {
        let root = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        return event.hasRecurrenceRules || event.isDetached ? "\(root)|\(event.occurrenceDate?.timeIntervalSince1970 ?? event.startDate.timeIntervalSince1970)" : root
    }
    private func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    func run(store: Store) async {
        guard !selected.isEmpty, !busy, store.paired else { return }
        busy = true; defer { busy = false }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { status = "Enable Calendar access in iOS Settings."; return }
            // Confirm exclusive ownership before any Apple writes.
            let (_, response) = try await URLSession.shared.data(for: store.request("/v1/calendar/claim", method: "POST", body: Data("{}".utf8)))
            try store.checked(response)
            await store.sync()
            guard store.cache.queue.isEmpty, store.cache.conflicts.isEmpty else { status = "Waiting for Homebase edits to sync."; return }
            guard let calendar = events.calendar(withIdentifier: selected), calendar.allowsContentModifications else { status = "Shared calendar unavailable. Select it again."; return }
            let start = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let end = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
            let appleEvents = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
            var byKey = Dictionary(appleEvents.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
            var reviewCount = 0
            issues = []
            for item in store.cache.items where item.kind == .event {
                let id = item.id.uuidString
                let link = links[id]
                var apple = byKey[item.calendarKey]
                if apple == nil, let link { apple = events.event(withIdentifier: link.eventIdentifier) }
                if let apple, apple.calendar.calendarIdentifier != selected { continue }
                if let apple {
                    byKey.removeValue(forKey: key(apple))
                    let appleChanged = link.map { $0.lastApple != stamp(apple) } ?? false
                    let homeChanged = link.map { $0.lastHome != stamp(item) } ?? false
                    if appleChanged && homeChanged { reviewCount += 1; issues.append(CalendarIssue(item: item, missing: false)); continue }
                    if item.deleted {
                        try events.remove(apple, span: .thisEvent, commit: true)
                        links.removeValue(forKey: id)
                        continue
                    }
                    if appleChanged || link == nil {
                        var imported = item
                        imported.title = apple.title ?? "Untitled event"; imported.date = apple.startDate.timeIntervalSince1970
                        imported.allDay = apple.isAllDay; imported.endDate = apple.endDate.timeIntervalSince1970; imported.notes = apple.notes ?? ""; imported.calendarKey = key(apple)
                        if stamp(imported) != stamp(item) || item.calendarKey != imported.calendarKey { store.save(imported) }
                        links[id] = CalendarLink(eventIdentifier: apple.eventIdentifier, lastApple: stamp(apple), lastHome: stamp(imported))
                    } else if homeChanged {
                        apple.isAllDay = item.allDay; apple.title = item.title; apple.startDate = item.when; apple.endDate = Date(timeIntervalSince1970: item.endDate ?? (item.date ?? 0) + 3600); apple.notes = item.notes
                        try events.save(apple, span: .thisEvent, commit: true)
                        links[id] = CalendarLink(eventIdentifier: apple.eventIdentifier, lastApple: stamp(apple), lastHome: stamp(item))
                    }
                } else if !item.deleted && item.calendarKey.isEmpty {
                    guard let when = item.when else { continue }
                    let created = EKEvent(eventStore: events)
                    created.isAllDay = item.allDay; created.calendar = calendar; created.title = item.title; created.startDate = when
                    created.endDate = Date(timeIntervalSince1970: item.endDate ?? when.timeIntervalSince1970 + 3600); created.notes = item.notes
                    // Persist the Homebase ID on the Apple event for crash-recovery matching.
                    created.url = URL(string: "homebase://event/\(id)")
                    if let existing = appleEvents.first(where: { $0.url == created.url }) {
                        var updated = item; updated.calendarKey = key(existing); store.save(updated)
                        links[id] = CalendarLink(eventIdentifier: existing.eventIdentifier, lastApple: stamp(existing), lastHome: stamp(updated))
                    } else {
                        try events.save(created, span: .thisEvent, commit: true)
                        var updated = item; updated.calendarKey = key(created); store.save(updated)
                        links[id] = CalendarLink(eventIdentifier: created.eventIdentifier, lastApple: stamp(created), lastHome: stamp(updated))
                    }
                } else if !item.deleted, link != nil, let when = item.when, when >= start, when < end {
                    // EventKit can temporarily omit iCloud events; never turn an uncertain absence into a destructive delete.
                    reviewCount += 1
                    issues.append(CalendarIssue(item: item, missing: true))
                }
            }
            for (calendarKey, event) in byKey {
                if let url = event.url, url.scheme == "homebase" { continue }
                if store.cache.items.contains(where: { $0.calendarKey == calendarKey }) { continue }
                var item = Item(kind: .event)
                item.id = stableID(calendarKey); item.calendarKey = calendarKey; item.title = event.title ?? "Untitled event"
                item.allDay = event.isAllDay; item.date = event.startDate.timeIntervalSince1970; item.endDate = event.endDate.timeIntervalSince1970; item.notes = event.notes ?? ""
                store.save(item)
                links[item.id.uuidString] = CalendarLink(eventIdentifier: event.eventIdentifier, lastApple: stamp(event), lastHome: stamp(item))
            }
            UserDefaults.standard.set(try JSONEncoder().encode(links), forKey: "calendarLinks")
            await store.sync()
            status = reviewCount == 0 ? "Shared calendar synced" : "\(reviewCount) calendar changes need review. Check Calendar before editing in Homebase."
        } catch { status = "Calendar sync paused: \(error.localizedDescription)" }
    }
}
