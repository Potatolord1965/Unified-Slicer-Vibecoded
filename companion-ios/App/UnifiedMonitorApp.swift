import SwiftUI
import UIKit
import UnifiedCore
import UserNotifications

@main
struct UnifiedMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.settings)
                .onOpenURL { AppModel.shared.handle($0) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: AppModel.shared.startLive()
            case .background: AppModel.shared.stopLive()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskId)) {
            await AppModel.shared.backgroundCheck()
            await AppModel.shared.scheduleBackgroundCheck()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
            TransitionNotifier.requestPermission()
        }
        return true
    }

    /// Shows the notification even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Opens the printer a tapped notification is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo[TransitionNotifier.printerKey] as? String
        Task { @MainActor in
            if let key { AppModel.shared.openPrinter(key) }
            completionHandler()
        }
    }
}
