import SwiftUI

/// Read-only battery pane. Health and macOS gauge data remain available
/// independently of the live SMC snapshot.
struct BatteryInfoView: View {
    let info: BatteryInfo
    let telemetry: ChargeEngine.Snapshot?

    var body: some View {
        Form {
            Section("电源流向") {
                if let telemetry {
                    PowerFlowView(
                        dcInPower: telemetry.dcInPower,
                        batteryPower: telemetry.batteryPower,
                        hostPower: telemetry.hostPower)
                        .frame(height: 108)
                } else {
                    Label("实时功率暂不可用", systemImage: "bolt.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("电池健康") {
                InfoRow(label: "健康度",
                        value: info.healthPercent.map { "\($0)%" } ?? "—")
                InfoRow(label: "设计容量",
                        value: info.designCapacitymAh.map { "\($0) mAh" } ?? "—")
                InfoRow(label: "估算满充容量", value: maxCapacity)
                InfoRow(label: "循环次数",
                        value: info.cycleCount.map { "\($0)" } ?? "—")
                if let serial = info.serial {
                    InfoRow(label: "序列号", value: serial, monospacedValue: true)
                }
            }

            Section("实时读数") {
                InfoRow(label: "电量（硬件 / macOS）", value: dualPercent)
                InfoRow(label: "电池温度",
                        value: telemetry?.batteryTemp.map { String(format: "%.1f°C", $0) } ?? "—")
                InfoRow(label: "续航估算", value: runtimeText)
                InfoRow(label: "输入功率", value: watts(telemetry?.dcInPower))
                InfoRow(label: "主机负载", value: watts(telemetry?.hostPower))
                InfoRow(label: "电池电压 / 电流", value: batteryText)
                InfoRow(label: "适配器协商档位", value: adapterText)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }

 /// Derived full-charge capacity (design × health), marked approximate:
 /// Apple publishes only the rounded health percent.
    private var maxCapacity: String {
        guard let design = info.designCapacitymAh,
              let health = info.healthPercent else { return "—" }
        let mah = (Double(design) * Double(health) / 100).rounded()
        return "≈\(Int(mah)) mAh"
    }

    private var dualPercent: String {
 // Raw BUIC from the snapshot — pct (the selected basis) would show
 // the same value twice under the default macOS basis (review
 // round 2, P1-3).
        let hardware = telemetry?.hardwareBatteryPercent
            .map { String(format: "%.0f%%", $0) } ?? "—"
        let macos = info.macosPercent.map { "\($0)%" } ?? "—"
        return "\(hardware) / \(macos)"
    }

 /// The negotiated PD contract (capability tier), not instantaneous
 /// draw — that is the 输入功率 row.
    private var adapterText: String {
        switch (info.adapterVolts, info.adapterWatts) {
        case let (volts?, watts?):
            return "\(voltageText(volts)) · \(watts) W"
        case let (volts?, nil):
            return voltageText(volts)
        case let (nil, watts?):
            return "\(watts) W"
        case (nil, nil):
            return "—"
        }
    }

    private func voltageText(_ volts: Double) -> String {
        "\(volts.formatted(.number.precision(.fractionLength(0...2)))) V"
    }

    private var batteryText: String {
        switch (telemetry?.batteryVolts, telemetry?.batteryAmps) {
        case let (volts?, amps?):
            return String(format: "%.2f V · %.2f A", volts, amps)
        default:
            return "—"
        }
    }

 /// Runtime until empty from the engine's EMA-smoothed estimate; "—"
 /// while charging, adapter-holding, or still warming up after AC detach.
    private var runtimeText: String {
        telemetry?.runtimeEstimateMinutes
            .map { "≈\(RuntimeText.short(minutes: $0))" } ?? "—"
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "—"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospacedValue = false

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .font(monospacedValue ? .system(.callout, design: .monospaced) : nil)
        } label: {
            Text(label)
                .foregroundColor(.secondary)
        }
        .font(.callout)
    }
}

/// "3 小时 12 分" / "47 分钟" — shared by the battery-info telemetry row
/// and the popover status line (each adds its own qualifier).
enum RuntimeText {
    static func short(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        guard m > 0 else { return "不足 1 分钟" }
        guard m >= 60 else { return "\(m) 分钟" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h) 小时" : "\(h) 小时 \(rem) 分钟"
    }
}
