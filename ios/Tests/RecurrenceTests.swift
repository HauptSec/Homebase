import Foundation
import EventKit

@main struct RecurrenceTests {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        func root(_ start: Date, repeat frequency: String) -> Item {
            var item = Item(kind: .event); item.title = "Family plan"; item.date = start.timeIntervalSince1970
            item.endDate = start.addingTimeInterval(3600).timeIntervalSince1970; item.recurrence = frequency
            item.recurrenceTimeZone = calendar.timeZone.identifier; item.seriesVersion = UUID()
            return item
        }
        let monthly = root(date(2026, 1, 31), repeat: "monthly")
        let months = EventRecurrence.occurrences(of: monthly, from: date(2026, 1, 1), to: date(2026, 6, 1))
        precondition(months.map { calendar.component(.month, from: $0.when!) } == [1,3,5])
        let leap = root(date(2024, 2, 29), repeat: "yearly")
        precondition(EventRecurrence.occurrences(of: leap, from: date(2024, 1, 1), to: date(2029, 1, 1)).map { calendar.component(.year, from: $0.when!) } == [2024,2028])
        let weekly = root(date(2026, 3, 1), repeat: "weekly")
        let dst = EventRecurrence.occurrences(of: weekly, from: date(2026, 3, 1), to: date(2026, 3, 16))
        precondition(dst.count == 3 && dst.allSatisfy { calendar.component(.hour, from: $0.when!) == 9 })
        precondition(dst[1].date! - dst[0].date! == 7 * 86400 - 3600)
        var custom = root(date(2026, 3, 2), repeat: "custom")
        custom.customFrequency = "weekly"; custom.customInterval = 2; custom.repeatWeekdays = [2,4]
        let customDates = EventRecurrence.occurrences(of: custom, from: date(2026,3,1), to: date(2026,3,20))
        precondition(customDates.map { calendar.component(.day, from: $0.when!) } == [2,4,16,18])
        var allDay = root(date(2026,3,7,0), repeat: "daily"); allDay.allDay = true; allDay.endDate = date(2026,3,8,0).timeIntervalSince1970
        let days = EventRecurrence.occurrences(of: allDay, from: date(2026,3,7,0), to: date(2026,3,10,0))
        precondition(days.count == 3 && days[1].endDate! - days[1].date! == 23 * 3600)
        var finite = weekly; finite.recurrenceUntil = date(2026,3,8,23).timeIntervalSince1970
        precondition(EventRecurrence.occurrences(of: finite, from: date(2026,3,1), to: date(2026,4,1)).count == 2)
        var moved = dst[1]; moved.date! += 7200; moved.endDate! += 7200; moved.title = "Moved only once"
        var removed = dst[2]; removed.deleted = true
        let visible = EventRecurrence.visibleItems([weekly,moved,removed], now: date(2026,3,1))
        precondition(visible.filter { $0.id == moved.id }.count == 1 && visible.first { $0.id == moved.id }!.date == moved.date)
        precondition(!visible.contains { $0.id == removed.id })
        var revised = weekly; revised.seriesVersion = UUID()
        precondition(EventRecurrence.visibleItems([revised,moved,removed], now: date(2026,3,1)).first { $0.id == moved.id }!.title == weekly.title)
        revised.deleted = true
        precondition(EventRecurrence.visibleItems([revised,moved], now: date(2026,3,1)).isEmpty)
        var alerted = weekly; alerted.alertOffsets = [-900, 0]
        let alerts = EventAlertPlan.make(items: [alerted], now: date(2026,3,1,8))
        precondition(alerts.count == 60 && alerts[0].date == date(2026,3,1).addingTimeInterval(-900))
        alerted.calendarKey = "native-series:test"
        precondition(EventAlertPlan.make(items: [alerted], now: date(2026,3,1), usesAppleCalendar: true).isEmpty)
        let store = EKEventStore()
        let native = EKEvent(eventStore: store)
        custom.location = "123 Main Street"; custom.latitude = 34; custom.longitude = -118; custom.alertOffsets = [-900, 0]
        CalendarEventFields.write(custom, to: native)
        native.recurrenceRules = [CalendarEventFields.rule(for: custom)!]
        var imported = Item(kind: .event); CalendarEventFields.read(native, into: &imported)
        precondition(CalendarEventFields.readRule(native, into: &imported))
        precondition(imported.recurrence == "custom" && imported.customInterval == 2 && imported.repeatWeekdays == [2,4])
        precondition(imported.alertOffsets == [-900,0] && imported.location == custom.location && imported.latitude == 34)
        let basic = EKEvent(eventStore: store); CalendarEventFields.write(weekly, to: basic); basic.recurrenceRules = [CalendarEventFields.rule(for: weekly)!]
        var basicCopy = weekly; CalendarEventFields.read(basic, into: &basicCopy)
        precondition(CalendarEventFields.readRule(basic, into: &basicCopy))
        precondition(CalendarEventFields.scheduleStamp(basicCopy) == CalendarEventFields.scheduleStamp(weekly))
        var cleared = weekly; cleared.recurrenceUntil = nil; cleared.latitude = nil; cleared.alertOffsets = []
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as! [String: Any]
        precondition(json["recurrenceUntil"] is NSNull && json["latitude"] is NSNull)
        let restored = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(custom))
        precondition(restored == custom)
        print("Recurrence tests passed: monthly/leap-year skips, DST, custom weekdays, end date, exceptions, alerts, native rules/locations and explicit clears")
    }
}
