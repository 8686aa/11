import SwiftUI
import Foundation

// ============================================================================
// 拓扑斜线连接图（对齐安卓 TopologyView / PC LocalSniffer 同风格）：
// 左侧 = 已连接 SOCKS5 的客户端（iOS 小火箭），右侧 = 它访问的来源 IP 节点，
// 客户端与其来源 IP 之间斜线相连：橙=上行主导，青绿=下行主导，线宽随速率。
// ============================================================================

struct TopologyView: View {
    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .background(bg)
    }

    private let bg = Color(red: 18 / 255, green: 22 / 255, blue: 32 / 255)
    private let phoneFill = Color(red: 46 / 255, green: 110 / 255, blue: 218 / 255)
    private let phoneBorder = Color(red: 150 / 255, green: 170 / 255, blue: 255 / 255)
    private let remoteDownFill = Color(red: 22 / 255, green: 66 / 255, blue: 48 / 255)
    private let remoteDownBorder = Color(red: 72 / 255, green: 220 / 255, blue: 140 / 255)
    private let remoteUpFill = Color(red: 66 / 255, green: 46 / 255, blue: 18 / 255)
    private let remoteUpBorder = Color(red: 245 / 255, green: 168 / 255, blue: 46 / 255)
    private let upLine = Color(red: 243 / 255, green: 165 / 255, blue: 40 / 255, opacity: 0.45)
    private let downLine = Color(red: 60 / 255, green: 214 / 255, blue: 132 / 255, opacity: 0.45)

    private let maxRemotes = 60
    private let maxEdgesPerPhone = 10

    private func draw(context: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        guard w >= 120, h >= 100 else { return }

        let snap = FlowHub.shared.snapshot()
        let now = Date().timeIntervalSince1970
        let staleExtra: TimeInterval = 3.5

        // ---------- 提示：尚未捕获到客户端 ----------
        guard !snap.phones.isEmpty else {
            drawCenteredHint(context, w: w, h: h, title: "尚未捕获到客户端", sub: "iOS 小火箭连接本机 SOCKS5 后，\n此处实时显示 客户端 ↔ 来源IP 斜线连接")
            return
        }

        let padX: CGFloat = 10
        let phones = snap.phones
        let phoneW = min(150, w * 0.34)
        let gapY = h / CGFloat(phones.count + 1)
        let nodeH = min(max(22, gapY - 14), 56)
        let corridor = max(30, w * 0.04)
        let xRemote = padX + phoneW + corridor
        let wRemote = max(60, w - xRemote - padX)

        // 客户端节点矩形
        var phoneRects: [String: CGRect] = [:]
        for (i, p) in phones.enumerated() {
            let y = gapY * CGFloat(i + 1) - nodeH / 2
            phoneRects[p] = CGRect(x: padX, y: y, width: phoneW, height: nodeH)
        }

        // 来源 IP 方阵排布
        let liveRemotes = snap.remotes
            .filter { now - $0.last <= staleExtra }
            .prefix(maxRemotes)
        let boxW = min(130, wRemote - 6)
        let boxH: CGFloat = 24
        let stepX = boxW + 12
        let stepY = boxH + 10
        let cols = max(1, Int((wRemote - 4) / stepX))
        let rows = max(1, Int(ceil(Double(liveRemotes.count) / Double(cols))))
        let totalH = CGFloat(rows) * stepY - 8
        let yStart = max(16, (h - totalH) / 2)

        var remoteRects: [String: CGRect] = [:]
        for (idx, item) in liveRemotes.enumerated() {
            let c = idx % cols
            let r = idx / cols
            remoteRects[item.key] = CGRect(x: xRemote + CGFloat(c) * stepX,
                                           y: yStart + CGFloat(r) * stepY,
                                           width: boxW, height: boxH)
        }

        // ---------- 斜线（先画线，不穿文字） ----------
        for p in phones {
            guard let pr = phoneRects[p] else { continue }
            let anchor = CGPoint(x: pr.maxX - 2, y: pr.midY)
            let items = (snap.edges[p] ?? []).prefix(maxEdgesPerPhone)
            for item in items {
                guard now - item.last <= staleExtra else { continue }
                guard let rr = remoteRects[item.key] else { continue }
                let total = Double(item.upBytes + item.downBytes)
                let rate = total / max(1, now - item.last)
                let lw = CGFloat(1 + min(3, 1.4 * log10(1 + rate / 20)))
                let downDominant = item.downBytes >= item.upBytes
                var path = Path()
                path.move(to: anchor)
                path.addLine(to: CGPoint(x: rr.minX + 4, y: rr.midY))
                context.stroke(path, with: .color(downDominant ? downLine : upLine),
                               lineWidth: lw)
            }
        }

        // 来源 IP 区域淡底
        if !liveRemotes.isEmpty {
            let areaW = min(CGFloat(cols) * stepX - 4, wRemote)
            let area = CGRect(x: xRemote - 6, y: yStart - 8,
                              width: areaW + 8, height: totalH + 14)
            context.fill(Path(roundedRect: area, cornerRadius: 8),
                         with: .color(.white.opacity(0.05)))
        }

        // ---------- 来源 IP 节点 ----------
        for (key, rr) in remoteRects {
            guard let agg = liveRemotes.first(where: { $0.key == key }) else { continue }
            let downD = agg.downBytes >= agg.upBytes
            let path = Path(roundedRect: rr, cornerRadius: 4)
            context.fill(path, with: .color(downD ? remoteDownFill : remoteUpFill))
            context.stroke(path, with: .color(downD ? remoteDownBorder : remoteUpBorder), lineWidth: 1)
            drawText(context, text: ipOnly(key), in: rr, size: 10,
                     color: Color(red: 235 / 255, green: 240 / 255, blue: 245 / 255))
        }

        // ---------- 客户端节点 ----------
        for p in phones {
            guard let pr = phoneRects[p] else { continue }
            let path = Path(roundedRect: pr, cornerRadius: 8)
            context.fill(path, with: .color(phoneFill))
            context.stroke(path, with: .color(phoneBorder), lineWidth: 1.2)
            drawText(context, text: p, in: pr.insetBy(dx: 4, dy: 0), size: 11,
                     color: .white, bold: true, dy: -pr.height * 0.09)
            drawText(context, text: "SOCKS5", in: pr.insetBy(dx: 4, dy: 0), size: 8.5,
                     color: Color(red: 210 / 255, green: 230 / 255, blue: 255 / 255, opacity: 0.82),
                     dy: pr.height * 0.27)
        }

        guard snap.anyFlow else {
            drawCenteredHint(context, w: w, h: h, title: "等待客户端产生流量…",
                             sub: "客户端发起访问后，来源 IP 节点将与之连接成图")
            return
        }
        drawLegend(context, h: h)
    }

    private func drawText(_ context: GraphicsContext, text: String, in rect: CGRect,
                          size: CGFloat, color: Color, bold: Bool = false, dy: CGFloat = 0) {
        var f = Font.system(size: size)
        if bold { f = Font.system(size: size, weight: .bold) }
        context.draw(Text(text).font(f).foregroundColor(color),
                     at: CGPoint(x: rect.midX, y: rect.midY + dy))
    }

    private func drawLegend(_ context: GraphicsContext, h: CGFloat) {
        let items = ["橙 = 上行主导", "青绿 = 下行主导"]
        let x: CGFloat = 8
        let boxH: CGFloat = 30
        let y = h - boxH - 6
        context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 118, height: boxH), cornerRadius: 6),
                     with: .color(.black.opacity(0.6)))
        for (i, s) in items.enumerated() {
            let cy = y + 8 + CGFloat(i) * 12
            let dot = CGRect(x: x + 10, y: cy - 2, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot),
                         with: .color(i == 0 ? Color(red: 243 / 255, green: 165 / 255, blue: 40 / 255)
                                            : Color(red: 60 / 255, green: 214 / 255, blue: 132 / 255)))
            context.draw(Text(s).font(.system(size: 9)).foregroundColor(.white.opacity(0.7)),
                         at: CGPoint(x: x + 24, y: cy + 2), anchor: .leading)
        }
    }

    private func drawCenteredHint(_ context: GraphicsContext, w: CGFloat, h: CGFloat,
                                  title: String, sub: String) {
        let titleY = h / 2 - 8
        context.draw(Text(title).font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 235 / 255, green: 238 / 255, blue: 245 / 255)),
                     at: CGPoint(x: w / 2, y: titleY))
        var y = titleY + 20
        for line in sub.split(separator: "\n") {
            context.draw(Text(String(line)).font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.66)),
                         at: CGPoint(x: w / 2, y: y))
            y += 15
        }
    }

    private func ipOnly(_ key: String) -> String {
        if let idx = key.lastIndex(of: ":") { return String(key[..<idx]) }
        return key
    }
}
