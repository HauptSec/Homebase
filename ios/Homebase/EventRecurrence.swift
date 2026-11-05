import Foundation
import CryptoKit

/// Offline expansion of simple Gregorian series. Monthly/yearly invalid dates are
/// skipped (Jan 31 never drifts to Feb 28), matching native calendar recurrence.
enum EventRecurrence {
    static let frequencies = ["daily", "weekly", "biweekly", "monthly", "yearly", "custom"]
    static func calendar(for item: Item) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = item.recurrenceTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return calendar
    }
    static func identifier(series: UUID, date: Double) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(series.uuidString.lowercased()):\(Int64(date.rounded()))".utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func occurrences(of root: Item, from lower: Date, to upper: Date) -> [Item] {
        guard root.isRecurringSeries, let start = root.when, let end = root.endDate, upper > lower else { return [] }
        let calendar = calendar(for: root)
        let frequency = root.recurrence == "custom" ? (root.customFrequency ?? "weekly") : root.recurrence
        let weekDays = frequency == "weekly" ? (root.repeatWeekdays ?? []) : []
        let component: Calendar.Component = !weekDays.isEmpty || frequency == "daily" ? .day : ["weekly", "biweekly"].contains(frequency) ? .weekOfYear : frequency == "monthly" ? .month : .year
        let interval = root.recurrence == "custom" ? max(1, root.customInterval ?? 1) : root.recurrence == "biweekly" ? 2 : 1
        let step = weekDays.isEmpty ? interval : 1
        let duration = end - start.timeIntervalSince1970
        let days = max(1, calendar.dateComponents([.day], from: start, to: Date(timeIntervalSince1970: end)).day ?? 1)
        let anchor = calendar.dateComponents([.month, .day], from: start)
        let distance = calendar.dateComponents([component], from: start, to: lower.addingTimeInterval(-duration)).value(for: component) ?? 0
        var index = max(0, distance / step - 1)
        var result: [Item] = []
        while let next = calendar.date(byAdding: component, value: index * step, to: start), next < upper {
            index += 1
            if let until = root.recurrenceUntil, next.timeIntervalSince1970 > until { break }
            if !weekDays.isEmpty && next != start {
                var weeks = calendar; weeks.firstWeekday = 2
                let firstWeek = weeks.dateInterval(of: .weekOfYear, for: start)!.start
                let nextWeek = weeks.dateInterval(of: .weekOfYear, for: next)!.start
                let weekIndex = (weeks.dateComponents([.day], from: firstWeek, to: nextWeek).day ?? 0) / 7
                if weekIndex % interval != 0 || !weekDays.contains(calendar.component(.weekday, from: next)) { continue }
            }
            if frequency == "monthly" && calendar.component(.day, from: next) != anchor.day { continue }
            if frequency == "yearly" && (calendar.component(.month, from: next) != anchor.month || calendar.component(.day, from: next) != anchor.day) { continue }
            let finish = root.allDay ? calendar.date(byAdding: .day, value: days, to: next)! : next.addingTimeInterval(duration)
            guard finish > lower else { continue }
            var occurrence = root
            occurrence.id = identifier(series: root.id, date: next.timeIntervalSince1970)
            occurrence.seriesID = root.id; occurrence.occurrenceDate = next.timeIntervalSince1970
            occurrence.recurrence = "none"; occurrence.recurrenceUntil = nil
            occurrence.date = next.timeIntervalSince1970; occurrence.endDate = finish.timeIntervalSince1970
            occurrence.revision = 0; occurrence.calendarKey = ""
            result.append(occurrence)
        }
        return result
    }
    static func visibleItems(_ items: [Item], now: Date = Date()) -> [Item] {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let lower = calendar.date(from: DateComponents(year: year - 1, month: 1, day: 1))!
        let upper = calendar.date(from: DateComponents(year: year + 3, month: 1, day: 1))!
        let roots = items.filter { !$0.deleted && $0.isRecurringSeries }
        var result = items.filter { !$0.deleted && !$0.isRecurringSeries && $0.seriesID == nil }
        for root in roots {
            let exceptions = items.filter { $0.seriesID == root.id && $0.seriesVersion == root.seriesVersion }
            let byID = Dictionary(exceptions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var generated = occurrences(of: root, from: lower, to: upper)
            // Retain an editable anchor for a series wholly outside the rolling window.
            if generated.isEmpty, let start = root.when { generated = occurrences(of: root, from: start, to: start.addingTimeInterval(1)) }
            for occurrence in generated where byID[occurrence.id] == nil { result.append(occurrence) }
            // Include moved occurrences even when the original slot is outside the display window.
            result += exceptions.filter { !$0.deleted && ($0.date ?? 0) < upper.timeIntervalSince1970 && ($0.endDate ?? 0) > lower.timeIntervalSince1970 }
        }
        return result
    }
}
extension Item {
    var isRecurringSeries: Bool { kind == .event && seriesID == nil && EventRecurrence.frequencies.contains(recurrence) }
}

struct PlannedEventAlert {
    let id: String
    let date: Date
    let title: String
}
enum EventAlertPlan {
    static func make(items: [Item], now: Date = Date(), usesAppleCalendar: Bool = false) -> [PlannedEventAlert] {
        var result: [PlannedEventAlert] = []
        let originals = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for item in EventRecurrence.visibleItems(items, now: now) where item.kind == .event && !item.done {
            let source = item.seriesID.flatMap { originals[$0] } ?? item
            if usesAppleCalendar && !source.calendarKey.isEmpty { continue }
            guard let start = item.when else { continue }
            for offset in (item.alertOffsets ?? []).prefix(2) {
                let date = start.addingTimeInterval(Double(offset))
                if date > now { result.append(PlannedEventAlert(id: "homebase-event:\(item.id.uuidString):\(offset)", date: date, title: item.title)) }
            }
        }
        return Array(result.sorted { $0.date < $1.date }.prefix(60))
    }
}
