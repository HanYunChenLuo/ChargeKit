import SwiftUI

/// Sankey-style power-flow diagram.
///
/// Nodes: 电源 (adapter, left) → 主机 (top right) / 电池 (bottom right).
/// Discharging reverses the battery leg: 电池 → 主机. Band width encodes
/// watts up to 60 W, and chevrons indicate direction.
///
/// Input identity: dcInPower ≈ hostPower + batteryPower(charging), and
/// hostPower ≈ dcInPower + |batteryPower|(discharging) — both hold by
/// construction (ChargeEngine computes host = input − battery).
struct PowerFlowView: View {
    var dcInPower: Double      // PDTR, W
    var batteryPower: Double?  // B0AV×B0AC, W; + charging / − discharging
    var hostPower: Double?     // system load, W

    @Environment(\.colorScheme) private var colorScheme

    private static let flowFloor = 0.2      // W; below this a leg is not drawn
    private static let fullScaleW = 60.0    // W at max band thickness
    private static let maxBand: CGFloat = 12
    private static let minBand: CGFloat = 3
    private static let branchGap: CGFloat = 6
    private static let cardHeight: CGFloat = 52

    private var inputTint: Color {
        colorScheme == .dark ? Color(red: 0.35, green: 0.85, blue: 0.68)
            : Color(red: 0.04, green: 0.49, blue: 0.35)
    }

    private var dischargeTint: Color {
        colorScheme == .dark ? Color(red: 0.42, green: 0.71, blue: 1)
            : Color(red: 0.11, green: 0.41, blue: 0.76)
    }

    private var sourceActive: Bool { dcInPower.isFinite && dcInPower > Self.flowFloor }

    private var srcToHost: Double {
        guard sourceActive else { return 0 }
        let remainingInput = dcInPower - srcToBatt
        guard let hostPower, hostPower.isFinite else { return remainingInput }
        return min(max(0, hostPower), remainingInput)
    }
    private var srcToBatt: Double {
        guard sourceActive, let b = batteryPower, b.isFinite, b > Self.flowFloor else { return 0 }
        return min(b, dcInPower)
    }
    private var battToHost: Double {
        guard let b = batteryPower, b.isFinite, b < -Self.flowFloor else { return 0 }
        return -b
    }

    private static func bandWidth(_ w: Double) -> CGFloat {
        minBand + (maxBand - minBand) * CGFloat(min(w / fullScaleW, 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let cardWidth = min(132, size.width * 0.40)
            let source = CGRect(x: 0, y: (size.height - Self.cardHeight) / 2,
                                width: cardWidth, height: Self.cardHeight)
            let host = CGRect(x: size.width - cardWidth, y: 0,
                              width: cardWidth, height: Self.cardHeight)
            let battery = host.offsetBy(dx: 0, dy: size.height - Self.cardHeight)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawConnections(context, source: source, host: host, battery: battery)
                }
                .accessibilityHidden(true)

                node("适配器", icon: "powerplug", value: watts(dcInPower),
                     tint: sourceActive ? inputTint : .secondary, rect: source)
                node("主机", icon: "laptopcomputer", value: watts(hostPower),
                     tint: .secondary, rect: host)
                node(batteryLabel, icon: batteryIcon, value: batteryValueText,
                     tint: batteryTint, rect: battery)
            }
        }
        .frame(height: 142)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("电源流向"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func drawConnections(_ context: GraphicsContext, source: CGRect, host: CGRect, battery: CGRect) {
        let split = srcToHost > Self.flowFloor && srcToBatt > Self.flowFloor
        // Space the band edges, so the gap survives unequal power on the two branches.
        let hostOffset = split ? (Self.bandWidth(srcToBatt) + Self.branchGap) / 2 : 0
        let batteryOffset = split ? (Self.bandWidth(srcToHost) + Self.branchGap) / 2 : 0
        drawBand(context, from: CGPoint(x: source.maxX, y: source.midY - hostOffset),
                 to: CGPoint(x: host.minX, y: host.midY), watts: srcToHost, tint: inputTint)
        drawBand(context, from: CGPoint(x: source.maxX, y: source.midY + batteryOffset),
                 to: CGPoint(x: battery.minX, y: battery.midY), watts: srcToBatt, tint: inputTint)
        drawBand(context, from: CGPoint(x: battery.midX, y: battery.minY),
                 to: CGPoint(x: host.midX, y: host.maxY), watts: battToHost, tint: dischargeTint)
    }

    private func drawBand(_ context: GraphicsContext, from start: CGPoint, to end: CGPoint,
                          watts: Double, tint: Color) {
        guard watts > Self.flowFloor else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let bend = dx * 0.44
        let bandWidth = Self.bandWidth(watts)
        var path = Path()
        path.move(to: start)
        if dx != 0 {
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + bend, y: start.y),
                          control2: CGPoint(x: end.x - bend, y: end.y))
        } else {
            path.addLine(to: end)
        }
        context.stroke(path, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.21), tint.opacity(0.48)]), startPoint: start, endPoint: end),
            style: StrokeStyle(lineWidth: bandWidth, lineCap: .butt))

        // With symmetric control points, the cubic midpoint lies halfway
        // between the two ports. Its tangent also covers the straight vertical leg.
        let tangentLength = hypot(dx - bend, dy)
        guard tangentLength > 0 else { return }
        let forwardX = (dx - bend) / tangentLength
        let forwardY = dy / tangentLength
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let arrowLength = 5 + bandWidth * 0.18
        let arrowHalfWidth = 2.5 + bandWidth * 0.15
        let tip = CGPoint(x: midpoint.x + forwardX * arrowLength / 2,
                          y: midpoint.y + forwardY * arrowLength / 2)
        let tail = CGPoint(x: midpoint.x - forwardX * arrowLength / 2,
                           y: midpoint.y - forwardY * arrowLength / 2)
        var chevron = Path()
        chevron.move(to: CGPoint(x: tail.x - forwardY * arrowHalfWidth, y: tail.y + forwardX * arrowHalfWidth))
        chevron.addLine(to: tip)
        chevron.addLine(to: CGPoint(x: tail.x + forwardY * arrowHalfWidth, y: tail.y - forwardX * arrowHalfWidth))
        context.stroke(chevron, with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }

    private var accessibilitySummary: String {
        let source = dcInPower.isFinite
            ? String(format: "适配器输入 %.1f 瓦", dcInPower)
            : "适配器功率不可用"
        let host = hostPower.flatMap { $0.isFinite ? String(format: "主机 %.1f 瓦", $0) : nil } ?? "主机功率不可用"
        let battery: String
        if let value = batteryPower, value.isFinite {
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
        guard let b = batteryPower, b.isFinite else { return "—" }
        if b > Self.flowFloor { return String(format: "+%.1f W", b) }
        if b < -Self.flowFloor { return String(format: "−%.1f W", -b) }
        return "0 W"
    }

    private var batteryTint: Color {
        guard let b = batteryPower, b.isFinite else { return .secondary }
        if b > Self.flowFloor { return inputTint }
        if b < -Self.flowFloor { return dischargeTint }
        return .secondary
    }

    private var batteryLabel: String {
        guard let power = batteryPower, power.isFinite else { return "电池" }
        if power > Self.flowFloor { return "电池充电" }
        if power < -Self.flowFloor { return "电池放电" }
        return "电池闲置"
    }

    private var batteryIcon: String {
        guard let power = batteryPower, power.isFinite, power > Self.flowFloor else { return "battery.100" }
        return "battery.100.bolt"
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f W", value)
    }

    private func node(_ name: String, icon: String, value: String, tint: Color, rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 25)
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .frame(width: rect.width, height: rect.height, alignment: .leading)
        .background(tint.opacity(0.07), in: shape)
        .background(.background, in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.24), lineWidth: 1))
        .position(x: rect.midX, y: rect.midY)
    }
}
