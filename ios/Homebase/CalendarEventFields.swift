import Foundation
import EventKit
import CoreLocation
import CryptoKit

/// Event fields shared by ordinary events, series anchors, and detached occurrences.
enum CalendarEventFields {
    static func read(_ event: EKEvent, into item: inout Item) {
        item.title = event.title ?? "Untitled event"; item.date = event.startDate.timeIntervalSince1970
        item.endDate = event.endDate.timeIntervalSince1970; item.allDay = event.isAllDay; item.notes = event.notes ?? ""
        item.location = event.location ?? ""
        item.latitude = event.structuredLocation?.geoLocation?.coordinate.latitude
        item.longitude = event.structuredLocation?.geoLocation?.coordinate.longitude
        item.alertOffsets = Array(Set((event.alarms ?? []).compactMap { alarm in
            let offset = Int(alarm.absoluteDate?.timeIntervalSince(event.startDate) ?? alarm.relativeOffset)
            return (-604800...0).contains(offset) ? offset : nil
        })).sorted().prefix(2).map { $0 }
        item.recurrenceTimeZone = event.timeZone?.identifier ?? TimeZone.current.identifier
    }
    static func write(_ item: Item, to event: EKEvent) {
        event.isAllDay = item.allDay; event.title = item.title; event.startDate = item.when
        event.endDate = Date(timeIntervalSince1970: item.endDate ?? (item.date ?? 0) + 3600); event.notes = item.notes
        event.timeZone = item.allDay ? nil : item.recurrenceTimeZone.flatMap(TimeZone.init(identifier:))
        event.location = item.location
        if let name = item.location, !name.isEmpty {
            let location = EKStructuredLocation(title: name)
            if let lat = item.latitude, let lon = item.longitude { location.geoLocation = CLLocation(latitude: lat, longitude: lon) }
            event.structuredLocation = location
        } else { event.structuredLocation = nil }
        event.alarms = (item.alertOffsets ?? []).map { EKAlarm(relativeOffset: TimeInterval($0)) }
    }
    static func stamp(_ item: Item) -> String {
        "\(item.title)|\(item.date ?? 0)|\(item.endDate ?? 0)|\(item.allDay)|\(item.notes)|\(item.location ?? "")|\(item.latitude ?? 0)|\(item.longitude ?? 0)|\((item.alertOffsets ?? []).sorted())"
    }
    static func stamp(_ event: EKEvent) -> String { var item = Item(kind: .event); read(event, into: &item); return stamp(item) }
    static func rule(for item: Item) -> EKRecurrenceRule? {
        guard item.isRecurringSeries else { return nil }
        let name = item.recurrence == "custom" ? item.customFrequency ?? "weekly" : item.recurrence
        let frequency: EKRecurrenceFrequency = name == "daily" ? .daily : ["weekly", "biweekly"].contains(name) ? .weekly : name == "monthly" ? .monthly : .yearly
        let interval = item.recurrence == "custom" ? max(1, item.customInterval ?? 1) : name == "biweekly" ? 2 : 1
        let end = item.recurrenceUntil.map { EKRecurrenceEnd(end: Date(timeIntervalSince1970: $0)) }
        let days = name == "weekly" ? item.repeatWeekdays?.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } } : nil
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days?.isEmpty == false ? days : nil, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }
    /// Preserve unsupported Apple rules by pausing that series, never flattening them.
    static func readRule(_ event: EKEvent, into item: inout Item) -> Bool {
        guard let rules = event.recurrenceRules, !rules.isEmpty else {
            item.recurrence = "none"; item.recurrenceUntil = nil; item.repeatWeekdays = nil; return true
        }
        guard rules.count == 1, let rule = rules.first, rule.interval <= 99,
              (rule.recurrenceEnd?.occurrenceCount ?? 0) == 0,
              (rule.weeksOfTheYear ?? []).isEmpty, (rule.daysOfTheYear ?? []).isEmpty, (rule.setPositions ?? []).isEmpty else { return false }
        let calendar = EventRecurrence.calendar(for: item)
        let month = calendar.component(.month, from: event.startDate), day = calendar.component(.day, from: event.startDate)
        guard (rule.daysOfTheMonth ?? []).allSatisfy({ $0.intValue == day }),
              (rule.monthsOfTheYear ?? []).allSatisfy({ $0.intValue == month }),
              (rule.daysOfTheWeek ?? []).allSatisfy({ $0.weekNumber == 0 }),
              (rule.daysOfTheWeek ?? []).isEmpty || rule.frequency == .weekly else { return false }
        let name: String
        switch rule.frequency { case .daily: name = "daily"; case .weekly: name = "weekly"; case .monthly: name = "monthly"; case .yearly: name = "yearly"; @unknown default: return false }
        let weekdays = (rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue }.sorted()
        let basicWeek = weekdays.isEmpty || weekdays == [calendar.component(.weekday, from: event.startDate)]
        item.recurrence = rule.interval == 1 && basicWeek ? name : name == "weekly" && rule.interval == 2 && basicWeek ? "biweekly" : "custom"
        item.customFrequency = item.recurrence == "custom" ? name : nil
        item.customInterval = item.recurrence == "custom" ? rule.interval : nil
        item.repeatWeekdays = item.recurrence == "custom" ? weekdays : nil
        item.recurrenceUntil = rule.recurrenceEnd?.endDate?.timeIntervalSince1970
        return true
    }
    static func scheduleStamp(_ item: Item) -> String {
        "\(item.date ?? 0)|\(item.endDate ?? 0)|\(item.allDay)|\(item.recurrence)|\(item.recurrenceUntil ?? 0)|\(item.recurrenceTimeZone ?? "")|\(item.customFrequency ?? "")|\(item.customInterval ?? 1)|\((item.repeatWeekdays ?? []).sorted())"
    }
}

