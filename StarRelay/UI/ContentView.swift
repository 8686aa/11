import SwiftUI
import Foundation
import Combine

/// 主界面（对齐安卓 activity_main 单列布局）：
/// 转发器服务器下拉 → 房间Key/端口 → 启动/停止 → 提示 → 状态行 → 拓扑图(大) → 日志(小)
struct ContentView: View {
    @StateObject private var model = AppModel()
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let bg = Color(red: 20 / 255, green: 23 / 255, blue: 32 / 255)
    private let txtMain = Color(red: 0.92, green: 0.93, blue: 0.95)
    private let txtSub = Color(red: 0.62, green: 0.66, blue: 0.72)
    private let fieldBg = Color(white: 0.17)
    private let primary = Color(red: 64 / 255, green: 128 / 255, blue: 255 / 255)
    private let warn = Color(red: 1.0, green: 0.56, blue: 0.38)

    var body: some View {
        VStack(spacing: 7) {
            serverHeader
            keyPortRow
            controlRow
            frontTip
            hintText
            statusText
            errorLine
            chart
            logCard
        }
        .padding(10)
        .background(bg)
        .onReceive(secondTimer) { _ in model.onSecondTick() }
        .onAppear { model.viewDidAppear() }
        .onDisappear { model.viewDidDisappear() }
    }

    // MARK: - 转发器服务器（组合框：内置 ws，不可手填；自动测速挂在项名）
    private var serverHeader: some View {
        HStack {
            Text("转发器服务器")
                .font(.system(size: 13))
                .foregroundColor(txtMain)
            Spacer()
            Menu {
                ForEach(0..<model.servers.count, id: \.self) { i in
                    Button {
                        model.selectServer(i)
                    } label: {
                        Text(model.servers[i].label()).font(.system(size: 13))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.currentServer().label())
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(fieldBg))
            }
            .disabled(model.running)
        }
    }

    // MARK: - 房间Key / 端口
    private var keyPortRow: some View {
        HStack(spacing: 6) {
            Text("房间Key").font(.system(size: 13)).foregroundColor(txtMain)
            field(text: $model.apiKeyText, placeholder: "32位hex(留空=调试房间)", flex: true)
                .disabled(model.running)
            Text("  端口 ").font(.system(size: 13)).foregroundColor(txtMain)
            field(text: $model.portText, placeholder: "1080", flex: false)
                .frame(width: 78)
                .keyboardType(.numberPad)
                .disabled(model.running)
        }
    }

    private func field(text: Binding<String>, placeholder: String, flex: Bool) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
            .frame(maxWidth: flex ? .infinity : nil)
    }

    // MARK: - 启动 / 停止
    private var controlRow: some View {
        HStack(spacing: 8) {
            Button {
                model.start()
            } label: {
                Text("启动 Socks5 + 上报")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(primary))
                    .foregroundColor(.white)
            }
            .disabled(model.running)
            .opacity(model.running ? 0.5 : 1)

            Button {
                model.stop()
            } label: {
                Text("停止")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(fieldBg))
                    .foregroundColor(model.running ? .white : .white.opacity(0.4))
            }
            .disabled(!model.running)
        }
    }

    // MARK: - 前台常驻提示
    private var frontTip: some View {
        Text("注意：本 App 必须保持前台运行 — 切勿切到后台或锁屏，否则转发中断")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(warn)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 提示 / 状态
    private var hintText: some View {
        Text("iOS 小火箭 SOCKS5：服务器 = \(State.shared.localIp.isEmpty ? "未获取" : State.shared.localIp)，端口 = \(State.shared.listenPort)（需同一 WiFi）")
            .font(.system(size: 11))
            .foregroundColor(txtSub)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: some View {
        let s = State.shared.stats()
        let line = "运行:\(model.running ? "是" : "否")  WS:\(State.shared.wsState)  " +
                   "延迟:\(model.latLabel())  上行↑\(s.upPackets)  下行↓\(s.downPackets)  " +
                   "已发\(s.sentPackets)"
        return Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(txtMain)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 错误行（最近一次失败原因，成功/停止后消失）
    private var errorLine: some View {
        let err = State.shared.lastError
        return Group {
            if !err.isEmpty {
                Text("!  \(err)")
                    .font(.system(size: 11))
                    .foregroundColor(warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(warn.opacity(0.12)))
            }
        }
    }

    // MARK: - 拓扑图（占最大空间）
    private var chart: some View {
        TopologyView()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 110)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - 日志（带标题，固定最小高度保证可见）
    private var logCard: some View {
        VStack(spacing: 4) {
            HStack {
                Text("运行日志")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(txtSub)
                Spacer()
                Text("启动后此处实时输出")
                    .font(.system(size: 9.5))
                    .foregroundColor(txtSub.opacity(0.6))
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Text(State.shared.tail(maxLines: 300))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(red: 0.72, green: 0.9, blue: 0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logBottom")
                }
                .padding(6)
                .frame(maxHeight: 150)
                .frame(minHeight: 70)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1))
                .onChange(of: model.uiTick) { _ in
                    withAnimation(.none) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}
