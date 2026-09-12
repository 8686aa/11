# 星辰雷达（iOS 中转器）

iPhone 做“SOCKS5 中转机”的 iOS 版：供另一台 iOS 的小火箭连接本机开出的
SOCKS5 代理，把经过的流量封装成完整 IP 报文，经 WebSocket 上报转发器
（`ws://服务器:1082`，协议与安卓版 / LocalSniffer / 转发器 WsMirrorServer 完全一致）。

> 注意：iOS 无后台常驻机制。本 App 采用「前台常亮」方案——充电 + 关闭自动锁屏
> （App 已自动禁用屏幕休眠），保持本 App 在前台即可持续中转。
> 不依赖 NetworkExtension / VPN 权限，普通开发者账号即可真机运行。

## 目录结构

```
StarRelay.xcodeproj     Xcode 工程（双击打开即可）
StarRelay/
  StarRelayApp.swift    App 入口（禁用屏幕休眠）
  Info.plist            允许明文 ws / 本地网络说明
  Core/
    State.swift         线程安全全局状态 + 日志 + 本机 IP
    ServerPreset.swift  预置转发器列表（加天卡/月卡在此加项）
    IpPacket.swift      SOCKS5 载荷 -> 完整 IPv4 报文（与安卓一致）
    Socks5Server.swift  SOCKS5 服务端（TCP CONNECT / UDP ASSOCIATE，POSIX）
    WsUploader.swift    WS 逐包上报（断线重连 / 鉴权 / 心跳）
    FlowHub.swift       拓扑数据汇集
  UI/
    AppModel.swift      服务器下拉 + 10s 自动测速 + 启停
    TopologyView.swift  拓扑斜线连接图（橙=上行主导，青绿=下行主导）
    ContentView.swift   主界面
  Assets.xcassets       App 图标（logo）
```

## 在 Mac 上构建运行（约 3 分钟）

1. 把整个 `StarRelay` 文件夹拷到 Mac（例如用 AirDrop / 微信 / 网盘）。
2. 双击 `StarRelay.xcodeproj` 用 Xcode 打开（需 Xcode 14+，建议 15/16）。
3. 首次真机运行需要配置一次自动签名（工程已预置 `CODE_SIGN_STYLE = Automatic`，
   见下面「自动签名 5 步」）。
4. 顶部选择你的 iPhone 真机，点 ▶ 运行。首次会弹“本地网络”权限，点允许。
5. 打开后：转发器下拉自动测速显示 `服务器1(12ms)` → 填 Token(可选)/端口 →
   点「启动 Socks5 + 上报」。

### 自动签名 5 步（只在第一台 Mac 上做一次）

1. **登录 Apple ID**：Xcode 顶部菜单 → Settings(Settings…/偏好设置) → Accounts 标签 →
   左下角 `+` → Apple ID → 输入账号密码登录（免费账号即可）。
2. **打开签名页**：左侧 TARGETS → 选中 `StarRelay` → 顶部标签切到
   `Signing & Capabilities`。
3. **开启自动签名**：勾选 `Automatically manage signing`（工程默认已勾选；
   若下方出现黄色提示 "Provisioning profile doesn't include..." 属于旧缓存，
   在 Xcode 菜单 Product → Clean Build Folder 后重新打开即可）。
4. **选 Team**：Team 下拉框 → 选择刚登录的 Apple ID（免费账号显示为
   `Personal Team`）。此时 Xcode 自动生成开发证书和描述文件，
   “Signing Certificate” 应显示 `Apple Development`，状态无红色报错即成功。
5. **信任本机证书**（首次真机运行前）：手机 设置 → 通用 → VPN与设备管理 →
   点你的 Apple ID → 信任。随后回到 Xcode 点 ▶ 运行。

> 常见报错与处理：
> - `Signing for "StarRelay" requires a development team` → 第 4 步没选 Team。
> - `Provisioning profile ... doesn't include the currently selected device`
>   → 手机没在 Xcode 信任：重插数据线，Xcode → Window → Devices 里勾选信任。
> - `... bundle identifier "com.tzsp.starrelay" is already used` → 说明该 Bundle ID
>   已被别的账号用过（免费账号要求全局唯一），改一下再试：Xcode 签名页
>   `Bundle Identifier` 改成例如 `com.你的名字.starrelay1`。
> - 免费账号签名有效期 7 天，到期后需回 Xcode 点一次 ▶ 重新安装；
>   长期使用建议付费开发者账号（$99/年，无需重复操作）。
> - 提示 `Failed to register bundle identifier` 时可在签名页点
>   `Try Again`，或直接去掉 `Automatically manage signing` 再勾回重试。

> 如果 Xcode 打开报工程格式不兼容，请升级 Xcode（设置内
> `IPHONEOS_DEPLOYMENT_TARGET = 15.0`，Xcode 12 起可打开，仅 SwiftUI 代码）。

## 没有 Mac？云 Mac 远程构建（按小时计费，装回自己的手机）

思路：租一台带 Xcode 的云 Mac 完成「自动签名 + 导出 ipa」，再把 ipa 下载回
Windows，用爱思助手装进手机。云 Mac 上没有你的 USB 线，所以**不做真机运行**，
改为「注册设备 UDID → 导出 ipa → 本地安装」。

0. **先拿手机 UDID**（Windows 上做）：手机连电脑 → 打开爱思助手 →
   「我的设备」页复制 UDID（一串约 40 位十六进制）。没有爱思助手就用
   iTunes：点设备 → 点序列号，会切换显示 UDID，复制即可。
1. **租云 Mac**：选一家按小时计费的 macOS 云服务（如 MacinCloud 或国内云 Mac
   商家），系统选带 Xcode 的版本，用远程桌面（Windows 自带的“远程桌面连接”）
   登录进去。账户需能登录 App Store 安装/登录 Xcode 账号。
2. **上传工程**：把 `StarRelay` 整个文件夹压缩成 zip 上传到云 Mac
   （云服务自带文件管理，或用网盘/iCloud 中转），解压后双击
   `StarRelay.xcodeproj` 打开。
3. **自动签名**：按上面「自动签名 5 步」登录你的 Apple ID 并选 Team。
   由于手机不在身边，Xcode 会提示需要注册设备——见下一步。
4. **注册你的手机**：签名页若提示 `No devices registered` / 需要设备，
   点 Register a device → 粘贴第 0 步的 UDID → 注册完成，签名变绿。
   （免费账号同一时间注册设备数有限，别乱加别人的 UDID。）
5. **导出 ipa**：
   - 顶部运行目标选择 `Any iOS Device (arm64)`（不是模拟器）；
   - 菜单 Product → Archive，等构建完成后弹出 Organizer；
   - 点 Distribute App → Development → 勾选你的账号与已注册设备 →
     导出 .ipa 文件，下载回 Windows。
6. **装进手机**：Windows 装爱思助手 → 手机连电脑 →
   「应用游戏」→ 导入刚下载的 .ipa 安装。若提示“未受信任的开发者”：
   手机 设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID。
7. **计费提醒**：远程桌面会话用完及时**关闭云实例/停止计时**，避免一直扣费。

> 注意：
> - Development 签名的 ipa 只能装在“已注册该 UDID 的这台手机”上；
>   换手机需重新注册并重新导出。
> - 免费账号签名 **7 天过期**，到期需回云 Mac 重新 Archive 覆盖安装；
>   付费开发者账号（$99/年）一年内无需重复，且注册设备不紧张。
> - 若 Archive 弹窗中没有 Development 选项，确认第 3 步 Team 已选、证书为
>   `Apple Development`，并且 Xcode → Settings → Accounts 已登录该账号。
> - 嫌自己折腾，也可找“代签名/代打包”商家：把工程 + UDID 发过去，
>   对方导出 ipa 发回，用第 6 步安装即可（注意别泄露 Apple ID 密码）。

## 服务器地址在哪改

界面上「服务器IP」直接手填，**只有 IP 可改**，端口固定（上报 ws 1082 / 雷达 http 666）。

要改内置默认 IP 或固定端口，编辑 `StarRelay/Core/ServerPreset.swift`：

```swift
static let wsPort = 1082                      // 转发器上报端口（固定）
static let radarHTTPPort = 666                // 雷达服务端口（固定）
static let defaultHost = "192.140.179.181"    // 内置默认服务器 IP
```

输入框不可手填端口；10 秒自动测当前 IP，延迟显示在输入框右侧：`12ms` / `1.2s` / `离线`。

## 使用形态（两台 iPhone）

```
游戏 iPhone：小火箭 配置 SOCKS5 -> 中转机IP:1080
中转 iPhone：本 App 前台亮屏运行「启动 Socks5 + 上报」，流量 -> WS -> 转发器(1082) -> TZSP -> 解码器
```

与安卓版唯一差异：安卓可锁屏后台常驻，iOS 需保持前台 + 亮屏（已自动禁休眠）。
