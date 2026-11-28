import SwiftUI

/// Read-only battery pane. Health and macOS gauge data remain available
/// independently of the live SMC snapshot.
struct BatteryInfoView: View {
    let info: BatteryInfo
    let snapshot: ChargeEngine.Snapshot
    let statusText: String
    let lowPowerMode: Bool

    private var telemetry: ChargeEngine.Snapshot? { snapshot.readError == nil ? snapshot : nil }

    var body: some View {
        Form {
            Section("当前状态") {
                VStack(alignment: .leading, spacing: 4) {
                    BatteryGaugeView(
                        percent: snapshot.hasBatteryPercent ? snapshot.batteryPercent : nil,
                        phase: snapshot.isDrainingWhileChargeManaged ? .discharging : snapshot.phase,
                        lowPowerMode: lowPowerMode)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
            Section("电源流向") {
                if snapshot.liveAdapterPower != nil || snapshot.liveBatteryPower != nil {
                    PowerFlowView(
                        dcInPower: snapshot.liveAdapterPower,
                        batteryPower: snapshot.liveBatteryPower,
                        hostPower: snapshot.liveHostPower)
                } else {
                    Label("实时功率暂不可用", systemImage: "bolt.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("电池健康") {
                InfoRow(label: "系统报告的健康度",
                        value: info.healthPercent.map { "\($0)%" } ?? "—")
                InfoRow(label: "设计容量",
                        value: info.designCapacitymAh.map { "\($0) mAh" } ?? "—")
                InfoRow(label: "硬件满充容量",
                        value: info.fullChargeCapacitymAh.map { "\($0) mAh" } ?? "—")
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
                InfoRow(label: "适配器输入功率", value: watts(snapshot.liveAdapterPower))
                InfoRow(label: "估算主机负载", value: watts(snapshot.liveHostPower))
                InfoRow(label: "电池电压", value: batteryVoltageText)
                InfoRow(label: "电池电流", value: batteryCurrentText)
            }

            Section("电源适配器") {
                InfoRow(label: "适配器协商电压", value: info.adapterVolts.map(voltageText) ?? "—")
                InfoRow(label: "适配器报告的功率规格", value: info.adapterWatts.map { "\($0) W" } ?? "—")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
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

    private func voltageText(_ volts: Double) -> String {
        "\(volts.formatted(.number.precision(.fractionLength(0...2)))) V"
    }

    private var batteryVoltageText: String {
        guard let volts = telemetry?.batteryVolts, volts.isFinite else { return "—" }
        return String(format: "%.2f V", volts)
    }

    private var batteryCurrentText: String {
        guard let amps = telemetry?.batteryAmps, amps.isFinite else { return "暂不可用" }
        if amps == 0 { return "0.000 A" }
        let direction = amps > 0 ? "充电" : "放电"
        return "\(String(format: "%.3f A", abs(amps))) · \(direction)"
    }

 /// Runtime until empty from the engine's EMA-smoothed estimate; "—"
 /// while charging, adapter-holding, or still warming up after AC detach.
    private var runtimeText: String {
        telemetry?.runtimeEstimateMinutes
            .map { "≈\(RuntimeText.short(minutes: $0))" } ?? "—"
    }

    private func watts(_ value: Double?) -> String {
        value.flatMap { $0.isFinite ? String(format: "%.1f W", $0) : nil } ?? "—"
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
