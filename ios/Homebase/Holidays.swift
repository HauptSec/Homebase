import Foundation
import CryptoKit

/// A local, read-only calendar layer. Civil dates are regenerated in the phone's
/// time zone, so holidays stay all-day when travelling and never enter iCloud sync.
enum USHolidays {
    static func events(year: Int, timeZone: TimeZone = .current) -> [Item] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func date(_ month: Int, _ day: Int, year value: Int? = nil) -> Date {
            calendar.date(from: DateComponents(year: value ?? year, month: month, day: day))!
        }
        func nth(_ month: Int, _ weekday: Int, _ ordinal: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal))!
        }
        var result: [Item] = []
        func add(_ title: String, _ day: Date, federal: Bool = false, observed: Bool = false) {
            guard calendar.component(.year, from: day) == year else { return }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let key = "homebase-holiday:\(components.year!)-\(components.month!)-\(components.day!):\(title)"
            let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
            var item = Item(kind: .event)
            item.id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            item.calendarKey = key
            item.title = title
            item.allDay = true
            item.date = day.timeIntervalSince1970
            item.endDate = calendar.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince1970
            item.notes = observed ? "US federal holiday · Observed" : federal ? "US federal holiday" : "US common observance"
            result.append(item)
        }
        // Include adjacent years so New Year's observed on December 31 is retained.
        for value in (year - 1)...(year + 1) {
            for (title, month, day) in [("New Year’s Day", 1, 1), ("Juneteenth", 6, 19), ("Independence Day", 7, 4), ("Veterans Day", 11, 11), ("Christmas Day", 12, 25)] {
                let actual = date(month, day, year: value)
                add(title, actual, federal: true)
                let weekday = calendar.component(.weekday, from: actual)
                if weekday == 7 || weekday == 1 {
                    add(title + " (observed)", calendar.date(byAdding: .day, value: weekday == 7 ? -1 : 1, to: actual)!, federal: true, observed: true)
                }
            }
        }
        add("Martin Luther King Jr. Day", nth(1, 2, 3), federal: true)
        add("Presidents’ Day (Washington’s Birthday)", nth(2, 2, 3), federal: true)
        add("Memorial Day", nth(5, 2, -1), federal: true)
        add("Labor Day", nth(9, 2, 1), federal: true)
        add("Columbus Day / Indigenous Peoples’ Day", nth(10, 2, 2), federal: true)
        let thanksgiving = nth(11, 5, 4)
        add("Thanksgiving", thanksgiving, federal: true)
        for (title, month, day) in [("Valentine’s Day", 2, 14), ("St. Patrick’s Day", 3, 17), ("Earth Day", 4, 22), ("Cinco de Mayo", 5, 5), ("Flag Day", 6, 14), ("Patriot Day", 9, 11), ("Halloween", 10, 31), ("Christmas Eve", 12, 24), ("New Year’s Eve", 12, 31)] {
            add(title, date(month, day))
        }
        add("Mother’s Day", nth(5, 1, 2))
        add("Father’s Day", nth(6, 1, 3))
        add("Black Friday", calendar.date(byAdding: .day, value: 1, to: thanksgiving)!)
        // Gregorian Easter (Meeus/Jones/Butcher computus).
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let easter = date((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
        add("Good Friday", calendar.date(byAdding: .day, value: -2, to: easter)!)
        add("Easter Sunday", easter)
        return result.sorted { $0.date! == $1.date! ? $0.title < $1.title : $0.date! < $1.date! }
    }

    static func currentEvents(now: Date = Date()) -> [Item] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        return ((year - 1)...(year + 2)).flatMap { events(year: $0) }
    }
}

extension Item {
    var isHoliday: Bool { calendarKey.hasPrefix("homebase-holiday:") }
}
