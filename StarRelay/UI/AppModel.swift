import Foundation
import SwiftUI

/// 后台转发器连接测速探针：测 ws 握手延迟（最多 timeout 秒），完成后回调 (ok, ms)。
private final class WsProbe: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let onDone: (Bool, Int64) -> Void
    private let started = Date()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timeoutWork: DispatchWorkItem?
    private let lock = NSLock()
    private var finished = false

    init(url: URL, onDone: @escaping (Bool, Int64) -> Void) {
        self.url = url
        self.onDone = onDone
        super.init()
    }

    func run(timeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: config, delegate: self, delegateQueue: q)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        let work = DispatchWorkItem { [weak self] in self?.finish(ok: false) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        finish(ok: true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(ok: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(ok: false)
    }

    private func finish(ok: Bool) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        timeoutWork?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        let ms = Int64(Date().timeIntervalSince(started) * 1000)
        onDone(ok, ms)
    }
}

/// 主界面状态/编排：等效安卓 MainActivity（服务器IP输入 + 自动测速 + 启停）。
final class AppModel: ObservableObject {
    @Published var serverHost = ServerPreset.defaultHost   // 服务器 IP：仅此一项可改，端口固定
    @Published var apiKeyText = ""
    @Published var portText = "1080"
    @Published var uiTick = 0               // 每秒/状态变更自增，驱动 UI 刷新

    private var server = ServerPreset(host: ServerPreset.defaultHost)
    private var socks: Socks5Server?
    private var uploader: WsUploader?
    private var probe: WsProbe?
    private var testTimer: Timer?

    var running: Bool { State.shared.running }

    init() {
        let d = UserDefaults.standard
        apiKeyText = d.string(forKey: "api_key") ?? ""
        portText = d.string(forKey: "port") ?? "1080"
        let host = d.string(forKey: "server_host") ?? ServerPreset.defaultHost
        serverHost = host
        server = ServerPreset(host: host)
    }

    // MARK: - 每秒 UI tick（等效安卓 poller）
    func onSecondTick() {
        FlowHub.shared.tick()
        // WiFi 变化时及时刷新提示里的本机 IP
        if !running || State.shared.localIp.isEmpty {
            State.shared.setLocalIp(localIPAddress())
        }
        uiTick &+= 1
    }

    func viewDidAppear() {
        State.shared.setLocalIp(localIPAddress())
        scheduleAutoTest(immediate: true)
    }

    func viewDidDisappear() {
        testTimer?.invalidate()
        testTimer = nil
    }

    // MARK: - 服务器 IP（端口固定，仅 IP 可改）
    /// 输入框每次变化都会调到这里：换了 IP 就重建服务器对象并清掉旧测速结果。
    func setServerHost(_ text: String) {
        serverHost = text
        let host = text.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(host, forKey: "server_host")
        guard !running, host != server.host else { return }
        server = ServerPreset(host: host)
        State.shared.setLatMs(-1)
        scheduleAutoTest(immediate: true)   // 重新测速（0.3s 后触发，等于按输入停顿去抖）
        uiTick &+= 1
    }

    func currentServer() -> ServerPreset { server }

    /// 状态行使用的延迟文案：测速中（未出结果）→ 具体延迟 → 离线
    func latLabel() -> String {
        let p = currentServer()
        if p.latMs >= 0 { return formatLat(p.latMs) }
        return probe == nil ? "离线" : "测速中…"
    }

    // MARK: - 自动测速（仅未启动时循环：10s 测当前 IP，结果挂在服务器对象上；等效安卓 testSelectedServer）
    func scheduleAutoTest(immediate: Bool) {
        guard !running else { return }
        testTimer?.invalidate()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.autoTest()
        }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
        if immediate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.autoTest() }
        }
    }

    func autoTest() {
        guard !running, probe == nil else { return }
        let preset = currentServer()
        guard let u = URL(string: preset.url), let h = u.host, !h.isEmpty else {
            preset.latMs = -1
            State.shared.setLatMs(-1)
            uiTick &+= 1
            return
        }
        let p = WsProbe(url: u) { [weak self] ok, ms in
            DispatchQueue.main.async { self?.applyTest(ok: ok, ms: ms) }
        }
        probe = p
        p.run()
    }

    private func applyTest(ok: Bool, ms: Int64) {
        probe = nil
        server.latMs = ok ? ms : -1
        State.shared.setLatMs(ok ? ms : -1)
        uiTick &+= 1
    }

    // MARK: - 启停（等效安卓 doStart / doStop）
    func start() {
        guard !running else { return }
        let preset = currentServer()
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 1080
        let apiKey = apiKeyText.trimmingCharacters(in: .whitespaces)

        // 服务器 IP 由用户手填，空/非法时直接拦下，避免拼出 ws://:1082 这种地址
        guard !preset.host.isEmpty, URL(string: preset.url)?.host?.isEmpty == false else {
            State.shared.setLastError("请先填写服务器IP（端口固定 1082）")
            State.shared.log("启动中止：服务器IP 为空")
            uiTick &+= 1
            return
        }

        UserDefaults.standard.set(apiKey, forKey: "api_key")
        UserDefaults.standard.set(String(port), forKey: "port")

        State.shared.setListenPort(port)
        State.shared.setLocalIp(localIPAddress())
        FlowHub.shared.clear()
        State.shared.log("=== 启动（转发器 \(preset.url)，端口 \(port)）===")

        let up = WsUploader(urlString: preset.url, apiKey: apiKey) { State.shared.log($0) }
        uploader = up
        up.start()

        let s = Socks5Server(port: port,
                             onPacket: { upPkt, proto, srcIp, sport, dstIp, dport, payload in
            if upPkt {
                State.shared.addUp(bytes: payload.count)
            } else {
                State.shared.addDown(bytes: payload.count)
            }
            // 拓扑：客户端 = SOCKS5 调用方(小火箭)，对端 = 它访问的来源IP
            let client = upPkt ? srcIp : dstIp
            let remote = upPkt ? dstIp : srcIp
            let rport = upPkt ? dport : sport
            FlowHub.shared.report(phone: client, remoteIp: remote, remotePort: rport,
                                  up: upPkt, bytes: payload.count)
            let pkt = IpPacket.wrap(proto: proto, srcIp: srcIp, dstIp: dstIp,
                                    sport: sport, dport: dport, payload: payload)
            up.enqueueIp(pkt)
        },
                             onClientActive: { FlowHub.shared.touchClient($0) },
                             log: { State.shared.log($0) })
        socks = s
        if s.start() {
            State.shared.setRunning(true)
            State.shared.setLastError("")
            testTimer?.invalidate()
            testTimer = nil
            State.shared.log("提示：小火箭 SOCKS5 = \(State.shared.localIp):\(port)")
            openRadarPage(preset: preset, apiKey: apiKey)
        } else {
            State.shared.setRunning(false)
            State.shared.setLastError("SOCKS5 未启动：端口 \(port) 监听失败，请改端口或看下方日志的 errno")
            up.stop()
            uploader = nil
        }
        uiTick &+= 1
    }

    // MARK: - 启动后校验 key → 让内置雷达 Tab 打开该 key 对应的分享页
    // 转发器(ws://host:1082)与雷达服务(http://host:666)同机同 IP，地址由 ServerPreset 换算。
    private func openRadarPage(preset: ServerPreset, apiKey: String) {
        guard !apiKey.isEmpty else {
            State.shared.log("[雷达] 房间Key 为空（调试房间），不自动打开雷达页")
            return
        }
        guard let url = preset.shareByKeyURL(apiKey: apiKey) else {
            State.shared.log("[雷达] 无法从 \(preset.url) 推导雷达服务地址，跳过自动打开")
            return
        }
        State.shared.log("[雷达] 校验 key …")
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, error in
            var link: String?
            var message: String
            if let error = error {
                message = "校验失败：\(error.localizedDescription)"
            } else if let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if (obj["ok"] as? Bool) == true, let text = obj["url"] as? String {
                    link = text
                    let name = obj["username"] as? String ?? ""
                    let code = obj["code"] as? String ?? ""
                    message = "key 校验通过（\(name) / \(code)），打开雷达页"
                } else {
                    message = "校验失败：\(obj["error"] as? String ?? "未知错误")"
                }
            } else {
                message = "校验失败：雷达服务无响应"
            }
            DispatchQueue.main.async {
                State.shared.log("[雷达] \(message)")
                if let link = link { RadarRouter.shared.open(link) }
            }
        }.resume()
    }

    func stop() {
        guard running else { return }
        uploader?.stop()
        socks?.stop()
        uploader = nil
        socks = nil
        State.shared.setRunning(false)
        State.shared.setLastError("")
        State.shared.setWsState("未连接")
        FlowHub.shared.clear()
        State.shared.log("=== 已停止 ===")
        scheduleAutoTest(immediate: true)   // 停止后恢复自动测速
        uiTick &+= 1
    }
}
