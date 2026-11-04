import Foundation
import Security
import SwiftUI
import UserNotifications

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum Keychain {
    static let service = "xyz.hauptsec.homebase"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let existing = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if existing == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw APIError(message: "Could not securely save the device credential.") }
        } else if existing != errSecSuccess { throw APIError(message: "Could not update the device credential.") }
    }
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var cache = Cache()
    @Published var paired = Keychain.read() != nil
    @Published var status = "Ready"
    @Published var error: String?
    @Published var syncing = false
    @Published var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "https://homebase.hauptsec.xyz"
    private var liveTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let file: URL
    private var cacheHealthy = true
    #if DEBUG
    let demo = ProcessInfo.processInfo.arguments.contains("--preview")
    #else
    let demo = false
    #endif
    init() {
        file = URL.applicationSupportDirectory.appendingPathComponent("homebase-cache.json")
        if demo {
            paired = true
            var dinner = Item(kind: .dinner); dinner.title = "Lemon chicken & roasted vegetables"; dinner.date = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date())!.timeIntervalSince1970; dinner.notes = "An easy evening at home"
            var task = Item(kind: .task); task.title = "Book the weekend getaway"; task.date = Date().timeIntervalSince1970
            var bill = Item(kind: .bill); bill.title = "Internet"; bill.date = Date().timeIntervalSince1970; bill.amountCents = 6500; bill.recurrence = "monthly"
            var grocery = Item(kind: .grocery); grocery.title = "Fresh lemons"; grocery.quantity = "3"; grocery.store = "Trader Joe’s"
            cache.items = [dinner, task, bill, grocery]; status = "Preview · sample household"
            return
        }
        if FileManager.default.fileExists(atPath: file.path) {
            do { cache = try decoder.decode(Cache.self, from: Data(contentsOf: file)) }
            catch { cacheHealthy = false; self.error = "The local cache could not be read. It has been preserved; do not reinstall if you have unsynced edits." }
        }
    }
    var items: [Item] { cache.items.filter { !$0.deleted } }
    func items(_ kind: Kind) -> [Item] {
        items.filter { $0.kind == kind }.sorted {
            if $0.done != $1.done { return !$0.done }
            if kind == .grocery { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return ($0.date ?? .greatestFiniteMagnitude) < ($1.date ?? .greatestFiniteMagnitude)
        }
    }
    @discardableResult func persist() -> Bool {
        if demo { return true }
        guard cacheHealthy else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(cache).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { self.error = "Could not save offline changes: \(error.localizedDescription)"; return false }
    }
    func upsert(_ item: Item) {
        if let i = cache.items.firstIndex(where: { $0.id == item.id }) { cache.items[i] = item }
        else { cache.items.append(item) }
    }
    func save(_ item: Item) {
        guard cacheHealthy else { return }
        upsert(item)
        // Queue every edit; never change an in-flight request's idempotency key or body.
        cache.queue.append(Mutation(baseRevision: item.revision, item: item))
        if persist() { Task { await sync() } }
    }
    func remove(_ item: Item) { var copy = item; copy.deleted = true; save(copy) }
    func complete(_ item: Item) { var copy = item; copy.complete(); save(copy) }
    func addIngredients(_ item: Item) {
        for name in item.ingredients where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            var grocery = Item(kind: .grocery); grocery.title = name; save(grocery)
        }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) throws -> URLRequest {
        guard let base = URL(string: endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw APIError(message: "Enter a valid HTTPS server address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = Keychain.read() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    func checked(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "Invalid server response") }
        if http.statusCode == 401 { throw APIError(message: "This device is no longer authorized. Pair it again in Settings.") }
        guard (200..<300).contains(http.statusCode) else { throw APIError(message: "Server returned \(http.statusCode). Your changes remain saved on this phone.") }
    }
    func pair(code: String, name: String) async throws {
        let body = try encoder.encode(["code": code.trimmingCharacters(in: .whitespacesAndNewlines), "name": name])
        let (data, response) = try await URLSession.shared.data(for: request("/v1/pair", method: "POST", body: body, authenticated: false))
        try checked(response)
        let result = try decoder.decode(PairResult.self, from: data)
        try Keychain.save(result.token)
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        UserDefaults.standard.set(result.deviceId, forKey: "deviceId")
        paired = true
        await sync(); startLive()
        await registerPush()
    }
    func sync() async {
        guard !demo, paired, !syncing, cacheHealthy else { return }
        syncing = true; status = "Syncing…"
        defer { syncing = false }
        do {
            guard persist() else { return }
            // A conflict blocks subsequent edits to that item, not the rest of the household.
            while let queued = cache.queue.first(where: { q in !cache.conflicts.contains(where: { $0.id == q.item.id }) }) {
                let (data, response) = try await URLSession.shared.data(for: request("/v1/mutations", method: "POST", body: encoder.encode(queued)))
                if (response as? HTTPURLResponse)?.statusCode == 409 {
                    let conflict = try decoder.decode(ConflictEnvelope.self, from: data)
                    if let remote = conflict.detail.current {
                        let latest = cache.items.first { $0.id == queued.item.id } ?? queued.item
                        cache.conflicts.append(Conflict(local: latest, remote: remote))
                        guard persist() else { return }
                        continue
                    }
                }
                try checked(response)
                let result = try decoder.decode(MutationResult.self, from: data).item
                cache.queue.removeAll { $0.id == queued.id }
                if let next = cache.queue.firstIndex(where: { $0.item.id == result.id }) {
                    cache.queue[next].baseRevision = result.revision
                } else { upsert(result) }
                guard persist() else { return }
            }
            var more = true
            while more {
                let (data, response) = try await URLSession.shared.data(for: request("/v1/sync?after=\(cache.cursor)"))
                try checked(response)
                let page = try decoder.decode(SyncPage.self, from: data)
                for item in page.items where !cache.queue.contains(where: { $0.item.id == item.id }) && !cache.conflicts.contains(where: { $0.id == item.id }) { upsert(item) }
                cache.cursor = page.cursor; more = page.hasMore
                guard persist() else { return }
            }
            status = cache.conflicts.isEmpty ? "Up to date" : "Changes need review"
        } catch { status = "Offline · \(cache.queue.count) pending"; self.error = error.localizedDescription }
    }
    func resolve(_ conflict: Conflict, keepMine: Bool) {
        cache.queue.removeAll { $0.item.id == conflict.id }
        cache.conflicts.removeAll { $0.id == conflict.id }
        if keepMine {
            var item = conflict.local; item.revision = conflict.remote.revision
            save(item)
        } else { upsert(conflict.remote); if persist() { Task { await sync() } } }
    }
    func startLive() {
        guard !demo, paired, liveTask == nil else { return }
        liveTask = Task {
            while !Task.isCancelled {
                do {
                    guard let token = Keychain.read() else { return }
                    let request = try request("/v1/live")
                    var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    parts.scheme = "wss"
                    let ws = URLSession.shared.webSocketTask(with: parts.url!)
                    socket = ws; ws.resume()
                    let hello = String(data: try encoder.encode(["token": token]), encoding: .utf8)!
                    try await ws.send(.string(hello))
                    while !Task.isCancelled { _ = try await ws.receive(); await sync() }
                } catch {
                    socket?.cancel(with: .goingAway, reason: nil)
                    if !Task.isCancelled { await sync(); try? await Task.sleep(for: .seconds(15)) }
                }
            }
        }
    }
    func stopLive() { liveTask?.cancel(); liveTask = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
    func registerPush() async {
        guard !demo else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            if let token = UserDefaults.standard.string(forKey: "pushToken") { await uploadPush(token) }
        } catch { self.error = error.localizedDescription }
    }
    func uploadPush(_ token: String) async {
        guard paired else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            let (_, response) = try await URLSession.shared.data(for: request("/v1/push", method: "POST", body: encoder.encode(["token": token, "environment": environment])))
            try checked(response)
        } catch { self.error = "Push registration: \(error.localizedDescription)" }
    }
}
