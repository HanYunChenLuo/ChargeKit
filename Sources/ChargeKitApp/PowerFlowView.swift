import SwiftUI

/// Sankey-style power-flow diagram.
///
/// Nodes: 电源 (adapter, left) → 主机 (top right) / 电池 (bottom right).
/// Discharging reverses the battery leg: 电池 → 主机. Band width is
/// proportional to watts (24pt at 60W) and dashes move in the flow direction.
///
/// Input identity: dcInPower ≈ hostPower + batteryPower(charging), and
/// hostPower ≈ dcInPower + |batteryPower|(discharging) — both hold by
/// construction (ChargeEngine computes host = input − battery).
struct PowerFlowView: View {
    var dcInPower: Double      // PDTR, W
    var batteryPower: Double?  // B0AV×B0AC, W; + charging / − discharging
    var hostPower: Double?     // system load, W

    private static let flowFloor = 0.2      // W; below this a leg is not drawn
    private static let sourceFloor = 1.0    // W; PDTR above this = adapter live
    private static let fullScaleW = 60.0    // W at max band thickness
    private static let maxBand = 24.0
    private static let minBand = 3.0

    private var sourceActive: Bool { dcInPower > Self.sourceFloor }

    private var srcToHost: Double {
        guard sourceActive else { return 0 }
        return hostPower.map { min($0, dcInPower) } ?? dcInPower
    }
    private var srcToBatt: Double {
        guard sourceActive, let b = batteryPower, b > Self.flowFloor else { return 0 }
        return b
    }
    private var battToHost: Double {
        guard let b = batteryPower, b < -Self.flowFloor else { return 0 }
        return -b
    }

    private static func bandWidth(_ w: Double) -> CGFloat {
        minBand + (maxBand - minBand) * CGFloat(min(w / fullScaleW, 1))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let nodeW = 78.0, nodeH = 40.0
                let sourceRect = CGRect(x: 0, y: h / 2 - nodeH / 2, width: nodeW, height: nodeH)
                let hostRect = CGRect(x: w - nodeW, y: 6, width: nodeW, height: nodeH)
                let battRect = CGRect(x: w - nodeW, y: h - nodeH - 6, width: nodeW, height: nodeH)

 // Dash phase: negative offset moves dashes along the path direction.
                let phase = -timeline.date.timeIntervalSinceReferenceDate * 24

                func band(_ path: Path, _ watts: Double, _ color: Color) {
                    guard watts > Self.flowFloor else { return }
                    ctx.stroke(path, with: .color(color.opacity(0.55)),
                               style: StrokeStyle(lineWidth: Self.bandWidth(watts),
                                                  lineCap: .butt,
                                                  dash: [5, 7], dashPhase: phase))
                }

 // Two source bands fork from the node's right edge, stacked so
 // their widths do not overlap (host above, battery below).
                let wHost = Self.bandWidth(srcToHost), wBatt = Self.bandWidth(srcToBatt)
                let srcX = nodeW
                let span = w - 2 * nodeW

                let hostOut = CGPoint(x: srcX, y: h / 2 - (srcToBatt > Self.flowFloor ? wBatt / 2 : 0))
                let hostIn = CGPoint(x: w - nodeW, y: hostRect.midY)
                var p = Path()
                p.move(to: hostOut)
                p.addCurve(to: hostIn,
                           control1: CGPoint(x: hostOut.x + span * 0.5, y: hostOut.y),
                           control2: CGPoint(x: hostIn.x - span * 0.5, y: hostIn.y))
                band(p, srcToHost, .green)

                let battOut = CGPoint(x: srcX, y: h / 2 + (srcToHost > Self.flowFloor ? wHost / 2 : 0))
                let battIn = CGPoint(x: w - nodeW, y: battRect.midY)
                p = Path()
                p.move(to: battOut)
                p.addCurve(to: battIn,
                           control1: CGPoint(x: battOut.x + span * 0.5, y: battOut.y),
                           control2: CGPoint(x: battIn.x - span * 0.5, y: battIn.y))
                band(p, srcToBatt, .green)

                p = Path()
                p.move(to: CGPoint(x: battRect.midX, y: battRect.minY))
                p.addLine(to: CGPoint(x: hostRect.midX, y: hostRect.maxY))
                band(p, battToHost, .blue)

                node(ctx, rect: sourceRect, name: "电源",
                     value: sourceActive ? String(format: "%.1f W", dcInPower) : "—",
                     tint: .green, active: sourceActive)
                node(ctx, rect: hostRect, name: "主机",
                     value: hostPower.map { String(format: "%.1f W", $0) } ?? "—",
                     tint: .secondary, active: (hostPower ?? 0) > Self.flowFloor)
                node(ctx, rect: battRect, name: "电池",
                     value: batteryValueText, tint: batteryTint,
                     active: srcToBatt > 0 || battToHost > 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("电源流向"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let source = sourceActive
            ? String(format: "电源 %.1f 瓦", dcInPower)
            : "未检测到外接电源输入"
        let host = hostPower.map { String(format: "主机 %.1f 瓦", $0) } ?? "主机功率不可用"
        let battery: String
        if let value = batteryPower {
            if value > Self.flowFloor {
                battery = String(format: "电池充电 %.1f 瓦", value)
            } else if value < -Self.flowFloor {
                battery = String(format: "电池放电 %.1f 瓦", -value)
            } else {
                battery = "电池没有明显充放电"
            }
        } else {
            battery = "电池功率不可用"
        }
        return "\(source)，\(host)，\(battery)"
    }

    private var batteryValueText: String {
        guard let b = batteryPower else { return "—" }
        if b > Self.flowFloor { return String(format: "+%.1f W", b) }
        if b < -Self.flowFloor { return String(format: "−%.1f W", -b) }
        return "0 W"
    }

    private var batteryTint: Color {
        guard let b = batteryPower else { return .secondary }
        if b > Self.flowFloor { return .green }
        if b < -Self.flowFloor { return .blue }
        return .secondary
    }

    private func node(_ ctx: GraphicsContext, rect: CGRect, name: String,
                      value: String, tint: Color, active: Bool) {
        let shape = RoundedRectangle(cornerRadius: 8).path(in: rect)
        ctx.fill(shape, with: .color(active ? tint.opacity(0.18) : Color.gray.opacity(0.12)))
        ctx.stroke(shape, with: .color(active ? tint.opacity(0.5) : Color.gray.opacity(0.4)))
        ctx.draw(Text(name).font(.caption2).foregroundColor(.secondary),
               at: CGPoint(x: rect.midX, y: rect.midY - 9))
        ctx.draw(Text(value).font(.caption.weight(.semibold)).foregroundColor(.primary),
               at: CGPoint(x: rect.midX, y: rect.midY + 9))
    }
}
