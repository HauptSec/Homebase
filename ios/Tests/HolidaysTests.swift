import Foundation

@main struct HolidayTests {
    static func main() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = la
        func holiday(_ title: String, year: Int) -> Item {
            USHolidays.events(year: year, timeZone: la).first { $0.title == title }!
        }
        func check(_ title: String, _ year: Int, _ month: Int, _ day: Int) {
            let item = holiday(title, year: year)
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: item.when!)
            precondition(parts.year == year && parts.month == month && parts.day == day && parts.hour == 0, title)
            precondition(item.allDay && item.isHoliday && item.reminderAt == nil)
            precondition(calendar.date(byAdding: .day, value: 1, to: item.when!)!.timeIntervalSince1970 == item.endDate)
        }
        check("Independence Day (observed)", 2026, 7, 3)
        check("Christmas Day (observed)", 2022, 12, 26)
        check("New Year’s Day (observed)", 2021, 12, 31)
        check("Memorial Day", 2026, 5, 25)
        check("Thanksgiving", 2026, 11, 26)
        check("Mother’s Day", 2026, 5, 10)
        check("Father’s Day", 2026, 6, 21)
        check("Easter Sunday", 2026, 4, 5)
        check("Easter Sunday", 2027, 3, 28)
        check("Easter Sunday", 2024, 3, 31)
        check("Good Friday", 2026, 4, 3)
        for year in 2020...2040 {
            let items = USHolidays.events(year: year, timeZone: la)
            precondition(Set(items.map(\.id)).count == items.count)
            precondition(items.filter { $0.notes == "US federal holiday" }.count == 11)
            precondition(items.allSatisfy { calendar.component(.year, from: $0.when!) == year })
            let utc = USHolidays.events(year: year, timeZone: TimeZone(secondsFromGMT: 0)!)
            precondition(Set(items.map(\.id)) == Set(utc.map(\.id)), "IDs must survive travel")
        }
        print("Holiday tests passed: observed dates, year boundaries, Easter, 21 years of unique IDs and timezone independence")
    }
}
