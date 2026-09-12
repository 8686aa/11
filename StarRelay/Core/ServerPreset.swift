import Foundation

/// 预置转发器（内置 ws 地址，不可修改）。测速结果挂在名称上，如 服务器1(12ms)。等效安卓 ServerPreset。
final class ServerPreset: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    /// 测速延迟 ms；-1 = 未测/离线（仅主线程/UI 更新）
    var latMs: Int64 = -1

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    func label() -> String {
        latMs < 0 ? name : "\(name)(\(formatLat(latMs)))"
    }
}

/// 内置转发器列表：添加天卡/月卡只需在此追加（等效安卓 MainActivity.servers）。
func defaultServers() -> [ServerPreset] {
    [
        ServerPreset(name: "服务器1", url: "ws://192.140.167.247:1082"),
    ]
}

// MARK: - 雷达服务地址推导
//
// 转发器(ws 1082)与雷达服务(http 666)部署在同一台机器、同一个 IP，只是端口不同。
// 这里按约定把内置的 ws 地址换算成雷达服务基址，避免再为每个服务器多配一个字段。
// 若服务端改了 666 端口，需同步改 radarHTTPPort。
extension ServerPreset {
    /// 雷达服务（HTTP）端口，与 sol_radar_local 的 PORT 默认值一致
    static let radarHTTPPort = 666

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
