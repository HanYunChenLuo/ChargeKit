import AppKit
import ChargeKitCore

struct MenuBarStatusIcon: Equatable {
    let symbolName: String
    let lowPowerMode: Bool

    init(phase: ChargePhase, batteryPercent: Double?, systemIsCharging: Bool?,
         readFailed: Bool, lowPowerMode: Bool) {
        self.lowPowerMode = lowPowerMode
        if readFailed {
            symbolName = "exclamationmark.triangle.fill"
            return
        }
        switch phase {
        case .charging where systemIsCharging == true,
             .idle where systemIsCharging == true,
             .systemManaged where systemIsCharging == true:
            symbolName = "battery.100percent.bolt"
        case _ where lowPowerMode:
            symbolName = Self.batterySymbol(for: batteryPercent) ?? "battery.0percent"
        case .idle, .charging, .systemManaged:
            symbolName = Self.batterySymbol(for: batteryPercent) ?? "battery.0percent"
        case .chargePaused: symbolName = "clock"
        case .holding: symbolName = "pause.circle"
        case .heatPaused: symbolName = "thermometer.high"
        case .discharging:
            symbolName = Self.batterySymbol(for: batteryPercent) ?? "arrow.down.circle"
        }
    }

    private static func batterySymbol(for batteryPercent: Double?) -> String? {
        guard let batteryPercent, batteryPercent.isFinite else { return nil }
        let percent = min(max(batteryPercent, 0), 100)
        let symbolPercent = Int((percent / 25).rounded()) * 25
        return "battery.\(symbolPercent)percent"
    }

    func makeImage() -> NSImage? {
        let showLowPowerColor = lowPowerMode && symbolName.hasPrefix("battery.")
        var style = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if showLowPowerColor {
            // The battery symbols place the fill or bolt in the foreground layer.
            style = style.applying(.init(paletteColors: [.systemYellow, .labelColor, .systemYellow]))
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(style) else { return nil }
        image.isTemplate = !showLowPowerColor
        return image
    }
}