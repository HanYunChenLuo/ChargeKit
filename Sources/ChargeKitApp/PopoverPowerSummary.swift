import SwiftUI

struct PopoverPowerSummary: View {
    let snapshot: ChargeEngine.Snapshot
    let batteryInfo: BatteryInfo

    private var battery: Double? { snapshot.liveBatteryPower }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                reading("适配器输入", watts: snapshot.liveAdapterPower)
                reading("估算主机负载", watts: snapshot.liveHostPower)
                reading(batteryLabel, watts: battery.map(abs))
            }
            if snapshot.systemPowerSource == .external || batteryInfo.adapterVolts != nil
                || batteryInfo.adapterWatts != nil || batteryInfo.adapterProtocol != nil {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("适配器协商", systemImage: "powerplug")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(adapterContractText)
                        Text(adapterVoltageCurrentText)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var adapterContractText: String {
        let protocolName = batteryInfo.adapterProtocol ?? "协议 —"
        let watts = batteryInfo.adapterNegotiatedWatts.map {
            "\($0.formatted(.number.precision(.fractionLength(0...2)))) W"
        }
        return "\(protocolName) · \(watts ?? "— W")"
    }

    private var adapterVoltageCurrentText: String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
        let volts = batteryInfo.adapterVolts?.formatted(format) ?? "—"
        let amps = batteryInfo.adapterContractAmps?.formatted(format) ?? "—"
        return "\(volts) V · \(amps) A"
    }

    private var batteryLabel: String {
        guard let battery, battery.isFinite else { return "电池功率" }
        if battery > 0.2 { return "电池充入" }
        if battery < -0.2 { return "电池放出" }
        return "电池功率"
    }

    private func reading(_ label: String, watts: Double?) -> some View {
        let value = watts.flatMap { $0.isFinite ? $0 : nil }
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f W", max(0, $0)) } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.map { String(format: "%.1f 瓦", max(0, $0)) } ?? "暂不可用"))
    }
}