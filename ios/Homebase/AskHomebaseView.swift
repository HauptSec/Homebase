import SwiftUI
import AppIntents

struct AskHomebaseView: View {
    @State private var question = ""
    @State private var answer = ""
    @State private var working = false
    var body: some View {
        Form {
            Section("Ask about your household") {
                TextField("What would you like to know?", text: $question, axis: .vertical).lineLimit(2...6)
                Button {
                    working = true; answer = ""
                    Task {
                        do { answer = try await HomebaseQuestions.answer(question) }
                        catch { answer = error.localizedDescription }
                        working = false
                    }
                } label: {
                    HStack { Text(working ? "Looking up your records…" : "Ask Homebase"); if working { Spacer(); ProgressView() } }
                }.disabled(working || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !answer.isEmpty { Section("Answer") { Text(answer).textSelection(.enabled) } }
            Section("Siri") {
                Text("Say “Ask Homebase”, then ask your question in your own words. You don’t need to set up a list of questions.")
                Text("You can also ask Siri to add a shopping item, plan dinner, add a calendar event or task, or update an item in Homebase.")
                ShortcutsLink()
            }
            Section {
                Text("Open-ended answers use Apple Intelligence on this device and need iOS 26 or later with Apple Intelligence enabled. Answers are based on saved Homebase records and may be incomplete or mistaken. The question feature never edits items.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Ask Homebase")
    }
}
