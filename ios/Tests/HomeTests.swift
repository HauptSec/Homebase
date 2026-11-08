import Foundation

@main struct HomeTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Cover ordinary midnight, both DST transitions, and the year boundary.
        for components in [DateComponents(year: 2026, month: 11, day: 7),
                           DateComponents(year: 2026, month: 3, day: 8),
                           DateComponents(year: 2026, month: 11, day: 1),
                           DateComponents(year: 2026, month: 12, day: 31)] {
            let day = calendar.date(from: components)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
            var dinner = Item(kind: .dinner)
            dinner.date = day.timeIntervalSince1970
            precondition(dinner.appearsOnHome(on: tomorrow.addingTimeInterval(-1), isToday: true, calendar: calendar))
            precondition(!dinner.appearsOnHome(on: tomorrow, isToday: true, calendar: calendar))
            precondition(dinner.appearsOnHome(on: day, isToday: false, calendar: calendar))
            precondition(!dinner.appearsOnHome(on: calendar.date(byAdding: .day, value: -1, to: day)!, isToday: true, calendar: calendar))
            dinner.done = true
            precondition(!dinner.appearsOnHome(on: day, isToday: true, calendar: calendar))
            for kind in [Kind.bill, .task] {
                var overdue = Item(kind: kind)
                overdue.date = day.timeIntervalSince1970
                precondition(overdue.appearsOnHome(on: tomorrow, isToday: true, calendar: calendar))
                overdue.done = true
                precondition(!overdue.appearsOnHome(on: tomorrow, isToday: true, calendar: calendar))
            }
            var event = Item(kind: .event)
            event.date = day.timeIntervalSince1970
            event.endDate = tomorrow.timeIntervalSince1970
            precondition(event.appearsOnHome(on: day, isToday: true, calendar: calendar))
            precondition(!event.appearsOnHome(on: tomorrow, isToday: true, calendar: calendar))
            event.endDate = tomorrow.addingTimeInterval(3600).timeIntervalSince1970
            precondition(event.appearsOnHome(on: tomorrow, isToday: true, calendar: calendar))
        }
        precondition(!Item(kind: .dinner).appearsOnHome(on: Date(), isToday: true))
        print("Home tests passed: dinner expiry, history, DST, year boundary, overdue tasks/bills and event overlap")
    }
}
