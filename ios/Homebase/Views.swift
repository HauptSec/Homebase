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
    var today: [Item] {
        store.items.filter { item in
            guard !item.done, item.kind != .meal, item.kind != .grocery, let when = item.when else { return false }
            if item.isHoliday { return Calendar.current.isDateInToday(when) }
            return Calendar.current.isDateInToday(when) || when < Date()
        }.sorted { ($0.date ?? 0) < ($1.date ?? 0) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()).font(.caption).tracking(1.5).foregroundStyle(.secondary)
                        Text("Welcome home.").font(.system(size: 34, weight: .medium, design: .serif))
                        Text(today.isEmpty ? "A little breathing room today." : "Your day, a little more together.").foregroundStyle(.secondary)
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
                Section("Today & overdue") {
                    if today.isEmpty { ContentUnavailableView("Nothing pressing", systemImage: "sun.horizon", description: Text("Add a plan or enjoy a clear day.")) }
                    ForEach(today) { item in
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
                .sheet(item: $editing) { ItemEditor(item: $0) }
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
                if item.allDay { Text("All day").font(.caption).foregroundStyle(.secondary) }
                if !item.quantity.isEmpty { Text(item.quantity).font(.caption).foregroundStyle(.secondary) }
                if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let cents = item.amountCents { Text(Double(cents) / 100, format: .currency(code: item.currency)).font(.subheadline).monospacedDigit() }
        }.padding(.vertical, 6)
    }
}
struct ItemList: View {
    @EnvironmentObject var store: Store
    let kind: Kind
    @State var editing: Item?
    @State var search = ""
    @State var week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start
    var values: [Item] {
        store.items(kind).filter { item in
            let match = search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.notes.localizedCaseInsensitiveContains(search)
            if kind == .dinner { return match && (item.when.map { $0 >= week && $0 < Calendar.current.date(byAdding: .day, value: 7, to: week)! } ?? false) }
            return match
        }
    }
    var stores: [String] { Array(Set(values.map { $0.store.trimmingCharacters(in: .whitespaces) })).sorted { a, b in a.isEmpty || (!b.isEmpty && a.localizedStandardCompare(b) == .orderedAscending) } }
    var body: some View {
        NavigationStack {
            List {
                if kind == .event {
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
                if values.isEmpty && kind != .dinner { ContentUnavailableView("Room for \(kind.title.lowercased())", systemImage: kind.symbol, description: Text("Tap + to add your first item.")) }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle(kind.title).searchable(text: $search)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") { editing = Item(kind: kind) } } }
                .refreshable { await store.sync(); if kind == .event { await CalendarBridge.shared.run(store: store) } }
                .sheet(item: $editing) { ItemEditor(item: $0) }
        }
    }
    @ViewBuilder func rows(_ items: [Item]) -> some View {
        ForEach(items) { item in
            if item.isHoliday { ItemRow(item: item) } else {
            Button { editing = item } label: { ItemRow(item: item) }.buttonStyle(.plain)
                .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { store.remove(item) } }
                .swipeActions(edge: .leading) {
                    if kind == .task || kind == .bill || kind == .grocery { Button(kind == .bill ? "Paid" : item.done ? "Reopen" : "Done") { store.complete(item) }.tint(.accentColor) }
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
                    NavigationLink { ItemList(kind: .bill) } label: { Label("Bills", systemImage: "creditcard") }
                    NavigationLink { ItemList(kind: .meal) } label: { Label("Saved meals", systemImage: "book.closed") }
                }
                Section { NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") } }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Household")
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
    @State var ingredients = ""
    @State var added = false
    var valid: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title.count <= 300 && item.notes.count <= 10000 && ingredientLines.count <= 100 && ingredientLines.allSatisfy { $0.count <= 300 } && item.store.count <= 100 && item.quantity.count <= 100 && (item.kind != .bill || (Decimal(string: amount).map { $0 >= 0 && $0 <= 1000000000 } ?? false) && item.currency.count == 3 && item.currency.allSatisfy { $0.isASCII && $0.isUppercase }) && (item.kind != .event || end > date)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("The essentials") {
                    TextField(item.kind == .dinner || item.kind == .meal ? "What’s cooking?" : "Title", text: $item.title)
                    if item.kind == .dinner {
                        Menu("Choose a saved meal") { ForEach(store.items(.meal)) { meal in Button(meal.title) { item.title = meal.title; item.notes = meal.notes; ingredients = meal.ingredients.joined(separator: "\n") } } }
                    }
                    if item.kind == .grocery { TextField("Store · leave empty for General", text: $item.store); TextField("Quantity", text: $item.quantity) }
                    if item.kind == .bill { TextField("Amount", text: $amount).keyboardType(.decimalPad); TextField("Currency", text: $item.currency).textInputAutocapitalization(.characters) }
                    if item.kind != .meal && item.kind != .grocery {
                        if item.kind == .task { Toggle("Set a date", isOn: $hasDate) }
                        if hasDate || item.kind != .task { DatePicker(item.kind == .bill ? "Due" : "Date", selection: $date, displayedComponents: item.kind == .event || item.kind == .task ? [.date, .hourAndMinute] : [.date]) }
                        if item.kind == .event { Toggle("All-day event", isOn: $item.allDay); DatePicker("Ends", selection: $end) }
                    }
                }
                if item.kind == .bill || item.kind == .task {
                    Section("Repeat & remind") {
                        Picker("Repeat", selection: $item.recurrence) { Text("Never").tag("none"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly") }
                        Toggle("Remind us", isOn: $reminder)
                        if reminder { DatePicker("Reminder", selection: $reminderDate) }
                    }
                }
                if item.kind == .dinner || item.kind == .meal {
                    Section("Ingredients · one per line") { TextEditor(text: $ingredients).frame(minHeight: 100) }
                    if item.revision > 0 {
                        Section {
                            Button(added ? "Added to General" : "Add ingredients to groceries", systemImage: "basket.badge.plus") { var copy = item; copy.ingredients = ingredientLines; store.addIngredients(copy); added = true }.disabled(added || ingredientLines.isEmpty)
                            if item.kind == .dinner { Button("Save as a favorite meal", systemImage: "bookmark") { var meal = Item(kind: .meal); meal.title = item.title; meal.notes = item.notes; meal.ingredients = ingredientLines; store.save(meal) } }
                        }
                    }
                }
                Section("Notes") { TextEditor(text: $item.notes).frame(minHeight: 90) }
                if item.kind == .bill && !item.paidDates.isEmpty { Section("Payment history") { ForEach(item.paidDates.indices, id: \.self) { i in Text(Date(timeIntervalSince1970: item.paidDates[i]), format: .dateTime.year().month().day()) } } }
                if item.revision > 0 && [.task, .bill, .grocery].contains(item.kind) {
                    Section { Button(item.kind == .bill ? "Mark paid" : item.done ? "Mark incomplete" : "Mark complete") { store.complete(item); dismiss() } }
                }
            }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle(item.revision == 0 ? "Add \(item.kind == .grocery ? "grocery" : item.kind.rawValue)" : "Edit \(item.kind.rawValue)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { commit(); dismiss() }.disabled(!valid) }
                }
                .onAppear {
                    hasDate = item.date != nil; date = item.when ?? Date(); end = Date(timeIntervalSince1970: item.endDate ?? date.timeIntervalSince1970 + 3600)
                    reminder = item.reminderAt != nil; reminderDate = Date(timeIntervalSince1970: item.reminderAt ?? date.timeIntervalSince1970)
                    if let cents = item.amountCents { amount = NSDecimalNumber(decimal: Decimal(cents) / 100).stringValue }
                    ingredients = item.ingredients.joined(separator: "\n")
                }
        }
    }
    var ingredientLines: [String] { ingredients.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func commit() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if [.event, .dinner, .bill].contains(item.kind) || (item.kind == .task && hasDate) { item.date = date.timeIntervalSince1970 } else { item.date = nil }
        if item.kind == .event { item.endDate = end.timeIntervalSince1970 }
        item.reminderAt = reminder ? reminderDate.timeIntervalSince1970 : nil
        if item.kind == .bill, let decimal = Decimal(string: amount) { item.amountCents = NSDecimalNumber(decimal: decimal * 100).intValue }
        item.ingredients = ingredientLines
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
    @EnvironmentObject var store: Store
    @StateObject var bridge = CalendarBridge.shared
    @State var repairing = false
    var body: some View {
        Form {
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
                Button("Check for updates") { Task { await store.checkForUpdate() } }
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
                Text("Sync covers the past 30 days and next year. iOS decides when background refresh runs. Calendar conflicts or missing events are flagged for review.").font(.caption).foregroundStyle(.secondary)
            }
            if !bridge.issues.isEmpty {
                Section("Calendar changes to review") {
                    ForEach(bridge.issues) { issue in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(issue.item.title).font(.headline)
                            Text(issue.missing ? "This event is missing from Apple Calendar. It may have been deleted or iCloud may still be syncing." : "This event changed in both Homebase and Apple Calendar.").font(.caption)
                            Button(issue.missing ? "Restore in Apple Calendar" : "Use Homebase version") { Task { await bridge.resolve(issue, useHomebase: true, store: store) } }
                            Button(issue.missing ? "Confirm deletion from Homebase" : "Use Apple Calendar version") { Task { await bridge.resolve(issue, useHomebase: false, store: store) } }
                        }
                    }
                }
            }
            Section { NavigationLink("Review sync conflicts") { ConflictsView() } }
            Section { Text("Homebase\nA shared place for everyday life.").foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden).background(Color("Canvas")).navigationTitle("Settings").sheet(isPresented: $repairing) { PairView() }
    }
}
