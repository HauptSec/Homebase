import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if !store.paired { PairView() }
        else {
            TabView {
                TodayView().tabItem { Label("Today", systemImage: "house") }
                ItemList(kind: .event).tabItem { Label("Calendar", systemImage: "calendar") }
                MealsView().tabItem { Label("Meals", systemImage: "fork.knife") }
                ItemList(kind: .grocery).tabItem { Label("Groceries", systemImage: "basket") }
                MoreView().tabItem { Label("Household", systemImage: "square.grid.2x2") }
            }
        }
    }
}
struct PairView: View {
    @EnvironmentObject var store: Store
    @State var code = ""
    @State var name = UIDevice.current.name
    @State var busy = false
    @State var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "house.lodge.fill").font(.system(size: 46)).foregroundStyle(.tint)
                        Text("A little more\nlife in order.").font(.system(.largeTitle, design: .serif)).fontWeight(.medium)
                        Text("Your plans, meals, and everyday things. Together, in one quiet place.").foregroundStyle(.secondary)
                    }.padding(.vertical, 24).listRowBackground(Color.clear)
                }
                Section("Connect your home") {
                    TextField("Server address", text: $store.endpoint).disabled(store.paired).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Device name", text: $name)
                    SecureField("One-time pairing code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "Connecting…" : "Make yourself at home") {
                        busy = true
                        Task { do { try await store.pair(code: code, name: name) } catch { message = error.localizedDescription }; busy = false }
                    }.disabled(busy || code.isEmpty || name.isEmpty)
                }
                if let message { Text(message).foregroundStyle(.red) }
                Text("Pair once using a code from your home server. After that, just open Homebase.").font(.footnote).foregroundStyle(.secondary)
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Homebase")
        }
    }
}
struct TodayView: View {
    @EnvironmentObject var store: Store
    @State var editing: Item?
    @State private var dayOffset = 0
    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: Date()))!
    }
    private var isToday: Bool { dayOffset == 0 }
    private var dayItems: [Item] {
        let calendar = Calendar.current
        let start = selectedDay
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return store.items.filter { item in
            guard item.kind != .meal, item.kind != .grocery, let when = item.when else { return false }
            if isToday && item.done { return false }
            if item.kind == .event {
                let eventEnd = item.endDate ?? when.timeIntervalSince1970
                return when < end && (eventEnd > start.timeIntervalSince1970 || (eventEnd == when.timeIntervalSince1970 && when >= start))
            }
            return calendar.isDate(when, inSameDayAs: start) || (isToday && when < start)
        }.sorted { ($0.date ?? 0) < ($1.date ?? 0) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button { dayOffset -= 1 } label: {
                                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                            }.accessibilityLabel("Previous day")
                            Spacer(minLength: 0)
                            Text(selectedDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                                .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                                .accessibilityAddTraits(.updatesFrequently)
                            Spacer(minLength: 0)
                            Button { dayOffset += 1 } label: {
                                Image(systemName: "chevron.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("Next day")
                        }.buttonStyle(.borderless)
                        if !isToday {
                            Button("Back to today") { dayOffset = 0 }.font(.subheadline).buttonStyle(.borderless)
                        }
                        Text("Welcome home.").font(.system(size: 34, weight: .medium, design: .serif))
                        Text(dayItems.isEmpty ? (isToday ? "A little breathing room today." : "A little breathing room this day.") : "Your day, a little more together.").foregroundStyle(.secondary)
                        Label(store.status, systemImage: store.syncing ? "arrow.triangle.2.circlepath" : "circle.fill").font(.caption).foregroundStyle(.secondary)
                        if !store.cache.queue.isEmpty { Text("\(store.cache.queue.count) changes saved on this phone").font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 18)
                }.listRowBackground(Color.clear)
                if store.updateAvailable {
                    Section { Button { Task { await store.openInstallPage() } } label: { Label("Homebase update available", systemImage: "arrow.down.app") } }
                }
                if !store.cache.conflicts.isEmpty {
                    Section { NavigationLink { ConflictsView() } label: { Label("Review shared changes", systemImage: "exclamationmark.arrow.triangle.2.circlepath") } }
                }
                Section(isToday ? "Today & overdue" : "On this day") {
                    if dayItems.isEmpty { ContentUnavailableView("Nothing pressing", systemImage: "sun.horizon", description: Text("Add a plan or enjoy a clear day.")) }
                    ForEach(dayItems) { item in
                        if item.isHoliday { ItemRow(item: item) }
                        else { Button { editing = item } label: { ItemRow(item: item) }.buttonStyle(.plain) }
                    }
                }
                Section("Your household") {
                    ForEach([Kind.task, .bill, .grocery]) { kind in
                        NavigationLink { ItemList(kind: kind) } label: {
                            Label { HStack { Text(kind.title); Spacer(); Text("\(store.items(kind).filter { !$0.done }.count)").foregroundStyle(.secondary) } } icon: { Image(systemName: kind.symbol).foregroundStyle(.tint) }
                        }
                    }
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Homebase")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { ForEach(Kind.allCases.filter { $0 != .meal }) { kind in Button(kind.title, systemImage: kind.symbol) { editing = Item(kind: kind) } } } label: { Image(systemName: "plus") } } }
                .refreshable { await store.sync(); await CalendarBridge.shared.run(store: store) }
                .sheet(item: $editing) { ItemEditSheet(item: $0) }
        }
    }
}
struct ItemRow: View {
    let item: Item
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.done ? "checkmark.circle.fill" : item.kind.symbol).font(.title3).foregroundStyle(item.done ? Color.secondary : Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                if let when = item.when { Text(when, format: item.kind == .event && !item.allDay ? .dateTime.year().month(.abbreviated).day().hour().minute() : .dateTime.year().month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary) }
                if item.seriesID != nil { Label("Repeating event", systemImage: "repeat").font(.caption).foregroundStyle(.secondary) }
                if item.kind == .bill { Text("\(item.isIncome ? "Income" : "Expense") · \(item.recurrenceLabel)").font(.caption).foregroundStyle(.secondary) }
                if item.allDay { Text("All day").font(.caption).foregroundStyle(.secondary) }
                if !item.quantity.isEmpty { Text(item.quantity).font(.caption).foregroundStyle(.secondary) }
                if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let cents = item.amountCents {
                HStack(spacing: 2) {
                    if item.kind == .bill { Text(item.isIncome ? "+" : "−") }
                    Text(Double(cents) / 100, format: .currency(code: item.currency))
                }.font(.subheadline).monospacedDigit().foregroundStyle(item.isIncome ? Color.green : Color.primary)
            }
        }.padding(.vertical, 6)
    }
}
struct ItemList: View {
    @EnvironmentObject var store: Store
    let kind: Kind
    @State var editing: Item?
    @State var search = ""
    @State private var deletingEvent: Item?
    @State private var showHistory = false
    @State private var calendarToday = Calendar.current.startOfDay(for: Date())
    @State var week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start
    var values: [Item] {
        store.items(kind).filter { item in
            let match = search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.notes.localizedCaseInsensitiveContains(search)
            if kind == .bill { return match && (showHistory ? item.done : !item.done) }
            if kind == .event {
                guard let start = item.when else { return false }
                // End dates are exclusive; a multi-day event remains visible through its final day.
                let isPast = start < calendarToday && (item.endDate.map { Date(timeIntervalSince1970: $0) <= calendarToday } ?? true)
                return match && (showHistory ? isPast : !isPast)
            }
            if kind == .dinner { return match && (item.when.map { $0 >= week && $0 < Calendar.current.date(byAdding: .day, value: 7, to: week)! } ?? false) }
            return match
        }.sorted {
            if kind == .event && showHistory { return ($0.date ?? 0) > ($1.date ?? 0) }
            if $0.done != $1.done { return !$0.done }
            if kind == .grocery { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return ($0.date ?? .greatestFiniteMagnitude) < ($1.date ?? .greatestFiniteMagnitude)
        }
    }
    var stores: [String] { Array(Set(values.map { $0.store.trimmingCharacters(in: .whitespaces) })).sorted { a, b in a.isEmpty || (!b.isEmpty && a.localizedStandardCompare(b) == .orderedAscending) } }
    var body: some View {
        NavigationStack {
            List {
                if kind == .bill {
                    Picker("Budget range", selection: $showHistory) {
                        Text("Upcoming").tag(false)
                        Text("Completed").tag(true)
                    }.pickerStyle(.segmented)
                    Text("Track income and expenses by date. Mark an entry received or paid to move a repeating entry to its next date. Overdue entries stay visible until completed.").font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .event {
                    Picker("Calendar range", selection: $showHistory) {
                        Text("Today & upcoming").tag(false)
                        Text("History").tag(true)
                    }.pickerStyle(.segmented)
                    Text("US federal holidays and common observances are included automatically. Holidays are read-only and available offline.").font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .dinner {
                    Section {
                        HStack {
                            Button { week = Calendar.current.date(byAdding: .day, value: -7, to: week)! } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                            Spacer(); Text("Week of \(week.formatted(.dateTime.month(.abbreviated).day()))").font(.subheadline); Spacer()
                            Button { week = Calendar.current.date(byAdding: .day, value: 7, to: week)! } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                        }
                    }
                }
                if kind == .grocery {
                    ForEach(stores, id: \.self) { name in Section(name.isEmpty ? "General" : name) { rows(values.filter { $0.store.trimmingCharacters(in: .whitespaces) == name }) } }
                } else if kind == .dinner {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = Calendar.current.date(byAdding: .day, value: offset, to: week)!
                        Section(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                            let meals = values.filter { $0.when.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
                            rows(meals)
                            if meals.isEmpty { Button("Plan dinner", systemImage: "plus") { var item = Item(kind: .dinner); item.date = day.timeIntervalSince1970; editing = item }.foregroundStyle(.secondary) }
                        }
                    }
                } else { rows(values) }
                if values.isEmpty && kind == .event {
                    ContentUnavailableView(search.isEmpty ? (showHistory ? "No past events" : "No upcoming events") : "No matching events", systemImage: "calendar", description: Text(search.isEmpty ? (showHistory ? "Past events will appear here, newest first." : "Tap + to add an event.") : "Try a different search or calendar range."))
                } else if values.isEmpty && kind != .dinner { ContentUnavailableView("Room for \(kind.title.lowercased())", systemImage: kind.symbol, description: Text("Tap + to add your first item.")) }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle(kind.title).searchable(text: $search)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") { editing = Item(kind: kind) } } }
                .onAppear { calendarToday = Calendar.current.startOfDay(for: Date()) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    calendarToday = Calendar.current.startOfDay(for: Date())
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    calendarToday = Calendar.current.startOfDay(for: Date())
                }
                .refreshable { await store.sync(); if kind == .event { await CalendarBridge.shared.run(store: store) } }
                .sheet(item: $editing) { ItemEditSheet(item: $0) }
                .confirmationDialog("Delete recurring event", isPresented: Binding(get: { deletingEvent != nil }, set: { if !$0 { deletingEvent = nil } })) {
                    if let event = deletingEvent {
                        Button("Delete this occurrence", role: .destructive) { store.remove(event) }
                        Button("Delete entire series", role: .destructive) { store.removeSeries(for: event) }
                    }
                    Button("Cancel", role: .cancel) { deletingEvent = nil }
                }
        }
    }
    @ViewBuilder func rows(_ items: [Item]) -> some View {
        ForEach(items) { item in
            if item.isHoliday { ItemRow(item: item) } else {
            Button { editing = item } label: { ItemRow(item: item) }.buttonStyle(.plain)
                .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) {
                    if item.seriesID != nil { deletingEvent = item } else { store.remove(item) }
                } }
                .swipeActions(edge: .leading) {
                    if kind == .task || kind == .bill || kind == .grocery { Button(kind == .bill ? item.completionLabel : item.done ? "Reopen" : "Done") { store.complete(item) }.tint(.accentColor) }
                }
            }
        }
    }
}
struct MealsView: View {
    var body: some View { ItemList(kind: .dinner) }
}
struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Keep life moving") {
                    NavigationLink { ItemList(kind: .task) } label: { Label("Tasks & reminders", systemImage: "checkmark.circle") }
                    NavigationLink { ItemList(kind: .bill) } label: { Label("Budget", systemImage: "creditcard") }
                    NavigationLink { ItemList(kind: .meal) } label: { Label("Saved meals", systemImage: "book.closed") }
                }
                Section { NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") } }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Household")
        }
    }
}
struct ItemEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let item: Item
    @State private var selected: Item?
    var body: some View {
        if let root = store.series(for: item), item.seriesID != nil, selected == nil {
            NavigationStack {
                List {
                    Section(item.title) {
                        if let when = item.when { Text(when.formatted(date: .abbreviated, time: .shortened)) }
                        Button("Edit this occurrence") { selected = item }
                        Button("Edit entire series") { selected = root }
                    }
                }.navigationTitle("Repeating event")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        } else { ItemEditor(item: selected ?? item) }
    }
}
struct MealLine: Identifiable {
    let id = UUID()
    var text = ""
    static func rows(_ values: [String]) -> [MealLine] {
        values.isEmpty ? [MealLine()] : values.map { MealLine(text: $0) }
    }
}
struct MealLinesSection: View {
    let title: String
    let placeholder: String
    @Binding var lines: [MealLine]
    @FocusState private var focusedLine: UUID?
    var body: some View {
        Section(title) {
            ForEach($lines) { $line in
                HStack {
                    TextField(placeholder, text: $line.text).focused($focusedLine, equals: line.id)
                    Button {
                        let removedID = line.id
                        lines.removeAll { $0.id == removedID }
                        if lines.isEmpty { lines.append(MealLine()) }
                    } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(placeholder.lowercased())")
                }
            }
            Button {
                let line = MealLine(); lines.append(line); focusedLine = line.id
            } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("Add \(placeholder.lowercased())").disabled(lines.count >= 100)
        }
    }
}
struct ItemEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var item: Item
    @State var hasDate = false
    @State var date = Date()
    @State var end = Date(timeIntervalSinceNow: 3600)
    @State var reminder = false
    @State var reminderDate = Date()
    @State var amount = ""
    @State var ingredients = [MealLine()]
    @State var prep = [MealLine()]
    @State var cooking = [MealLine()]
    @State var added = false
    @State private var originalItem: Item?
    @State private var repeatsUntil = false
    @State private var repeatEnd = Date()
    @State private var confirmingDelete = false
    @State private var alertOne = 1
    @State private var alertTwo = 1
    var valid: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title.count <= 300 && item.notes.count <= 10000 && ingredientLines.count <= 100 && ingredientLines.allSatisfy { $0.count <= 300 } && prepLines.count <= 100 && cookingLines.count <= 100 && (prepLines + cookingLines).allSatisfy { $0.count <= 300 } && (item.location?.count ?? 0) <= 1000 && (alertOne == 1 || alertTwo == 1 || alertOne != alertTwo) && item.store.count <= 100 && item.quantity.count <= 100 && (item.kind != .bill || (Decimal(string: amount).map { $0 >= 0 && $0 <= 1000000000 } ?? false) && item.currency.count == 3 && item.currency.allSatisfy { $0.isASCII && $0.isUppercase }) && (item.kind != .event || ((item.allDay ? Calendar.current.startOfDay(for: end) >= Calendar.current.startOfDay(for: date) : end > date) && (!repeatsUntil || item.recurrence == "none" || Calendar.current.startOfDay(for: repeatEnd) >= Calendar.current.startOfDay(for: date))))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("The essentials") {
                    TextField(item.kind == .dinner || item.kind == .meal ? "What’s cooking?" : "Title", text: $item.title)
                    if item.kind == .dinner {
                        Menu("Choose a saved meal") { ForEach(store.items(.meal)) { meal in Button(meal.title) { item.title = meal.title; item.notes = meal.notes; ingredients = MealLine.rows(meal.ingredients); prep = MealLine.rows(meal.prepSteps ?? []); cooking = MealLine.rows(meal.cookingSteps ?? []) } } }
                    }
                    if item.kind == .grocery { TextField("Store · leave empty for General", text: $item.store); TextField("Quantity", text: $item.quantity) }
                    if item.kind == .bill {
                        Picker("Type", selection: Binding(get: { item.budgetType ?? .expense }, set: { item.budgetType = $0 })) {
                            Text("Expense").tag(BudgetType.expense)
                            Text("Income").tag(BudgetType.income)
                        }.pickerStyle(.segmented)
                        TextField("Amount", text: $amount).keyboardType(.decimalPad)
                        TextField("Currency", text: $item.currency).textInputAutocapitalization(.characters)
                    }
                    if item.kind != .meal && item.kind != .grocery {
                        if item.kind == .task { Toggle("Set a date", isOn: $hasDate) }
                        if item.kind == .event {
                            Toggle("All-Day", isOn: $item.allDay).onChange(of: item.allDay) { _, allDay in
                                if allDay { date = Calendar.current.startOfDay(for: date); end = date }
                                else { end = date.addingTimeInterval(3600) }
                            }
                            DatePicker("Starts", selection: startSelection, displayedComponents: item.allDay ? [.date] : [.date, .hourAndMinute])
                            DatePicker("Ends", selection: $end, displayedComponents: item.allDay ? [.date] : [.date, .hourAndMinute])
                            if item.allDay { Text("Ends is the last day of the event.").font(.caption).foregroundStyle(.secondary) }
                        } else if hasDate || item.kind != .task {
                            DatePicker(item.kind == .bill ? (item.isIncome ? "Expected" : "Due") : "Date", selection: startSelection, displayedComponents: item.kind == .task ? [.date, .hourAndMinute] : [.date])
                        }
                    }
                }
                if item.kind == .event {
                    if item.seriesID != nil {
                        Section { Text("Changes apply only to this occurrence.").font(.footnote).foregroundStyle(.secondary) }
                    } else if !item.calendarKey.hasPrefix("native-series:") && item.calendarKey.split(separator: "|").last.flatMap({ Double($0) }) != nil {
                        Section("Repeat") { Text("This Apple Calendar pattern is displayed one occurrence at a time. Change its repeat rule in Apple Calendar.").font(.footnote).foregroundStyle(.secondary) }
                    } else {
                        Section("Repeat") {
                            Picker("Repeat", selection: $item.recurrence) {
                                Text("Never").tag("none"); Text("Daily").tag("daily")
                                Text("Weekly").tag("weekly"); Text("Every 2 weeks").tag("biweekly")
                                Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly"); Text("Custom").tag("custom")
                            }.pickerStyle(.menu)
                            if item.recurrence == "custom" {
                                Picker("Frequency", selection: Binding(get: { item.customFrequency ?? "weekly" }, set: { item.customFrequency = $0 })) {
                                    Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly")
                                }
                                Stepper(customRepeatLabel, value: Binding(get: { item.customInterval ?? 1 }, set: { item.customInterval = $0 }), in: 1...99)
                                if (item.customFrequency ?? "weekly") == "weekly" {
                                    Text("The Starts weekday is always included.").font(.caption).foregroundStyle(.secondary)
                                    ForEach(1...7, id: \.self) { day in
                                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { (item.repeatWeekdays ?? [Calendar.current.component(.weekday, from: date)]).contains(day) }, set: { enabled in
                                            var days = Set(item.repeatWeekdays ?? [Calendar.current.component(.weekday, from: date)])
                                            if enabled { days.insert(day) } else { days.remove(day) }
                                            item.repeatWeekdays = days.sorted()
                                        }))
                                    }
                                }
                            }
                            if item.recurrence != "none" {
                                Toggle("End repeating", isOn: $repeatsUntil)
                                if repeatsUntil { DatePicker("Last day", selection: $repeatEnd, in: Calendar.current.startOfDay(for: date)..., displayedComponents: [.date]) }
                                Text("Repeats in \(item.recurrenceTimeZone ?? TimeZone.current.identifier).").font(.caption).foregroundStyle(.secondary)
                                Text("Repeats at the same local time. Monthly and yearly repeats skip dates that do not exist. Calendar displays last year through two years ahead.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if item.isRecurringSeries && item.revision > 0 {
                                Text("Editing the schedule applies to the entire series and resets individual exceptions. Title and notes edits preserve exceptions.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if item.kind == .event {
                    EventLocationSection(item: $item)
                    Section("Alert") {
                        alertPicker("Alert", selection: $alertOne)
                        alertPicker("Second alert", selection: $alertTwo)
                        Text("Enable Homebase notifications for alerts. This phone uses Apple Calendar alerts for synced events when its calendar bridge is connected.").font(.caption).foregroundStyle(.secondary)
                        if alertOne != 1 && alertOne == alertTwo { Text("Choose two different alert times.").font(.caption).foregroundStyle(.red) }
                    }
                }
                if item.kind == .bill || item.kind == .task {
                    Section("Repeat & remind") {
                        Picker("Repeat", selection: $item.recurrence) { Text("Never").tag("none"); Text("Weekly").tag("weekly"); Text("Every 2 weeks").tag("biweekly"); Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly") }
                        Toggle("Remind us", isOn: $reminder)
                        if reminder { DatePicker("Reminder", selection: $reminderDate) }
                    }
                }
                if item.kind == .dinner || item.kind == .meal {
                    MealLinesSection(title: "Ingredients", placeholder: "Ingredient", lines: $ingredients)
                    MealLinesSection(title: "Prep", placeholder: "Prep step", lines: $prep)
                    MealLinesSection(title: "Cooking", placeholder: "Cooking step", lines: $cooking)
                    if item.revision > 0 {
                        Section {
                            Button(added ? "Added to General" : "Add ingredients to groceries", systemImage: "basket.badge.plus") { var copy = item; copy.ingredients = ingredientLines; store.addIngredients(copy); added = true }.disabled(added || ingredientLines.isEmpty)
                            if item.kind == .dinner { Button("Save as a favorite meal", systemImage: "bookmark") { var meal = Item(kind: .meal); meal.title = item.title; meal.notes = item.notes; meal.ingredients = ingredientLines; meal.prepSteps = prepLines; meal.cookingSteps = cookingLines; store.save(meal) } }
                        }
                    }
                }
                Section(item.kind == .event ? "Details" : "Notes") { TextEditor(text: $item.notes).frame(minHeight: 90) }
                if item.kind == .event && (item.revision > 0 || item.seriesID != nil) {
                    Section { Button(item.isRecurringSeries ? "Delete entire series" : "Delete event", role: .destructive) { confirmingDelete = true } }
                }
                if item.kind == .bill && !item.paidDates.isEmpty { Section(item.isIncome ? "Received history" : "Payment history") { ForEach(item.paidDates.indices, id: \.self) { i in Text(Date(timeIntervalSince1970: item.paidDates[i]), format: .dateTime.year().month().day()) } } }
                if item.revision > 0 && [.task, .bill, .grocery].contains(item.kind) {
                    Section { Button(item.kind == .bill ? (item.done ? "Reopen" : item.isIncome ? "Mark received" : "Mark paid") : item.done ? "Mark incomplete" : "Mark complete") { store.complete(item); dismiss() } }
                }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle(item.revision == 0 && item.seriesID == nil ? "Add \(item.kind == .bill ? "budget event" : item.kind == .grocery ? "grocery" : item.kind.rawValue)" : "Edit \(item.kind == .bill ? "budget event" : item.kind.rawValue)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { commit(); dismiss() }.disabled(!valid) }
                }
                .confirmationDialog(item.isRecurringSeries ? "Delete the entire recurring series?" : "Delete this event?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) { store.remove(item); dismiss() }
                }
                .onAppear {
                    originalItem = item
                    repeatsUntil = item.recurrenceUntil != nil
                    repeatEnd = Date(timeIntervalSince1970: item.recurrenceUntil ?? (item.date ?? Date().timeIntervalSince1970))
                    hasDate = item.date != nil; date = item.when ?? Date(); end = Date(timeIntervalSince1970: item.endDate ?? date.timeIntervalSince1970 + 3600)
                    if item.kind == .event && item.allDay { end = Calendar.current.date(byAdding: .day, value: -1, to: end)! }
                    alertOne = item.alertOffsets?.first ?? 1
                    alertTwo = (item.alertOffsets?.count ?? 0) > 1 ? item.alertOffsets![1] : 1
                    reminder = item.reminderAt != nil; reminderDate = Date(timeIntervalSince1970: item.reminderAt ?? date.timeIntervalSince1970)
                    if let cents = item.amountCents { amount = NSDecimalNumber(decimal: Decimal(cents) / 100).stringValue }
                    ingredients = MealLine.rows(item.ingredients)
                    prep = MealLine.rows(item.prepSteps ?? [])
                    cooking = MealLine.rows(item.cookingSteps ?? [])
                }
        }
    }
    // Only picker edits reset the duration; loading an existing event preserves its saved end.
    var startSelection: Binding<Date> {
        Binding(get: { date }, set: { newStart in
            if item.kind == .event {
                end = item.allDay ? newStart : newStart.addingTimeInterval(3600)
            }
            date = newStart
        })
    }
    var customRepeatLabel: String {
        let count = item.customInterval ?? 1
        let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"][item.customFrequency ?? "weekly"] ?? "week"
        return "Every \(count) \(unit)\(count == 1 ? "" : "s")"
    }
    @ViewBuilder func alertPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(1); Text("At time of event").tag(0)
            Text("5 minutes before").tag(-300); Text("10 minutes before").tag(-600)
            Text("15 minutes before").tag(-900); Text("30 minutes before").tag(-1800)
            Text("1 hour before").tag(-3600); Text("2 hours before").tag(-7200)
            Text("1 day before").tag(-86400); Text("2 days before").tag(-172800); Text("1 week before").tag(-604800)
            if selection.wrappedValue != 1 && ![0,-300,-600,-900,-1800,-3600,-7200,-86400,-172800,-604800].contains(selection.wrappedValue) {
                Text("\(-selection.wrappedValue) seconds before").tag(selection.wrappedValue)
            }
        }
    }
    func cleaned(_ lines: [MealLine]) -> [String] {
        lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var ingredientLines: [String] { cleaned(ingredients) }
    var prepLines: [String] { cleaned(prep) }
    var cookingLines: [String] { cleaned(cooking) }
    func commit() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if [.event, .dinner, .bill].contains(item.kind) || (item.kind == .task && hasDate) { item.date = date.timeIntervalSince1970 } else { item.date = nil }
        if item.kind == .event {
            if item.allDay {
                item.date = Calendar.current.startOfDay(for: date).timeIntervalSince1970
                item.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!.timeIntervalSince1970
            } else { item.endDate = end.timeIntervalSince1970 }
            item.alertOffsets = [alertOne, alertTwo].filter { $0 != 1 }
            if item.seriesID == nil {
                if item.recurrenceTimeZone == nil || originalItem?.date != item.date { item.recurrenceTimeZone = TimeZone.current.identifier }
                let calendar = EventRecurrence.calendar(for: item)
                item.recurrenceUntil = repeatsUntil && item.recurrence != "none" ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: repeatEnd))!.addingTimeInterval(-1).timeIntervalSince1970 : nil
                if item.recurrence == "custom" {
                    item.customFrequency = item.customFrequency ?? "weekly"; item.customInterval = item.customInterval ?? 1
                    if item.customFrequency == "weekly" {
                        var days = Set(item.repeatWeekdays ?? [])
                        days.insert(calendar.component(.weekday, from: Date(timeIntervalSince1970: item.date!)))
                        item.repeatWeekdays = days.sorted()
                    } else { item.repeatWeekdays = nil }
                } else { item.customFrequency = nil; item.customInterval = nil; item.repeatWeekdays = nil }
                if item.recurrence != "none" || originalItem?.isRecurringSeries == true {
                    let changedSchedule = originalItem.map { $0.date != item.date || $0.endDate != item.endDate || $0.allDay != item.allDay || $0.recurrence != item.recurrence || $0.recurrenceUntil != item.recurrenceUntil || $0.customFrequency != item.customFrequency || $0.customInterval != item.customInterval || $0.repeatWeekdays != item.repeatWeekdays } ?? true
                    if item.seriesVersion == nil || changedSchedule { item.seriesVersion = UUID() }
                }
            }
        }
        item.reminderAt = reminder ? reminderDate.timeIntervalSince1970 : nil
        if item.kind == .bill { item.budgetType = item.budgetType ?? .expense }
        if item.kind == .bill, let decimal = Decimal(string: amount) { item.amountCents = NSDecimalNumber(decimal: decimal * 100).intValue }
        item.ingredients = ingredientLines
        if item.kind == .dinner || item.kind == .meal {
            item.prepSteps = prepLines; item.cookingSteps = cookingLines
        }
        store.save(item)
        Task { await store.sync(); await CalendarBridge.shared.run(store: store) }
    }
}
struct ConflictsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            ForEach(store.cache.conflicts) { conflict in
                Section(conflict.local.title) {
                    Text("This item changed on both phones. Choose which version to keep.").font(.subheadline)
                    Text("Your version").font(.headline)
                    conflictDetails(conflict.local)
                    Text("Shared version").font(.headline)
                    conflictDetails(conflict.remote)
                    Button("Keep my version") { store.resolve(conflict, keepMine: true) }
                    Button("Use shared version") { store.resolve(conflict, keepMine: false) }
                }
            }
        }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Review changes")
    }
    @ViewBuilder func conflictDetails(_ item: Item) -> some View {
        ItemRow(item: item)
        if item.deleted { Text("Deleted").foregroundStyle(.red) }
        Text(item.done ? "Completed" : "Open").font(.caption)
        if let end = item.endDate { Text("Ends: \(Date(timeIntervalSince1970: end).formatted())").font(.caption) }
        if let reminder = item.reminderAt { Text("Reminder: \(Date(timeIntervalSince1970: reminder).formatted())").font(.caption) }
        if !item.store.isEmpty { Text("Store: \(item.store)").font(.caption) }
        if item.recurrence != "none" { Text("Repeats \(item.recurrence)").font(.caption) }
        if !item.ingredients.isEmpty { Text(item.ingredients.joined(separator: ", ")).font(.caption) }
        if !item.notes.isEmpty { Text(item.notes).font(.caption) }
    }
}
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @EnvironmentObject var store: Store
    @StateObject var bridge = CalendarBridge.shared
    @State var repairing = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
                Text("System follows your iPhone’s appearance. Your choice is saved on this phone.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                LabeledContent("Status", value: store.status)
                LabeledContent("Pending edits", value: "\(store.cache.queue.count)")
                Text(store.endpoint).font(.caption).textSelection(.enabled)
                Button("Sync now") { Task { await store.sync(); await bridge.run(store: store) } }
                Button("Enable notifications") { Task { await store.registerPush() } }
                Button("Pair this phone again") { repairing = true }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Section("App updates") {
                LabeledContent("Installed", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(store.installedBuild))")
                if !store.releaseStatus.isEmpty { Text(store.releaseStatus).font(.subheadline) }
                Button { Task { await store.checkForUpdate() } } label: {
                    HStack {
                        Text(store.checkingForUpdate ? "Checking…" : "Check for updates")
                        if store.checkingForUpdate { Spacer(); ProgressView() }
                    }
                }.disabled(store.checkingForUpdate)
                if let checkedAt = store.releaseCheckedAt {
                    Text("Last checked \(checkedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let release = store.appRelease {
                    if store.updateAvailable {
                        Text(release.notes).font(.footnote).foregroundStyle(.secondary)
                        Button("Install update in Safari", systemImage: "arrow.down.app") { Task { await store.openInstallPage() } }.disabled(!store.cache.queue.isEmpty || !store.cache.conflicts.isEmpty)
                    }
                    Text("Latest release signing expires \(Date(timeIntervalSince1970: release.expiresAt).formatted(date: .abbreviated, time: .omitted)).").font(.caption).foregroundStyle(.secondary)
                }
                Text("Updates install over the existing app. Sync your edits first, then confirm installation in Safari.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Shared iCloud calendar") {
                Text("Choose your shared iCloud calendar on one phone. Keep the bridge on that phone; both phones see its synced events in Homebase.").font(.footnote)
                Text(bridge.status).font(.subheadline)
                if bridge.selected.isEmpty {
                    Button("Choose calendar") { Task { await bridge.load() } }
                    ForEach(bridge.calendars, id: \.calendarIdentifier) { calendar in Button("\(calendar.title) · \(calendar.source.title)") { Task { await bridge.connect(calendar, store: store) } } }
                } else { Button("Disconnect calendar bridge") { Task { await bridge.disconnect(store: store) } } }
                Text("Ordinary imports cover the past 30 days and next year. Recurring series include last year through two years ahead. iOS controls background refresh; conflicts and missing events are flagged for review.").font(.caption).foregroundStyle(.secondary)
            }
            if !bridge.issues.isEmpty {
                Section("Calendar changes to review") {
                    ForEach(bridge.issues) { issue in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(issue.item.title).font(.headline)
                            Text(issue.message ?? (issue.missing ? "This event is missing from Apple Calendar. It may have been deleted or iCloud may still be syncing." : "This event changed in both Homebase and Apple Calendar.")).font(.caption)
                            Button(issue.missing ? "Restore in Apple Calendar" : "Use Homebase version") { Task { await bridge.resolve(issue, useHomebase: true, store: store) } }.disabled(!issue.allowHome)
                            Button(issue.missing ? "Confirm deletion from Homebase" : "Use Apple Calendar version") { Task { await bridge.resolve(issue, useHomebase: false, store: store) } }.disabled(!issue.allowApple)
                        }
                    }
                }
            }
            Section { NavigationLink("Review sync conflicts") { ConflictsView() } }
            Section { Text("Homebase\nA shared place for everyday life.").foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Settings").sheet(isPresented: $repairing) { PairView() }
    }
}
