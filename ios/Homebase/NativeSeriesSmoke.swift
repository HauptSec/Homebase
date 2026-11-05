#if DEBUG
import Foundation
import EventKit

/// Explicit simulator-only smoke test. Uses a disposable local calendar and preview
/// data; never runs during normal launch or in a distribution build.
@MainActor enum NativeSeriesSmoke {
    static func run(store: Store) async {
        #if targetEnvironment(simulator)
        let output = URL.applicationSupportDirectory.appendingPathComponent("native-series-smoke.txt")
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "RUNNING\n".write(to: output, atomically: true, encoding: .utf8)
            guard store.demo else { throw APIError(message: "Smoke test requires --preview") }
            let events = EKEventStore()
            guard try await events.requestFullAccessToEvents() else { throw APIError(message: "Simulator calendar access required") }
            guard let source = events.sources.first(where: { $0.sourceType == .local }) else { throw APIError(message: "No local simulator calendar source") }
            let calendar = EKCalendar(for: .event, eventStore: events)
            calendar.title = "Homebase disposable recurrence test"; calendar.source = source
            try events.saveCalendar(calendar, commit: true)
            let savedCache = store.cache
            let savedLinks = UserDefaults.standard.data(forKey: "nativeSeriesLinks")
            defer {
                try? events.removeCalendar(calendar, commit: true)
                store.cache = savedCache
                UserDefaults.standard.set(savedLinks, forKey: "nativeSeriesLinks")
            }
            let bridge = NativeSeriesBridge()
            var legacy: [String: CalendarLink] = [:]
            var issues: [CalendarIssue] = []
            let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(7 * 86400))!
            var root = Item(kind: .event); root.title = "Initial series"
            root.date = start.timeIntervalSince1970; root.endDate = start.addingTimeInterval(3600).timeIntervalSince1970
            root.recurrence = "daily"; root.recurrenceUntil = start.addingTimeInterval(4 * 86400 + 3600).timeIntervalSince1970
            root.recurrenceTimeZone = TimeZone.current.identifier; root.seriesVersion = UUID(); root.revision = 1
            store.cache = Cache(); store.cache.items = [root]
            func sync() throws {
                issues = []
                _ = try bridge.run(store: store, events: events, calendar: calendar, legacyLinks: &legacy, issues: &issues)
                if !issues.isEmpty { throw APIError(message: "Unexpected review: \(issues.map { $0.message ?? $0.item.title })") }
                store.cache.queue = []
            }
            func nativeEvents() -> [EKEvent] { events.events(matching: events.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(14 * 86400), calendars: [calendar])).sorted { $0.startDate < $1.startDate } }
            func check(_ condition: Bool, _ message: String) throws { if !condition { throw APIError(message: message) } }
            try sync()
            try check(nativeEvents().count == 5, "Native creation should yield five occurrences")
            root = store.cache.items.first { $0.id == root.id }!
            let occurrences = EventRecurrence.occurrences(of: root, from: start, to: start.addingTimeInterval(10 * 86400))
            var first = occurrences[0]; first.date! += 7200; first.endDate! += 7200; first.title = "Single exception"
            store.cache.items.append(first); try sync()
            try check(nativeEvents().count == 5 && nativeEvents().filter { $0.title == "Single exception" }.count == 1, "Editing first occurrence must preserve other events")
            var second = occurrences[1]; second.deleted = true
            store.cache.items.append(second); try sync()
            try check(nativeEvents().count == 4, "Deleting one occurrence must preserve the rest")
            root.title = "Whole series"; store.upsert(root); try sync()
            try check(nativeEvents().count == 4 && nativeEvents().filter { $0.title == "Whole series" }.count == 3, "Whole-series edit must preserve single-occurrence exceptions")
            root = store.cache.items.first { $0.id == root.id }!
            let changed = nativeEvents().last!
            changed.notes = "Edited in Apple Calendar"
            try events.save(changed, span: .thisEvent, commit: true)
            try sync()
            try check(store.cache.items.contains { $0.seriesID == root.id && $0.notes == "Edited in Apple Calendar" }, "Apple occurrence edit must import")
            root = store.cache.items.first { $0.id == root.id }!
            root.recurrence = "weekly"; root.seriesVersion = UUID(); store.upsert(root); try sync()
            try check(nativeEvents().count == 1, "Schedule change must reset old exceptions without duplicates")
            root = store.cache.items.first { $0.id == root.id }!
            root.deleted = true; store.upsert(root); try sync()
            try check(nativeEvents().isEmpty, "Deleting series must remove all native occurrences")
            try "PASS: native creation, first occurrence edit, single deletion, entire series edit, Apple-side edit, schedule reset, entire series deletion\n".write(to: output, atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error)\n".write(to: output, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
#endif
