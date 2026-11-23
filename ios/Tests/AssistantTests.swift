import Foundation

@main struct AssistantTests {
    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected validation failure") } catch {}
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = AssistantData.day("2026-11-22", calendar: calendar)!
        var task = Item(kind: .task); task.title = "Book dentist"; task.assignedOwner = "Alex"
        task.notes = "Bring insurance card"; task.date = today.timeIntervalSince1970
        let changed = try AssistantData.update(task, owner: "Laura", completed: true, actor: "Alex", device: "phone")
        precondition(changed.assignedOwner == "Laura" && changed.completedBy == "Alex" && changed.done && changed.completedAt != nil)
        precondition(changed.id == task.id && changed.notes == task.notes)
        let reopened = try AssistantData.update(changed, completed: false)
        precondition(!reopened.done && reopened.completedAt == nil)
        let unassigned = try AssistantData.update(task, owner: "Unassigned")
        precondition(unassigned.assignedOwner == nil)
        expectFailure { _ = try AssistantData.update(task, completed: true) }
        expectFailure { _ = try AssistantData.update(task, owner: "Other") }
        expectFailure { _ = try AssistantData.update(task, store: "Costco") }
        expectFailure { _ = try AssistantData.update(task, title: "  ") }
        var grocery = Item(kind: .grocery); grocery.title = "Milk"; grocery.store = "Costco"; grocery.quantity = "2"
        let purchased = try AssistantData.update(grocery, completed: true)
        precondition(purchased.done && purchased.visibleOnGroceryList(on: Date()))
        precondition(!purchased.visibleOnGroceryList(on: Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
        var dinner = Item(kind: .dinner); dinner.title = "Pasta"; dinner.date = today.timeIntervalSince1970
        dinner.ingredients = ["Tomatoes", "Pasta"]; dinner.prepSteps = ["Chop tomatoes"]
        let moved = try AssistantData.update(dinner, date: today.addingTimeInterval(86400))
        precondition(moved.ingredients == dinner.ingredients && moved.prepSteps == dinner.prepSteps)
        var event = Item(kind: .event); event.title = "Trip"; event.date = today.addingTimeInterval(-3600).timeIntervalSince1970
        event.endDate = today.addingTimeInterval(3600).timeIntervalSince1970; event.reminderAt = event.date! - 900
        let rescheduled = try AssistantData.update(event, date: today)
        precondition(rescheduled.endDate == today.addingTimeInterval(7200).timeIntervalSince1970 && rescheduled.reminderAt == today.addingTimeInterval(-900).timeIntervalSince1970)
        expectFailure { _ = try AssistantData.update(event, end: today.addingTimeInterval(-7200)) }
        var deleted = task; deleted.id = UUID(); deleted.deleted = true
        let data = [task, grocery, dinner, event, deleted]
        let day = try AssistantData.matches(data, filter: .init(startDay: "2026-11-22", endDay: "2026-11-22"), calendar: calendar)
        precondition(Set(day.map(\.id)) == Set([task.id, dinner.id, event.id]))
        let matchCheck1 = try AssistantData.matches(data, filter: .init(kind: "grocery", store: "costco")).count == 1
        precondition(matchCheck1)
        let matchCheck2 = try AssistantData.matches(data, filter: .init(kind: "dinner", text: "tomatoes")).count == 1
        precondition(matchCheck2)
        let matchCheck3 = try AssistantData.matches(data, filter: .init(kind: "task", owner: "Alex")).count == 1
        precondition(matchCheck3)
        let matchCheck4 = try AssistantData.matches(data, filter: .init(completion: "completed")).isEmpty
        precondition(matchCheck4)
        expectFailure { _ = try AssistantData.matches(data, filter: .init(startDay: "not a date")) }
        var yesterdayGrocery = purchased; yesterdayGrocery.completedAt = today.addingTimeInterval(-3600).timeIntervalSince1970
        let yesterdayMatches = try AssistantData.matches([yesterdayGrocery], filter: .init(kind: "grocery", startDay: "2026-11-21", endDay: "2026-11-21", completion: "completed", dateField: "completed"), calendar: calendar)
        precondition(yesterdayMatches.count == 1)
        let many = (0..<20).map { i -> Item in var value = grocery; value.id = UUID(); value.title = "Item \(i)"; return value }
        let output = try AssistantData.result(many, filter: .init())
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        precondition(json["totalMatches"] as? Int == 20 && json["hasMore"] as? Bool == true)
        let page = json["records"] as! [[String: Any]]
        precondition(page.count == 6)
        let second = try AssistantData.result(many, filter: .init(offset: page.count))
        let next = try JSONSerialization.jsonObject(with: Data(second.utf8)) as! [String: Any]
        let nextPage = next["records"] as! [[String: Any]]
        precondition(Set(page.compactMap { $0["id"] as? String }).isDisjoint(with: nextPage.compactMap { $0["id"] as? String }))
        print("Assistant tests passed: validation, identity preservation, completion, date shifts, recipe preservation, cross-category queries and pagination")
    }
}
