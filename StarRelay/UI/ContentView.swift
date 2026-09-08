import SwiftUI
import Foundation
import Combine

/// 主界面（对齐安卓 activity_main 单列布局）：
/// 转发器服务器下拉 → Token/端口 → 启动/停止 → 提示 → 状态行 → 拓扑图(大) → 日志(小)
struct ContentView: View {
    @StateObject private var model = AppModel()
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let bg = Color(red: 20 / 255, green: 23 / 255, blue: 32 / 255)
    private let txtMain = Color(red: 0.92, green: 0.93, blue: 0.95)
    private let txtSub = Color(red: 0.62, green: 0.66, blue: 0.72)
    private let fieldBg = Color(white: 0.17)
    private let primary = Color(red: 64 / 255, green: 128 / 255, blue: 255 / 255)

    var body: some View {
        VStack(spacing: 8) {
            serverHeader
            tokenPortRow
            controlRow
            hintText
            statusText
            chart
            logView
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

    // MARK: - Token / 端口
    private var tokenPortRow: some View {
        HStack(spacing: 6) {
            Text("Token").font(.system(size: 13)).foregroundColor(txtMain)
            field(text: $model.tokenText, placeholder: "可选", flex: true)
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

    // MARK: - 提示 / 状态
    private var hintText: some View {
        Text("iOS 小火箭 SOCKS5：服务器 = \(State.shared.localIp.isEmpty ? "未获取" : State.shared.localIp)，端口 = \(State.shared.listenPort)（同一 WiFi，保持本 App 前台亮屏）")
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

    // MARK: - 拓扑图（占最大空间）
    private var chart: some View {
        TopologyView()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 130)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - 日志
    private var logView: some View {
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.09)))
            .onChange(of: model.uiTick) { _ in
                withAnimation(.none) {
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
    }
}
