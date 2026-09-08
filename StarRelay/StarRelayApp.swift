import SwiftUI
import UIKit

@main
struct StarRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 应用代理：中转机需保持屏幕常亮 + 前台运行（iOS 无后台常驻机制）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationDidFinishLaunching(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
    }
}
