import SwiftUI
import ChargeKitCore

/// Battery level gauge: capsule track with a proportional fill and the
/// electrode nub, plus the percent readout beside it (iOS status-bar
/// convention — no text inside the fill, so contrast is never an issue).
/// The fill color carries the charging phase (the merged battery+status
/// element of the popover header); Low Power Mode tints it Apple-yellow
/// (system battery-icon convention); ≤20 % red always wins.
struct BatteryGaugeView: View {
 /// State of charge 0...100; nil = unreadable (sensor error).
    var percent: Double?
 /// Phase driving the fill color (charging green, holding orange,
 /// heat-paused red, discharging blue, idle plain green).
    var phase: ChargePhase = .idle
 /// macOS Low Power Mode active — yellow fill beats the phase colors
 /// (except the ≤20 % low-battery red); the status text beside the
 /// gauge still names the charging phase.
    var lowPowerMode: Bool = false

    private let gaugeWidth: CGFloat = 72
    private let gaugeHeight: CGFloat = 22

 /// LPM gauge yellow. Deeper than system yellow for contrast on the
 /// capsule track, yet deliberately clear of the holding orange:
 /// #D6A800 sits at hue ~47° (dark, green-leaning) vs system orange
 /// #FF9500 at ~35° (bright, red-leaning).
    private static let lowPowerYellow = Color(red: 0.84, green: 0.66, blue: 0)

    private var fill: Double { min(max(percent ?? 0, 0), 100) }
    private var fillColor: Color {
        if (percent ?? 100) <= 20 { return .red }
        if lowPowerMode { return Self.lowPowerYellow }
        switch phase {
        case .charging, .idle: return .green
        case .holding: return .orange
        case .heatPaused: return .red
        case .discharging: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                        .frame(width: gaugeWidth, height: gaugeHeight)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: gaugeWidth * fill / 100,
                               height: gaugeHeight - 6)
                        .padding(.leading, 3)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3.5, height: gaugeHeight * 0.45)
            }
            Text(percent == nil ? "—%" : "\(Int(fill))%")
                .font(.system(.title3, design: .rounded))
                .bold().monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("电池电量"))
        .accessibilityValue(Text(percent == nil ? "无法读取" : "\(Int(fill))%"))
    }
}
