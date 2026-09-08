import Foundation

/// 拓扑数据汇集点（等效安卓 FlowHub）：
/// 客户端“设备” = 连上本机 SOCKS5 的 iOS 小火箭 IP；
/// 每个包记录它访问的远端 ip:port 的边（上行↑/下行↓ 字节 + 最近时刻）。
final class FlowHub {
    static let shared = FlowHub()
    private init() {}

    private let lock = NSLock()
    private var phones: [String: PhoneInfo] = [:]          // 客户端 ip -> 信息
    private var remoteAgg: [String: Edge] = [:]            // ip:port -> 聚合(跨客户端)

    private let staleMs: TimeInterval = 3.5                 // 边过期
    private let phoneLinger: TimeInterval = 60.0            // 客户端节点存活

    final class Edge {
        var upBytes: Int64 = 0
        var downBytes: Int64 = 0
        var last: TimeInterval = 0
    }

    private final class PhoneInfo {
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var edges: [String: Edge] = [:]
        init(now: TimeInterval) { firstSeen = now; lastSeen = now }
    }

    struct EdgeItem {
        let key: String
        let upBytes: Int64
        let downBytes: Int64
        let last: TimeInterval
    }

    struct Snapshot {
        let phones: [String]
        let edges: [String: [EdgeItem]]
        let remotes: [EdgeItem]
        var anyFlow: Bool { !remotes.isEmpty }
    }

    // MARK: - 事件（任意线程）

    /// 客户端活跃（连接建立/握手时调用，不产生远端节点）
    func touchClient(_ phone: String) {
        guard !phone.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        lock.lock()
        if phones[phone] == nil {
            phones[phone] = PhoneInfo(now: now)
            State.shared.log("客户端接入: \(phone)")
        }
        phones[phone]?.lastSeen = now
        lock.unlock()
    }

    /// 上报一个 IP 包：phone=客户端(小火箭)，remote=对端
    func report(phone: String, remoteIp: String, remotePort: Int, up: Bool, bytes: Int) {
        guard !phone.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let key = "\(remoteIp):\(remotePort)"
        lock.lock()
        let info: PhoneInfo
        if let p = phones[phone] { info = p } else {
            info = PhoneInfo(now: now)
            phones[phone] = info
            State.shared.log("客户端接入: \(phone)")
        }
        info.lastSeen = now
        let e = info.edges[key] ?? Edge()
        info.edges[key] = e
        let agg = remoteAgg[key] ?? Edge()
        remoteAgg[key] = agg
        if up { e.upBytes += Int64(bytes) } else { e.downBytes += Int64(bytes) }
        e.last = now
        if up { agg.upBytes += Int64(bytes) } else { agg.downBytes += Int64(bytes) }
        agg.last = now
        lock.unlock()
    }

    // MARK: - 每秒清理（UI 调用）
    func tick() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        for (_, info) in phones {
            info.edges = info.edges.filter { now - $0.value.last <= staleMs }
        }
        remoteAgg = remoteAgg.filter { now - $0.value.last <= staleMs }
        let gone = phones.filter { now - $0.value.lastSeen > phoneLinger }.map { $0.key }
        for g in gone { phones.removeValue(forKey: g) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        phones.removeAll()
        remoteAgg.removeAll()
        lock.unlock()
    }

    // MARK: - 快照（绘制期间不持有锁）
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let sortedPhones = phones.sorted { $0.value.firstSeen < $1.value.firstSeen }.map { $0.key }
        var edges: [String: [EdgeItem]] = [:]
        for p in sortedPhones {
            guard let info = phones[p] else { continue }
            let items = info.edges
                .sorted { $0.value.last > $1.value.last }
                .map { EdgeItem(key: $0.key, upBytes: $0.value.upBytes,
                                downBytes: $0.value.downBytes, last: $0.value.last) }
            edges[p] = items
        }
        let remotes = remoteAgg
            .sorted { $0.value.last > $1.value.last }
            .map { EdgeItem(key: $0.key, upBytes: $0.value.upBytes,
                            downBytes: $0.value.downBytes, last: $0.value.last) }
        return Snapshot(phones: sortedPhones, edges: edges, remotes: remotes)
    }
}
