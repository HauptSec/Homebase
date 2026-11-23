import Foundation

@main struct HomeTests {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var movedTask = Item(kind: .task)
        movedTask.assignedOwner = "Alex"; movedTask.date = 12345; movedTask.notes = "Keep me"
        let taskID = movedTask.id
        precondition(movedTask.move(to: .taskOwner("Laura")))
        precondition(movedTask.id == taskID && movedTask.assignedOwner == "Laura" && movedTask.date == 12345 && movedTask.notes == "Keep me")
        precondition(!movedTask.move(to: .taskOwner("Laura")))
        precondition(movedTask.move(to: .taskOwner(nil)) && movedTask.assignedOwner == nil)
        precondition(!movedTask.move(to: .taskOwner("Other")))
        precondition(!movedTask.move(to: .groceryStore("Costco")))
        movedTask.done = true
        precondition(!movedTask.move(to: .taskOwner("Alex")))
        var movedGrocery = Item(kind: .grocery)
        movedGrocery.quantity = "2"; movedGrocery.store = "Costco"
        precondition(movedGrocery.move(to: .groceryStore(" Target ")))
        precondition(movedGrocery.store == "Target" && movedGrocery.quantity == "2")
        precondition(movedGrocery.move(to: .groceryStore("")) && movedGrocery.store.isEmpty)
        precondition(!movedGrocery.move(to: .groceryStore(String(repeating: "a", count: 101))))
        movedGrocery.deleted = true
        precondition(!movedGrocery.move(to: .groceryStore("Costco")))
        // Cover ordinary midnight, both DST transitions, and the year boundary.
        for components in [DateComponents(year: 2026, month: 11, day: 7),
                           DateComponents(year: 2026, month: 3, day: 8),
                           DateComponents(year: 2026, month: 11, day: 1),
                           DateComponents(year: 2026, month: 12, day: 31)] {
            let day = calendar.date(from: components)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
            let now = calendar.date(bySettingHour: 14, minute: 25, second: 0, of: day)!
            let futureEvent = Item.homeDraft(kind: .event, viewing: tomorrow, now: now, calendar: calendar)
            precondition(calendar.isDate(futureEvent.when!, inSameDayAs: tomorrow))
            precondition(calendar.component(.hour, from: futureEvent.when!) == 14)
            precondition(calendar.component(.minute, from: futureEvent.when!) == 25)
            precondition(Item.homeDraft(kind: .event, viewing: day, now: now, calendar: calendar).when == now)
            precondition(Item.homeDraft(kind: .event, viewing: day, now: tomorrow, calendar: calendar).when == tomorrow)
            for kind in Kind.allCases where kind != .event {
                precondition(Item.homeDraft(kind: kind, viewing: tomorrow, now: now, calendar: calendar).date == nil)
            }
            var grocery = Item(kind: .grocery)
            let checkout = tomorrow.addingTimeInterval(-1)
            grocery.complete(now: checkout)
            precondition(grocery.visibleOnGroceryList(on: checkout, calendar: calendar))
            precondition(!grocery.visibleOnGroceryList(on: tomorrow, calendar: calendar))
            grocery.complete(now: checkout)
            precondition(!grocery.done && grocery.completedAt == nil)
            precondition(grocery.visibleOnGroceryList(on: tomorrow, calendar: calendar))
            var movedDinner = Item(kind: .dinner)
            movedDinner.date = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: day)!.timeIntervalSince1970
            movedDinner.reminderAt = movedDinner.date! - 3600
            movedDinner.ingredients = ["Pasta"]
            precondition(movedDinner.move(to: .dinnerDay(tomorrow), calendar: calendar))
            precondition(calendar.isDate(movedDinner.when!, inSameDayAs: tomorrow))
            precondition(calendar.component(.hour, from: movedDinner.when!) == 18)
            precondition(calendar.component(.minute, from: movedDinner.when!) == 30)
            precondition(movedDinner.date! - movedDinner.reminderAt! == 3600 && movedDinner.ingredients == ["Pasta"])
            precondition(!movedDinner.move(to: .dinnerDay(tomorrow), calendar: calendar))
            let roundTrip = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(movedDinner))
            precondition(roundTrip == movedDinner)
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
        var task = Item(kind: .task)
        let completion = Date(timeIntervalSince1970: 1794268800)
        task.complete(now: completion, owner: "Laura", deviceID: "laura-phone")
        precondition(task.done && task.completedAt == completion.timeIntervalSince1970)
        precondition(task.completedBy == "Laura" && task.completedByDevice == "laura-phone")
        let restored = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(task))
        precondition(restored == task)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        for key in ["completedAt", "completedBy", "completedByDevice"] { legacy.removeValue(forKey: key) }
        let oldTask = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(oldTask.done && oldTask.completedAt == nil && oldTask.completedBy == nil)
        task.complete()
        precondition(!task.done && task.completedAt == nil && task.completedBy == nil && task.completedByDevice == nil)
        task.complete(now: completion.addingTimeInterval(60), owner: "Alex", deviceID: "alex-phone")
        precondition(task.done && task.completedBy == "Alex" && task.completedAt == completion.timeIntervalSince1970 + 60)
        var early = Item(kind: .task); early.createdAt = 10
        var due = Item(kind: .task); due.createdAt = 1; due.date = 20
        var late = Item(kind: .task); late.createdAt = 30; late.updatedAt = 2
        precondition([late, due, early].sorted(by: Item.taskOrder).map(\.id) == [early.id, due.id, late.id])
        early.assignedOwner = "Laura"
        let assigned = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(early))
        precondition(assigned.assignedOwner == "Laura" && assigned.createdAt == 10)
        for key in ["assignedOwner", "createdAt", "reminderKey"] { legacy.removeValue(forKey: key) }
        let unassigned = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(unassigned.assignedOwner == nil && unassigned.createdAt == nil)
        print("Task completion passed: offline timestamp, attribution, reopening and cache compatibility")
        print("Home tests passed: event draft dates, dinner expiry, history, DST, year boundary, overdue tasks/bills and event overlap")
    }
}
