import Foundation
import Darwin

/// 线程安全全局运行状态（网络线程高频写、UI 每秒快照读），等效安卓端 Globals。
final class State {
    static let shared = State()
    private init() {}

    private let lock = NSLock()

    private var _running = false
    private var _wsState = "未连接"
    private var _localIp = ""
    private var _listenPort = 1080
    private var _latMs: Int64 = -1          // 最近一次测速 ms，-1 = 未测/失败

    private var _upPackets: Int64 = 0
    private var _downPackets: Int64 = 0
    private var _sentPackets: Int64 = 0
    private var _upBytes: Int64 = 0
    private var _downBytes: Int64 = 0

    private var _logs: [String] = []
    private let maxLog = 500

    // MARK: - 运行状态
    var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    func setRunning(_ v: Bool) { lock.lock(); _running = v; lock.unlock() }

    var wsState: String { lock.lock(); defer { lock.unlock() }; return _wsState }
    func setWsState(_ v: String) { lock.lock(); _wsState = v; lock.unlock() }

    var localIp: String { lock.lock(); defer { lock.unlock() }; return _localIp }
    func setLocalIp(_ v: String) { lock.lock(); _localIp = v; lock.unlock() }

    var listenPort: Int { lock.lock(); defer { lock.unlock() }; return _listenPort }
    func setListenPort(_ v: Int) { lock.lock(); _listenPort = v; lock.unlock() }

    var latMs: Int64 { lock.lock(); defer { lock.unlock() }; return _latMs }
    func setLatMs(_ v: Int64) { lock.lock(); _latMs = v; lock.unlock() }

    private var _lastError = ""
    /// 最近一次错误（界面错误行显示，启动成功/停止时清空）
    var lastError: String { lock.lock(); defer { lock.unlock() }; return _lastError }
    func setLastError(_ v: String) { lock.lock(); _lastError = v; lock.unlock() }

    // MARK: - 流量计数
    struct Stats {
        var upPackets: Int64 = 0
        var downPackets: Int64 = 0
        var sentPackets: Int64 = 0
        var upBytes: Int64 = 0
        var downBytes: Int64 = 0
    }

    func addUp(bytes: Int) {
        lock.lock()
        _upPackets += 1
        _upBytes += Int64(bytes)
        lock.unlock()
    }

    func addDown(bytes: Int) {
        lock.lock()
        _downPackets += 1
        _downBytes += Int64(bytes)
        lock.unlock()
    }

    func addSent() {
        lock.lock()
        _sentPackets += 1
        lock.unlock()
    }

    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(upPackets: _upPackets, downPackets: _downPackets,
                     sentPackets: _sentPackets, upBytes: _upBytes, downBytes: _downBytes)
    }

    // MARK: - 环形日志（等效安卓 Globals.log/tail）
    func log(_ msg: String) {
        let line = "[\(Self.ts())] \(msg)"
        lock.lock()
        _logs.append(line)
        while _logs.count > maxLog { _logs.removeFirst() }
        lock.unlock()
    }

    func tail(maxLines: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !_logs.isEmpty else { return "" }
        let n = _logs.count
        let from = n > maxLines ? n - maxLines : 0
        return _logs[from..<n].joined(separator: "\n")
    }

    func clearLog() {
        lock.lock(); _logs.removeAll(); lock.unlock()
    }

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

/// 格式延迟：12ms / 1.2s / 离线
func formatLat(_ ms: Int64) -> String {
    if ms < 0 { return "离线" }
    if ms >= 1000 { return String(format: "%.1fs", Double(ms) / 1000.0) }
    return "\(ms)ms"
}

/// 私有 IPv4 是否为局域网地址（对齐安卓 findLocalIp 的判定）
func isPrivateIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    if parts[0] == 10 { return true }
    if parts[0] == 192 && parts[1] == 168 { return true }
    if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
    return false
}

/// 取本机局域网 IPv4（Wi-Fi en0 / 蜂窝 pdp 等），无则返回空串。
func localIPAddress() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return "" }
    defer { freeifaddrs(ifaddr) }

    var result = ""
    var ptr = ifaddr
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        // IFF_UP = 0x1, IFF_LOOPBACK = 0x8（宏在 Swift 不可直接引用，用数值）
        let flags = Int32(p.pointee.ifa_flags)
        guard (flags & 0x1) != 0, (flags & 0x8) == 0 else { continue }
        let name = String(cString: p.pointee.ifa_name)
        // 只关心 Wi-Fi/蜂窝接口；排除 utun/ipsec 等虚拟网卡
        guard name.hasPrefix("en") || name.hasPrefix("pdp") else { continue }

        let family = p.pointee.ifa_addr.pointee.sa_family
        guard family == sa_family_t(AF_INET) else { continue }

        var addr = p.pointee.ifa_addr.pointee
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(&addr, socklen_t(addr.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if isPrivateIPv4(ip) {
                result = ip
                break
            }
        }
    }
    return result
}
