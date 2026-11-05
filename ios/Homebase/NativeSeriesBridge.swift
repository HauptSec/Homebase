import Foundation
import EventKit
import CryptoKit

struct NativeSeriesLink: Codable {
    var eventIdentifier: String
    var externalIdentifier: String
    var lastHome: String
    var lastApple: String
    var lastRoot: String? = nil
    var anchorDate: Double? = nil
}

@MainActor final class NativeSeriesBridge {
    static let shared = NativeSeriesBridge()
    private var links: [String: NativeSeriesLink] = [:]
    var resolutions: [UUID: Bool] = [:]
    init() {
        if let data = UserDefaults.standard.data(forKey: "nativeSeriesLinks"), let decoded = try? JSONDecoder().decode([String: NativeSeriesLink].self, from: data) { links = decoded }
    }
    private func external(_ event: EKEvent) -> String { event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func homeStamp(_ root: Item, store: Store) -> String {
        let children = store.cache.items.filter { $0.seriesID == root.id && $0.seriesVersion == root.seriesVersion }.sorted { $0.id.uuidString < $1.id.uuidString }
        return hash(CalendarEventFields.stamp(root) + CalendarEventFields.scheduleStamp(root) + "|\(root.deleted)|\(root.seriesVersion?.uuidString ?? "")|" + children.map { "\($0.id)|\($0.deleted)|" + CalendarEventFields.stamp($0) }.joined(separator: "\n"))
    }
    private func members(_ root: EKEvent, in all: [EKEvent]) -> [EKEvent] {
        all.filter { external($0) == external(root) || (root.url != nil && $0.url == root.url) }
    }
    private func appleStamp(_ root: EKEvent, members: [EKEvent]) -> String {
        var item = Item(kind: .event); CalendarEventFields.read(root, into: &item)
        let supported = CalendarEventFields.readRule(root, into: &item)
        return hash(CalendarEventFields.stamp(root) + CalendarEventFields.scheduleStamp(item) + "\(supported)" + members.map { "\($0.occurrenceDate?.timeIntervalSince1970 ?? $0.startDate.timeIntervalSince1970)|" + CalendarEventFields.stamp($0) }.sorted().joined(separator: "\n"))
    }
    private func rootStamp(_ root: Item) -> String {
        hash(CalendarEventFields.stamp(root) + CalendarEventFields.scheduleStamp(root) + "|\(root.deleted)|\(root.seriesVersion?.uuidString ?? "")")
    }
    private func removeSeries(_ native: EKEvent, anchorDate: Double, events: EKEventStore, calendar: EKCalendar) throws {
        if !native.hasRecurrenceRules && !native.isDetached {
            try events.remove(native, span: .thisEvent, commit: true); return
        }
        // event(withIdentifier:) can return a detached first occurrence. Find the
        // earliest non-detached anchor before applying .futureEvents; remove earlier
        // detached exceptions individually. EventKit predicates are capped at 4 years.
        let gregorian = Calendar(identifier: .gregorian)
        var lower = Date(timeIntervalSince1970: min(anchorDate, native.startDate.timeIntervalSince1970)).addingTimeInterval(-1)
        let limit = gregorian.date(byAdding: .year, value: 100, to: max(lower, Date()))!
        var detached: [EKEvent] = []
        while lower < limit {
            let upper = min(gregorian.date(byAdding: .year, value: 4, to: lower)!, limit)
            let batch = members(native, in: events.events(matching: events.predicateForEvents(withStart: lower, end: upper, calendars: [calendar])))
            detached += batch.filter { $0.isDetached }
            if let first = batch.filter({ !$0.isDetached }).min(by: { $0.startDate < $1.startDate }) {
                var seen: Set<String> = []
                for event in detached where seen.insert(event.calendarItemIdentifier + "|\(event.occurrenceDate?.timeIntervalSince1970 ?? 0)").inserted {
                    try events.remove(event, span: .thisEvent, commit: true)
                }
                if first.refresh() { try events.remove(first, span: .futureEvents, commit: true) }
                return
            }
            lower = upper
        }
        var seen: Set<String> = []
        for event in detached where seen.insert(event.calendarItemIdentifier + "|\(event.occurrenceDate?.timeIntervalSince1970 ?? 0)").inserted { try events.remove(event, span: .thisEvent, commit: true) }
    }
    private func applyExceptions(_ root: Item, native: EKEvent, all: [EKEvent], store: Store, events: EKEventStore, calendar: EKCalendar, issues: inout [CalendarIssue]) throws -> Bool {
        var complete = true
        let url = native.url
        for exception in store.cache.items where exception.seriesID == root.id && exception.seriesVersion == root.seriesVersion {
            guard let slot = exception.occurrenceDate else { continue }
            let around = events.events(matching: events.predicateForEvents(withStart: Date(timeIntervalSince1970: slot - 86400), end: Date(timeIntervalSince1970: slot + 86400), calendars: [calendar]))
            let candidates = members(native, in: around + all)
            guard let occurrence = candidates.first(where: { abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince1970 - slot) < 1 }) else {
                if !exception.deleted { complete = false; issues.append(CalendarIssue(item: exception, missing: true, nativeSeriesID: root.id)) }
                continue
            }
            if exception.deleted { if occurrence.refresh() { try events.remove(occurrence, span: .thisEvent, commit: true) } }
            else if CalendarEventFields.stamp(exception) != CalendarEventFields.stamp(occurrence) {
                CalendarEventFields.write(exception, to: occurrence); occurrence.url = url
                try events.save(occurrence, span: .thisEvent, commit: true)
            }
        }
        return complete
    }
    func run(store: Store, events: EKEventStore, calendar: EKCalendar, legacyLinks: inout [String: CalendarLink], issues: inout [CalendarIssue]) throws -> Set<String> {
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = .current
        let year = gregorian.component(.year, from: Date())
        let lower = gregorian.date(from: DateComponents(year: year - 1, month: 1, day: 1))!
        let upper = gregorian.date(from: DateComponents(year: year + 3, month: 1, day: 1))!
        func fetch() -> [EKEvent] { events.events(matching: events.predicateForEvents(withStart: lower, end: upper, calendars: [calendar])) }
        var all = fetch()
        var managed: Set<String> = []
        // Adopt simple Apple-created series once, replacing older per-occurrence imports.
        for candidate in all where candidate.hasRecurrenceRules && !candidate.isDetached && !candidate.hasAttendees && candidate.url == nil && (candidate.alarms?.count ?? 0) <= 2 {
            let source = external(candidate)
            if managed.contains(source) { continue }
            let calendarKey = "native-series:" + source
            if store.cache.items.contains(where: { $0.calendarKey == calendarKey }) { managed.insert(source); continue }
            guard let anchor = events.event(withIdentifier: candidate.eventIdentifier), !anchor.isDetached else { continue }
            var root = Item(kind: .event)
            CalendarEventFields.read(anchor, into: &root)
            guard CalendarEventFields.readRule(anchor, into: &root), root.isRecurringSeries else { continue }
            // A stable source hash prevents duplicate masters if a second bridge takes over.
            let digest = Array(SHA256.hash(data: Data(calendarKey.utf8)).prefix(16))
            root.id = UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
            root.seriesVersion = root.id; root.calendarKey = calendarKey
            store.save(root)
            for old in store.cache.items where old.id != root.id && old.kind == .event && old.seriesID == nil && (old.calendarKey == source || old.calendarKey.hasPrefix(source + "|")) {
                var retired = old; retired.deleted = true; retired.calendarKey = ""
                legacyLinks.removeValue(forKey: old.id.uuidString); store.save(retired)
            }
            links[root.id.uuidString] = NativeSeriesLink(eventIdentifier: anchor.eventIdentifier, externalIdentifier: source, lastHome: homeStamp(root, store: store), lastApple: "", lastRoot: rootStamp(root), anchorDate: root.date)
            managed.insert(source)
        }
        let roots = store.cache.items.filter { $0.kind == .event && $0.seriesID == nil && ($0.isRecurringSeries || $0.seriesVersion != nil || links[$0.id.uuidString] != nil) }
        for initial in roots {
            var root = initial
            let id = root.id.uuidString, url = URL(string: "homebase://series/\(root.id.uuidString)")!
            var link = links[id]
            var native = (link?.eventIdentifier ?? legacyLinks[id]?.eventIdentifier).flatMap { events.event(withIdentifier: $0) }
            if native == nil, let found = all.first(where: { $0.url == url || (link != nil && external($0) == link!.externalIdentifier) }) { native = events.event(withIdentifier: found.eventIdentifier) }
            if let native, native.calendar.calendarIdentifier != calendar.calendarIdentifier { continue }
            if let native { managed.insert(external(native)) }
            if let native, native.hasAttendees {
                issues.append(CalendarIssue(item: root, missing: false, nativeSeriesID: root.id, message: "This series now includes invitations. Manage it in Apple Calendar; Homebase has paused series edits to preserve the participants.", allowApple: false, allowHome: false)); continue
            }
            let home = homeStamp(root, store: store)
            let nativeMembers = native.map { members($0, in: all) } ?? []
            let apple = native.map { appleStamp($0, members: nativeMembers) } ?? ""
            let forced = resolutions.removeValue(forKey: root.id)
            if root.deleted && native == nil { links.removeValue(forKey: id); continue }
            if native == nil && link != nil && !root.deleted && forced == nil {
                issues.append(CalendarIssue(item: root, missing: true, nativeSeriesID: root.id)); continue
            }
            let homeChanged = link == nil || link!.lastHome != home
            let appleChanged = link != nil && link!.lastApple != apple
            if homeChanged && appleChanged && forced == nil {
                issues.append(CalendarIssue(item: root, missing: false, nativeSeriesID: root.id)); continue
            }
            if root.deleted {
                if let native { try removeSeries(native, anchorDate: link?.anchorDate ?? root.date ?? native.startDate.timeIntervalSince1970, events: events, calendar: calendar) }
                links.removeValue(forKey: id); continue
            }
            if homeChanged && forced == nil, let native, link?.lastRoot == rootStamp(root) {
                let complete = try applyExceptions(root, native: native, all: all, store: store, events: events, calendar: calendar, issues: &issues)
                all = fetch()
                let refreshed = events.event(withIdentifier: native.eventIdentifier) ?? native
                links[id] = NativeSeriesLink(eventIdentifier: native.eventIdentifier, externalIdentifier: external(native), lastHome: complete ? homeStamp(root, store: store) : link!.lastHome, lastApple: appleStamp(refreshed, members: members(refreshed, in: all)), lastRoot: rootStamp(root), anchorDate: root.date)
                continue
            }
            if forced == true || (homeChanged && forced != false) {
                // Rebuild from the original anchor so "entire series" includes historical
                // occurrences. Apply exceptions natively with .thisEvent afterwards.
                if let native { try removeSeries(native, anchorDate: link?.anchorDate ?? root.date ?? native.startDate.timeIntervalSince1970, events: events, calendar: calendar) }
                let created = EKEvent(eventStore: events); created.calendar = calendar; created.url = url
                CalendarEventFields.write(root, to: created)
                created.recurrenceRules = CalendarEventFields.rule(for: root).map { [$0] }
                try events.save(created, span: .thisEvent, commit: true)
                native = created
                _ = try applyExceptions(root, native: created, all: fetch(), store: store, events: events, calendar: calendar, issues: &issues)
                root.calendarKey = "native-series:" + external(created)
                if root.calendarKey != initial.calendarKey { store.save(root) }
                all = fetch()
                let anchor = events.event(withIdentifier: created.eventIdentifier) ?? created
                links[id] = NativeSeriesLink(eventIdentifier: created.eventIdentifier, externalIdentifier: external(created), lastHome: homeStamp(root, store: store), lastApple: appleStamp(anchor, members: members(anchor, in: all)), lastRoot: rootStamp(root), anchorDate: root.date)
                managed.insert(external(created)); legacyLinks.removeValue(forKey: id)
                continue
            }
            guard let native else { continue }
            if appleChanged || forced == false {
                var imported = root
                let base = native.isDetached ? nativeMembers.filter({ !$0.isDetached }).min(by: { $0.startDate < $1.startDate }) : native
                if let base {
                    let anchorException = store.cache.items.contains { $0.seriesID == root.id && $0.seriesVersion == root.seriesVersion && $0.occurrenceDate == root.date }
                    let shifted = base.startDate.timeIntervalSince1970 != root.date
                    if shifted && !anchorException && forced == nil {
                        issues.append(CalendarIssue(item: root, missing: false, nativeSeriesID: root.id, message: "Apple Calendar changed the series start or removed its first occurrence. Review which series to keep.")); continue
                    }
                    CalendarEventFields.read(base, into: &imported)
                    if shifted && anchorException {
                        imported.date = root.date
                        imported.endDate = (root.date ?? 0) + base.endDate.timeIntervalSince(base.startDate)
                    }
                }
                guard base == nil || CalendarEventFields.readRule(base!, into: &imported) else {
                    issues.append(CalendarIssue(item: root, missing: false, nativeSeriesID: root.id, message: "Apple Calendar uses a repeat rule Homebase cannot edit yet. Simplify it in Calendar, or restore the Homebase series.", allowApple: false)); continue
                }
                if CalendarEventFields.scheduleStamp(imported) != CalendarEventFields.scheduleStamp(root) { imported.seriesVersion = UUID() }
                if CalendarEventFields.stamp(imported) != CalendarEventFields.stamp(root) || CalendarEventFields.scheduleStamp(imported) != CalendarEventFields.scheduleStamp(root) { store.save(imported) }
                root = imported
                let expected = EventRecurrence.occurrences(of: root, from: lower, to: upper)
                let expectedBySlot = Dictionary(expected.map { (Int64(($0.occurrenceDate ?? 0).rounded()), $0) }, uniquingKeysWith: { first, _ in first })
                for event in nativeMembers {
                    let slot = (event.occurrenceDate ?? event.startDate).timeIntervalSince1970
                    guard var occurrence = expectedBySlot[Int64(slot.rounded())] else { continue }
                    let existing = store.cache.items.first { $0.id == occurrence.id && $0.seriesVersion == root.seriesVersion }
                    CalendarEventFields.read(event, into: &occurrence)
                    occurrence.deleted = false
                    if let existing { occurrence.revision = existing.revision }
                    if let existing {
                        if existing.deleted || CalendarEventFields.stamp(existing) != CalendarEventFields.stamp(occurrence) { store.save(occurrence) }
                    } else if event.isDetached || CalendarEventFields.stamp(occurrence) != CalendarEventFields.stamp(expectedBySlot[Int64(slot.rounded())]!) { store.save(occurrence) }
                }
            }
            // Missing individual occurrences require review: a temporary iCloud gap is
            // never silently interpreted as an intentional deletion.
            let nativeSlots = Set(nativeMembers.map { Int64(($0.occurrenceDate ?? $0.startDate).timeIntervalSince1970.rounded()) })
            let deletedSlots = Set(store.cache.items.filter { $0.seriesID == root.id && $0.seriesVersion == root.seriesVersion && $0.deleted }.compactMap { $0.occurrenceDate.map { Int64($0.rounded()) } })
            for occurrence in EventRecurrence.occurrences(of: root, from: lower, to: upper) {
                let slot = Int64((occurrence.occurrenceDate ?? 0).rounded())
                if !nativeSlots.contains(slot) && !deletedSlots.contains(slot) { issues.append(CalendarIssue(item: store.cache.items.first(where: { $0.id == occurrence.id && $0.seriesVersion == root.seriesVersion }) ?? occurrence, missing: true, nativeSeriesID: root.id)) }
            }
            link = NativeSeriesLink(eventIdentifier: native.eventIdentifier, externalIdentifier: external(native), lastHome: homeStamp(root, store: store), lastApple: apple, lastRoot: rootStamp(root), anchorDate: root.date)
            links[id] = link
        }
        UserDefaults.standard.set(try JSONEncoder().encode(links), forKey: "nativeSeriesLinks")
        return managed
    }
}
