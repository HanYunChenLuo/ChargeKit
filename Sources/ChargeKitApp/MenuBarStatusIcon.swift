import AppKit
import ChargeKitCore

struct MenuBarStatusIcon: Equatable {
    let symbolName: String
    let lowPowerMode: Bool

    init(phase: ChargePhase, readFailed: Bool, lowPowerMode: Bool) {
        self.lowPowerMode = lowPowerMode
        if readFailed {
            symbolName = "exclamationmark.triangle.fill"
            return
        }
        switch phase {
        case .idle: symbolName = "battery.100percent"
        case .charging: symbolName = "bolt.fill"
        case .chargePaused: symbolName = "clock"
        case .holding: symbolName = "pause.circle"
        case .heatPaused: symbolName = "thermometer.high"
        case .discharging: symbolName = "arrow.down.circle"
        case .systemManaged: symbolName = "gearshape"
        }
    }

    func makeImage() -> NSImage? {
        let primaryStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let primary = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(primaryStyle) else { return nil }
        guard lowPowerMode,
              let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) else {
            primary.isTemplate = true
            return primary
        }

        let spacing: CGFloat = 2
        let primarySize = primary.size
        let leafSize = leaf.size
        let size = NSSize(width: primarySize.width + spacing + leafSize.width,
                          height: max(primarySize.height, leafSize.height))
        let image = NSImage(size: size, flipped: false) { bounds in
            primary.draw(in: NSRect(x: bounds.minX, y: bounds.midY - primarySize.height / 2,
                                    width: primarySize.width, height: primarySize.height))
            leaf.draw(in: NSRect(x: bounds.minX + primarySize.width + spacing,
                                 y: bounds.midY - leafSize.height / 2,
                                 width: leafSize.width, height: leafSize.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}