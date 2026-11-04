import Foundation

@main struct BudgetTests {
    static func main() throws {
        var original = Item(kind: .bill)
        original.title = "Rent"; original.date = 1793811600; original.amountCents = 200000
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "budgetType")
        let restored = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!restored.isIncome && restored.amountCents == 200000)
        var paycheck = original
        paycheck.budgetType = .income; paycheck.recurrence = "biweekly"
        paycheck.reminderAt = paycheck.date! - 3600
        let expected = Calendar.current.date(byAdding: .day, value: 14, to: paycheck.when!)!
        paycheck.complete()
        precondition(paycheck.isIncome && !paycheck.done && paycheck.paidDates.count == 1)
        precondition(paycheck.when == expected && paycheck.reminderAt == paycheck.date! - 3600)
        precondition(paycheck.completionLabel == "Received")
        var once = original
        once.complete()
        precondition(once.done && once.paidDates.count == 1 && once.completionLabel == "Reopen")
        once.complete()
        precondition(!once.done && once.paidDates.count == 1)
        let roundTrip = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(paycheck))
        precondition(roundTrip == paycheck)
        var meal = Item(kind: .meal)
        meal.ingredients = ["Chicken", "Salt"]
        meal.prepSteps = ["Season chicken"]
        meal.cookingSteps = ["Roast", "Rest"]
        let savedMeal = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(meal))
        precondition(savedMeal == meal)
        var oldMeal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meal)) as! [String: Any]
        oldMeal.removeValue(forKey: "prepSteps"); oldMeal.removeValue(forKey: "cookingSteps")
        let migratedMeal = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: oldMeal))
        precondition(migratedMeal.ingredients == meal.ingredients && migratedMeal.prepSteps == nil)
        print("Meal instructions passed: offline round-trip and older cache compatibility")
        print("Budget tests passed: legacy bills, income round-trip, biweekly recurrence, reminders and reopening")
    }
}
