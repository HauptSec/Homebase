import SwiftUI
import BackgroundTasks
import UserNotifications
import EventKit

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "xyz.hauptsec.homebase.refresh", using: nil) { task in
            Task { @MainActor in
                let work = Task { await Store.shared.sync(); await CalendarBridge.shared.run(store: Store.shared); Self.schedule(); task.setTaskCompleted(success: !Task.isCancelled) }
                task.expirationHandler = { work.cancel() }
            }
        }
        return true
    }
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: "xyz.hauptsec.homebase.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let text = token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(text, forKey: "pushToken")
        Task { await Store.shared.uploadPush(text) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Store.shared.error = "Push notifications: \(error.localizedDescription)"
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { await Store.shared.sync(); completionHandler(.newData) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
@main struct HomebaseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Color("AccentColor"))
                .task { if store.paired { await store.sync(); store.startLive(); await store.registerPush(); await CalendarBridge.shared.run(store: store) } }
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        await store.sync()
                        await CalendarBridge.shared.run(store: store)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    Task { await CalendarBridge.shared.run(store: store) }
                }
                .onChange(of: phase) { _, value in
                    if value == .active { store.startLive(); Task { await store.sync(); await CalendarBridge.shared.run(store: store) } }
                    else if value == .background { store.stopLive(); AppDelegate.schedule() }
                }
        }
    }
}
