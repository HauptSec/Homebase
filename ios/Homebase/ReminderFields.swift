import EventKit
import Foundation

/// Shared fields only; recipe ingredients and instructions stay on the Homebase item.
enum ReminderFields {
    static func read(_ reminder: EKReminder, into item: inout Item) {
        let kind = item.kind
        item.title = reminder.title ?? (kind == .dinner ? "Untitled dinner" : "Untitled task")
        if kind == .task { item.assignedOwner = nil }
        var lines = (reminder.notes ?? "").components(separatedBy: "\n")
        // Only our trailing metadata line represents ownership; ordinary notes remain intact.
        if kind == .task, let last = lines.last, last.hasPrefix("Homebase owner: "), ["Alex", "Laura", "Unassigned"].contains(String(last.dropFirst(16))) {
            let owner = String(last.dropFirst(16))
            item.assignedOwner = owner == "Unassigned" ? nil : owner
            lines.removeLast()
            if lines.last == "" { lines.removeLast() }
        }
        item.notes = lines.joined(separator: "\n")
        item.date = reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }?.timeIntervalSince1970
        item.reminderAt = reminder.alarms?.first?.absoluteDate?.timeIntervalSince1970
        item.done = reminder.isCompleted
        item.completedAt = reminder.completionDate?.timeIntervalSince1970
        item.reminderKey = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
    }
    static func write(_ item: Item, to reminder: EKReminder) {
        let kind = item.kind
        reminder.title = item.title
        reminder.notes = kind == .dinner ? item.notes : item.notes + (item.notes.isEmpty ? "" : "\n\n") + "Homebase owner: \(item.assignedOwner ?? "Unassigned")"
        reminder.dueDateComponents = item.when.map { Calendar.current.dateComponents(kind == .dinner ? [.calendar, .year, .month, .day] : [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: $0) }
        reminder.alarms = item.reminderAt.map { [EKAlarm(absoluteDate: Date(timeIntervalSince1970: $0))] }
        reminder.isCompleted = item.done
        reminder.completionDate = item.done ? item.completedAt.map { Date(timeIntervalSince1970: $0) } : nil
        reminder.url = URL(string: "homebase://\(kind.rawValue)/\(item.id.uuidString)")
    }
}
