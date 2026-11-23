import Foundation
import EventKit

@main struct ReminderTests {
    static func main() {
        let events = EKEventStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        for day in [DateComponents(year: 2026, month: 3, day: 8),
                    DateComponents(year: 2026, month: 11, day: 1),
                    DateComponents(year: 2026, month: 12, day: 31)] {
            var dinner = Item(kind: .dinner)
            dinner.title = "Tacos"
            dinner.date = calendar.date(from: day)!.addingTimeInterval(18 * 3600).timeIntervalSince1970
            dinner.notes = "Family favorite\nHomebase owner: Alex"
            dinner.ingredients = ["Tortillas"]
            dinner.prepSteps = ["Chop vegetables"]
            dinner.cookingSteps = ["Warm tortillas"]
            let reminder = EKReminder(eventStore: events)
            ReminderFields.write(dinner, to: reminder)
            precondition(reminder.dueDateComponents?.hour == nil)
            precondition(reminder.notes == dinner.notes)
            precondition(reminder.url?.host == "dinner")
            var imported = dinner
            ReminderFields.read(reminder, into: &imported)
            precondition(calendar.isDate(imported.when!, inSameDayAs: dinner.when!))
            precondition(imported.ingredients == dinner.ingredients && imported.prepSteps == dinner.prepSteps && imported.cookingSteps == dinner.cookingSteps)
            precondition(imported.notes == dinner.notes && imported.assignedOwner == nil)
            reminder.dueDateComponents = calendar.dateComponents([.calendar, .year, .month, .day], from: calendar.date(byAdding: .day, value: 7, to: dinner.when!)!)
            reminder.isCompleted = true
            ReminderFields.read(reminder, into: &imported)
            precondition(imported.done && calendar.isDate(imported.when!, inSameDayAs: calendar.date(byAdding: .day, value: 7, to: dinner.when!)!))
            reminder.dueDateComponents = nil
            ReminderFields.read(reminder, into: &imported)
            precondition(imported.date == nil) // Bridge skips undated new dinners and flags existing ones.
        }
        var task = Item(kind: .task)
        task.title = "Shopping"; task.assignedOwner = "Laura"; task.notes = "Milk"
        task.date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 15, minute: 30))!.timeIntervalSince1970
        let reminder = EKReminder(eventStore: events)
        ReminderFields.write(task, to: reminder)
        precondition(reminder.dueDateComponents?.hour == 15)
        precondition(reminder.url?.host == "task")
        var imported = Item(kind: .task)
        ReminderFields.read(reminder, into: &imported)
        precondition(imported.assignedOwner == "Laura" && imported.notes == "Milk" && imported.date == task.date)
        print("Reminder fields passed: dinner dates, week changes, completion, recipe preservation, and task compatibility")
    }
}
