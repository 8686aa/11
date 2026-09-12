import Foundation

/// 转发器服务器：**只有 IP 由用户填写**，端口固定（上报 ws 1082 / 雷达 http 666）。
/// 测速结果挂在 label() 上，如 192.140.179.181(12ms)。等效安卓 ServerPreset。
final class ServerPreset: Identifiable {
    /// 转发器上报(ws)端口，固定不可改
    static let wsPort = 1082
    /// 雷达服务（HTTP）端口，固定不可改；与 sol_radar_local 的 PORT 默认值一致
    static let radarHTTPPort = 666
    /// 内置默认服务器 IP
    static let defaultHost = "192.140.179.181"

    let id = UUID()
    /// 用户填写的服务器 IP（或主机名）
    let host: String
    /// 测速延迟 ms；-1 = 未测/离线（仅主线程/UI 更新）
    var latMs: Int64 = -1

    init(host: String) {
        self.host = host
    }

    /// 转发器上报地址：ws://<ip>:1082
    var url: String { "ws://\(host):\(ServerPreset.wsPort)" }

    func label() -> String {
        latMs < 0 ? host : "\(host)(\(formatLat(latMs)))"
    }
}

// MARK: - 雷达服务地址推导
//
// 转发器(ws 1082)与雷达服务(http 666)部署在同一台机器、同一个 IP，只是端口不同。
// 这里按约定把内置的 ws 地址换算成雷达服务基址，避免再为每个服务器多配一个字段。
// 若服务端改了 666 端口，需同步改 radarHTTPPort。
extension ServerPreset {
    /// 雷达服务基址：ws://host:1082 -> http://host:666（wss 则得到 https）
    var radarBaseURL: URL? {
        guard var c = URLComponents(string: url), c.host != nil else { return nil }
        c.scheme = (c.scheme == "wss") ? "https" : "http"
        c.port = Self.radarHTTPPort
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// 校验 key 并取回分享链接的接口地址：GET /api/share/by_key?key=<32位hex>
    func shareByKeyURL(apiKey: String) -> URL? {
        guard let base = radarBaseURL,
              var c = URLComponents(url: base.appendingPathComponent("api/share/by_key"),
                                    resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return c.url
    }
}
