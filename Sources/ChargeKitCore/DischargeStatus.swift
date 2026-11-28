public enum DischargePhase: Int {
    case idle = 0
    case discharging
    case restoring
    case reachedFloor
    case cancelled
    case failed

    public var ownsAdapter: Bool { self == .discharging || self == .restoring }

    public var result: Self? {
        switch self {
        case .reachedFloor, .cancelled, .failed: return self
        default: return nil
        }
    }
}