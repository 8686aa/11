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
        // 首页启动校验通过 -> 自动切到内置雷达 Tab（地址由 RadarTabPage 自己加载）
        .onReceive(RadarRouter.shared.$request.compactMap { $0 }) { _ in
            tab = 1
        }
        .onAppear { applyOrientation(.portrait, force: .portrait) }
    }
}

// MARK: - 内置雷达页（横屏内嵌浏览器）

/// 地址栏默认值；用户可在界面上改成任意链接，改动后持久化到 UserDefaults
private let radarDefaultURL = "http://192.140.167.247:666"

// MARK: - 启动校验通过后要打开的雷达地址

/// 一次「打开雷达」请求。每次都用新的 id，保证同一地址重复打开也能触发 onChange。
struct RadarOpenRequest: Equatable {
    let id = UUID()
    let url: String
}

/// 首页(AppModel)在 key 校验通过后调用 open(_:)；内置雷达 Tab 加载该地址，
/// RootTabView 同时切到该 Tab —— 两者各自监听同一个发布者，不依赖调用顺序。
final class RadarRouter: ObservableObject {
    static let shared = RadarRouter()
    @Published var request: RadarOpenRequest?
    private init() {}
    func open(_ url: String) { request = RadarOpenRequest(url: url) }
}

/// 供刷新按钮持有的 WebView 引用
private final class WebBox {
    weak var web: WKWebView?
}

private struct RadarWebView: UIViewRepresentable {
    let url: URL
    let box: WebBox

    final class Coordinator {
        /// 记录已加载的地址，用于区分「地址栏变更」和「SwiftUI 例行刷新」
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        box.web = w
        context.coordinator.loadedURL = url
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 只有地址栏真的改过才重新加载，否则每次界面刷新都会把页面重载一遍
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        uiView.load(URLRequest(url: url))
    }
}

struct RadarTabPage: View {
    @SwiftUI.State private var box = WebBox()
    /// 地址栏文本（持久化：重启后仍是上次填写的地址）
    @AppStorage("radar_url") private var urlText: String = radarDefaultURL
    /// 当前已加载的地址
    @SwiftUI.State private var url = URL(string: radarDefaultURL)!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "radar")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 64 / 255, green: 160 / 255, blue: 255 / 255))
                TextField("http://IP:666/", text: $urlText)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { go() }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.17)))
                Button {
                    go()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(Color(red: 64 / 255, green: 160 / 255, blue: 255 / 255))
                }
                Button {
                    box.web?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 24 / 255, green: 26 / 255, blue: 34 / 255))

            RadarWebView(url: url, box: box)
        }
        .background(Color(red: 18 / 255, green: 22 / 255, blue: 32 / 255))
        .onAppear {
            // 跟随设备方向旋转；若设备正横放则 attemptRotation 会立即转横
            applyOrientation(.allButUpsideDown, force: nil)
            // TabView 的子页可能在切到该 Tab 时才构建，此时 onReceive 收不到已发出的请求，这里补一次
            if let req = RadarRouter.shared.request { open(req) }
        }
        // 首页启动校验通过 -> 直接把本页地址栏换成该 key 的分享链接并加载
        .onReceive(RadarRouter.shared.$request.compactMap { $0 }) { req in
            open(req)
        }
        .onDisappear {
            applyOrientation(.portrait, force: .portrait)
        }
    }

    /// 地址栏提交：未带协议头时自动补 http://
    private func go() {
        var t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") {
            t = "http://" + t
        }
        guard let u = URL(string: t), u.host != nil else { return }
        urlText = u.absoluteString   // 回填规范化后的地址
        url = u
    }

    /// 载入外部请求的雷达地址（来自首页启动校验通过后推送的分享链接）
    private func open(_ req: RadarOpenRequest) {
        guard let u = URL(string: req.url), u.host != nil else { return }
        urlText = u.absoluteString
        url = u
    }
}
