import SwiftUI
import UIKit
import WebKit
import Darwin

// ============================================================================
// App 入口 + 底部导航（首页 / 内置雷达）+ 方向管理
// 首页锁竖屏；内置雷达页强制横屏（可左右旋转），内嵌浏览转发器雷达地址。
// ============================================================================

/// 全局方向锁：AppDelegate 按它决定支持的屏幕方向
enum ScreenOrientation {
    static var mask: UIInterfaceOrientationMask = .portrait
}

@main
struct StarRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 应用代理：保持屏幕常亮 + 前台运行；并按 ScreenOrientation.mask 响应旋转
final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationDidFinishLaunching(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
        // 忽略 SIGPIPE：转发连接任一端断开时写 socket 不再直接杀死进程
        signal(SIGPIPE, SIG_IGN)
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return ScreenOrientation.mask
    }
}

/// 切换全局方向并触发旋转
private func applyOrientation(_ mask: UIInterfaceOrientationMask, force: UIInterfaceOrientation?) {
    ScreenOrientation.mask = mask
    if let o = force {
        UIDevice.current.setValue(o.rawValue, forKey: "orientation")
    }
    UIViewController.attemptRotationToDeviceOrientation()
}

/// 底部导航：Tab 0 = 首页（全部转发功能），Tab 1 = 内置雷达（横屏浏览）
struct RootTabView: View {
    @SwiftUI.State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            RadarTabPage()
                .tabItem { Label("内置雷达", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)
        }
        .onChange(of: tab) { v in
            if v == 1 {
                // 内置雷达：跟随设备方向自由旋转（横竖都行，不锁死）
                applyOrientation(.allButUpsideDown, force: nil)
            } else {
                applyOrientation(.portrait, force: .portrait)
            }
        }
        .onAppear { applyOrientation(.portrait, force: .portrait) }
    }
}

// MARK: - 内置雷达页（横屏内嵌浏览器）

private let radarURL = URL(string: "http://192.140.167.247:666/")!

/// 供刷新按钮持有的 WebView 引用
private final class WebBox {
    weak var web: WKWebView?
}

private struct RadarWebView: UIViewRepresentable {
    let url: URL
    let box: WebBox

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        box.web = w
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct RadarTabPage: View {
    @SwiftUI.State private var box = WebBox()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "radar")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 64 / 255, green: 160 / 255, blue: 255 / 255))
                Text("内置雷达")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(radarURL.absoluteString)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button {
                    box.web?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 24 / 255, green: 26 / 255, blue: 34 / 255))

            RadarWebView(url: radarURL, box: box)
        }
        .background(Color(red: 18 / 255, green: 22 / 255, blue: 32 / 255))
        .onAppear {
            // 跟随设备方向旋转；若设备正横放则 attemptRotation 会立即转横
            applyOrientation(.allButUpsideDown, force: nil)
        }
        .onDisappear {
            applyOrientation(.portrait, force: .portrait)
        }
    }
}
