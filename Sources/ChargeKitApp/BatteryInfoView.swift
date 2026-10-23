import SwiftUI

/// Battery health + telemetry details (parity info block), shared
/// by the menu-bar popover (inside the height-animated disclosure) and the
/// Settings window's charging pane. All data comes from public sources:
/// AppleSmartBattery IORegistry properties (BatteryInfoReader),
/// IOPowerSources (macOS gauge percent) and the live SMC gauge keys carried
/// in the engine snapshot.
struct BatteryInfoView: View {
    let info: BatteryInfo
 /// Live SMC telemetry; nil on a read error (rows show "—").
    let telemetry: ChargeEngine.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "电池健康")
                InfoRow(label: "设计容量",
                        value: info.designCapacitymAh.map { "\($0) mAh" } ?? "—")
                InfoRow(label: "最大容量", value: maxCapacity)
                InfoRow(label: "电量（硬件 / macOS）", value: dualPercent)
                InfoRow(label: "循环次数",
                        value: info.cycleCount.map { "\($0)" } ?? "—")
                if let serial = info.serial {
                    InfoRow(label: "序列号", value: serial, monospacedValue: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "遥测明细")
                InfoRow(label: "输入功率", value: watts(telemetry?.dcInPower))
                InfoRow(label: "适配器", value: adapterText)
                InfoRow(label: "电池", value: batteryText)
                InfoRow(label: "电池温度",
                        value: telemetry?.batteryTemp.map { String(format: "%.1f°C", $0) } ?? "—")
                InfoRow(label: "主机负载", value: watts(telemetry?.hostPower))
            }
        }
    }

 /// Derived full-charge capacity (design × health), marked approximate:
 /// Apple publishes only the rounded health percent.
    private var maxCapacity: String {
        guard let design = info.designCapacitymAh,
              let health = info.healthPercent else { return "—" }
        let mah = (Double(design) * Double(health) / 100).rounded()
        return "≈\(Int(mah)) mAh · \(health)%"
    }

    private var dualPercent: String {
 // Raw BUIC from the snapshot — pct (the selected basis) would show
 // the same value twice under the default macOS basis (review
 // round 2, P1-3).
        let hardware = telemetry?.hardwareBatteryPercent
            .flatMap { String(format: "%.0f%%", $0) } ?? "—"
        let macos = info.macosPercent.map { "\($0)%" } ?? "—"
        return "\(hardware) / \(macos)"
    }

 /// The negotiated PD contract (capability tier), not instantaneous
 /// draw — that is the 输入功率 row.
    private var adapterText: String {
        switch (info.adapterVolts, info.adapterWatts) {
        case let (volts?, watts?):
            return "\(Int(volts)) V · \(watts) W（协商档）"
        default:
            return "未连接"
        }
    }

    private var batteryText: String {
        switch (telemetry?.batteryVolts, telemetry?.batteryAmps) {
        case let (volts?, amps?):
            return String(format: "%.2f V · %.2f A", volts, amps)
        default:
            return "—"
        }
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "—"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
 /// Full monospaced design for tech strings (serial number).
    var monospacedValue = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .font(monospacedValue ? .system(.callout, design: .monospaced) : nil)
        }
 // Matches SliderRow, the app's label/value rhythm in both the
 // popover and the settings panes.
        .font(.callout)
    }
}
