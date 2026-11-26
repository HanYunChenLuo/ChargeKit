public enum LowPowerModePolicy {
    public enum PowerSource {
        case battery
        case external
    }

    public static let thresholdRange = 5...100
    public static let defaultThreshold = 20

    public struct ManualSession {
        public enum State: String {
            case enabled
            case disabledOnBattery
            case restoring
        }

        private var lastSource: PowerSource?
        public private(set) var state: State?

        public init(state: State? = nil) {
            self.state = state
        }

        public var needsRestore: Bool { state == .restoring }

        public var target: Bool? {
            switch state {
            case .enabled: return true
            case .disabledOnBattery, .restoring: return false
            case nil: return nil
            }
        }

        public mutating func set(_ enabled: Bool) {
            if enabled {
                state = .enabled
            } else {
                state = lastSource == .external ? .restoring : .disabledOnBattery
            }
        }

        public mutating func observe(_ source: PowerSource?) {
            guard let source else { return }
            defer { lastSource = source }
            guard source == .external, lastSource != .external else { return }
            switch state {
            case .enabled: state = .restoring
            case .disabledOnBattery: state = nil
            case .restoring, nil: break
            }
        }

        public mutating func didWrite(_ enabled: Bool) {
            if !enabled && needsRestore { state = nil }
        }
    }

    /// nil leaves the system setting available to manual and scheduled changes.
    public static func target(
        enabled: Bool, source: PowerSource?, batteryPercent: Int?, threshold: Int
    ) -> Bool? {
        guard enabled, let source else { return nil }
        if source == .external { return false }
        guard let batteryPercent, (0...100).contains(batteryPercent),
              batteryPercent < threshold else { return nil }
        return true
    }
}