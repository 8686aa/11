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
