import Foundation

// MARK: - Charge policy (pure decision state machine)
//
// Layered decisions over telemetry; every evaluation starts from the REAL
// adapter state and converges toward the desired one (no latched desired
// state to restore after an app relaunch):
//
// 1. Heat layer (highest priority): battery temp >= threshold latches a
// pause; temp <= threshold - hysteresis clears it. Unknown/invalid
// temperature clears the latch and never blocks charging.
// 2. Master switch: limiting disabled -> adapter on.
// 3. Sailing layer: pct >= target -> adapter off (run on battery);
// pct <= target - sailBuffer -> adapter back on. Between those the
// current adapter state is kept (natural hysteresis, no flapping).

public struct ChargeConfig: Equatable {
    public var limitingEnabled: Bool
    public var targetPercent: Int
 /// Re-enable charging this many % below the target (sailing bottom buffer).
    public var sailBufferPercent: Int
    public var heatProtectionEnabled: Bool
 /// Pause charging at/above this battery temperature (°C).
    public var heatThresholdC: Double

    public init(
        limitingEnabled: Bool = false,
        targetPercent: Int = 80,
        sailBufferPercent: Int = 5,
        heatProtectionEnabled: Bool = false,
        heatThresholdC: Double = 35
    ) {
        self.limitingEnabled = limitingEnabled
        self.targetPercent = targetPercent
        self.sailBufferPercent = sailBufferPercent
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatThresholdC = heatThresholdC
    }

    public static let heatHysteresisC: Double = 3
}

public enum ChargePhase: Equatable {
 /// Adapter on, charging toward the target.
    case charging
 /// Charging switch on but the battery is not taking current (macOS
 /// optimized charging / native pause). Never returned by ChargePolicy;
 /// the engine sets it from IORegistry's NotChargingReason.
    case chargePaused
 /// Target reached; charging off, adapter keeps powering (sailing).
    case holding
 /// Battery at/above the heat threshold; charging off regardless of sailing.
    case heatPaused
 /// Limiting off and no heat pause; adapter on.
    case idle
 /// A daemon-owned discharge session is running (adapter intentionally
 /// off, battery drains to the floor), or wall power is absent and the
 /// machine simply runs on battery. Never returned by ChargePolicy; the
 /// engine sets it — statusText distinguishes the two by dischargeActive.
    case discharging
}

public struct ChargeDecision: Equatable {
 /// Charging state the engine should enforce (compare against the real
 /// one). With a charging-switch key the adapter keeps powering the
 /// machine while charging is off.
    public let chargingOn: Bool
    public let phase: ChargePhase
}

public struct ChargePolicy {
 /// Latched by the heat layer; survives the dead-band between
 /// threshold-hysteresis and threshold. Not persisted — a fresh policy
 /// re-latches on the next hot reading within one tick.
    public private(set) var heatPauseActive = false

    public init() {}

 /// - Parameters:
 /// - batteryTemp: current TB0T in °C; nil / NaN / ±Inf means unreadable.
 /// - chargingOn: the REAL charging state as just read from SMC.
    public mutating func evaluate(
        batteryPercent pct: Double,
        batteryTemp: Double?,
        chargingOn: Bool,
        config: ChargeConfig
    ) -> ChargeDecision {
        let temp = batteryTemp.flatMap { $0.isFinite ? $0 : nil }

 // 1. Heat layer.
        if !config.heatProtectionEnabled || temp == nil {
            heatPauseActive = false
        } else if temp! >= config.heatThresholdC {
            heatPauseActive = true
        } else if temp! <= config.heatThresholdC - ChargeConfig.heatHysteresisC {
            heatPauseActive = false
        }

        if heatPauseActive {
            return ChargeDecision(chargingOn: false, phase: .heatPaused)
        }

 // 2. Master switch.
        guard config.limitingEnabled else {
            return ChargeDecision(chargingOn: true, phase: .idle)
        }

 // 3. Sailing layer (mid-band keeps the current state).
        let on: Bool
        if chargingOn, pct >= Double(config.targetPercent) {
            on = false
        } else if !chargingOn, pct <= Double(config.targetPercent - config.sailBufferPercent) {
            on = true
        } else {
            on = chargingOn
        }
        return ChargeDecision(chargingOn: on, phase: on ? .charging : .holding)
    }
}

// MARK: - Session rules (S5a: Top Up / Discharge)
//
// Pure predicates for the app-driven session layer. The daemon owns the
// discharge floor loop itself (adapter restoration must not depend on a
// user-session process staying alive); these rules cover what the app
// decides.

public enum SessionRules {
 /// Battery percent at which "full" is assumed (BUIC tops out at 100 but
 /// some BMS readings stall at 99 near full).
    public static let topUpEndedThreshold: Double = 99

 /// Top-up ends when the battery is (essentially) full — BUIC tops out
 /// at 100 but some BMS readings stall at 99 near full — or when the
 /// adapter is gone (a top-up only matters while wall power is present;
 /// after a re-plug the normal limit resumes).
    public static func topUpEnded(batteryPercent: Double, acAttached: Bool) -> Bool {
        batteryPercent >= topUpEndedThreshold || !acAttached
    }

 /// Heat protection cancels an active discharge: draining under load
 /// heats the battery further. Mirrors the policy's heat pause rule
 /// (unknown/invalid temperature never cancels).
    public static func heatCancelsDischarge(
        batteryTemp: Double?, heatProtectionEnabled: Bool, heatThresholdC: Double
    ) -> Bool {
        guard heatProtectionEnabled, let temp = batteryTemp, temp.isFinite else { return false }
        return temp >= heatThresholdC
    }

 // MARK: S7: sleep / auto-discharge predicates

 /// Which battery percentage the limiter acts on ("Hardware
 /// Battery Percentage" parity): the macOS gauge value users see in the
 /// system UI by default, the BMS-direct value with the hardware toggle.
 /// The BMS value is the fallback when IOPowerSources is unreadable —
 /// the limiter must never stall on a missing display value.
    public static func effectiveBatteryPercent(
        hardware: Double, macos: Int?, useHardware: Bool
    ) -> Double {
        if useHardware || macos == nil { return hardware }
        return Double(macos!)
    }

 /// "Prevent sleep until the charge limit" ("Disable Sleep
 /// until Charge Limit"): while charging toward the limit with wall
 /// power present, the engine holds a PreventUserIdleSystemSleep
 /// assertion so the machine does not idle-sleep mid-charge. Released
 /// while sailing (charging deliberately off), heat-paused,
 /// discharging, or unplugged. Lid-close sleep is intentionally not
 /// blocked — charging is SMC hardware state that keeps progressing
 /// while asleep, so blocking it would only stop the user from
 /// sleeping the machine. (Discharge sessions hold their own
 /// daemon-side PreventSystemSleep; see ChargeKitHelper.)
    public static func preventIdleSleep(
        enabled: Bool,
        limitingEnabled: Bool,
        acAttached: Bool,
        chargingOn: Bool,
        batteryPercent: Double,
        targetPercent: Int
    ) -> Bool {
        guard enabled, limitingEnabled, acAttached, chargingOn else { return false }
        return batteryPercent < Double(targetPercent)
    }

 /// Hysteresis above the target before an automatic discharge session
 /// starts. After a discharge the battery sits AT the target; gauge
 /// noise of ±1 % must not restart the drain.
    public static let autoDischargeHysteresisPercent: Double = 2

 /// Auto-discharge (Automatic Discharge): plugged in and the
 /// battery sits meaningfully above the limit -> start a daemon
 /// discharge session down to the limit. Explicit sessions (Top Up /
 /// calibration / a running discharge) and a heat pause take
 /// precedence.
    public static func autoDischargeShouldStart(
        enabled: Bool,
        limitingEnabled: Bool,
        acAttached: Bool,
        batteryPercent: Double,
        targetPercent: Int,
        dischargeActive: Bool,
        topUpActive: Bool,
        calibrationActive: Bool,
        heatPaused: Bool
    ) -> Bool {
        guard enabled, limitingEnabled, acAttached,
              !dischargeActive, !topUpActive, !calibrationActive, !heatPaused
        else { return false }
        return batteryPercent >= Double(targetPercent) + autoDischargeHysteresisPercent
    }

 /// A charging leg counts as "reached the limit" (notification-worthy)
 /// only when it rose by more than the sailing buffer. Sailing top-ups
 /// span exactly the buffer (bottom -> target) and are maintenance, not
 /// a fresh charge to the limit; dragging the limit below the current
 /// battery (rise 0) is not either.
    public static func chargeLegNotifies(
        startPercent: Double, endPercent: Double, sailBufferPercent: Int
    ) -> Bool {
        endPercent - startPercent > Double(sailBufferPercent)
    }
}

// MARK: - Native charge-limit stall detection (S6)
//
// macOS's own charge limit (System Settings → Battery) caps Top Up and the
// calibration charge leg: we hold CHTE on, yet the battery stops well below
// full (e.g. at 80%). The user must raise the macOS limit to 100% by hand —
// no third-party write path exists. Detect the stall and surface it.
//
// Hysteresis guards against the BUIC top-of-charge plateau (observed:
// BUIC pins at 100 for a long while near full while the gauge has already
// rolled to 95) and against slow-charge rates: the battery must fail to
// rise by minRisePercent across stallTicks consecutive ticks before the
// latch sets. AC loss, CHTE turned off externally, or reaching the
// full threshold resets the latch.

public struct NativeLimitStall: Equatable {
 /// Ticks with no meaningful rise before the stall latches (2 s ticks →
 /// 5 ticks = 10 s of no progress).
    public var stallTicks: Int = 5
 /// Minimum rise over the window that still counts as "charging". 0.5%
 /// per minute is far below any real charge rate yet clears the BUIC
 /// plateau quantization.
    public var minRisePercent: Double = 0.5
 /// Percent at/above which the leg is considered complete, never stalled.
    public var fullThreshold: Double = SessionRules.topUpEndedThreshold

 /// Reference point for the current window (percent at window start).
    private var windowStartPercent: Double?
 /// Ticks elapsed in the current window.
    private var windowTicks: Int = 0
 /// Latched result; stays set until reset or a completed/irrelevant leg.
    public private(set) var stalled = false

    public init() {}

 /// One evaluation per engine tick. Call only while a full-charge leg is
 /// active (Top Up, calibration charging/dwell) with wall power present;
 /// call reset when the leg ends or wall power is removed.
 ///
 /// - Parameters:
 /// - batteryPercent: current BUIC reading.
 /// - chargingOn: the REAL CHTE state as just read from SMC. False does
 /// NOT latch by itself — our own sailing write may not be readable
 /// yet (XPC → SMC latency); it resets the window instead, so only a
 /// full window of flat charging proves the macOS cap.
    public mutating func tick(batteryPercent pct: Double, chargingOn: Bool) {
 // Leg complete — never stalled.
        guard pct < fullThreshold else { stalled = false; windowStartPercent = nil; windowTicks = 0; return }

        if stalled {
 // Recovery while latched: the battery rising again disproves the
 // stall (user raised the macOS limit; charging resumed). CHTE
 // state alone does not unlatch — our own sailing writes can flip
 // it without the cap having moved.
            if let anchor = windowStartPercent, pct - anchor >= minRisePercent {
                stalled = false
                windowStartPercent = pct
                windowTicks = 0
            }
            return
        }

 // CHTE off during a full-charge leg: could be the macOS cap, but
 // could also be our own sailing write not yet readable (XPC → SMC
 // latency). Do NOT latch on this alone — freeze the window (re-anchor
 // at the current reading, zero the tick count) so only a full window
 // of flat charging WITH CHTE on can latch.
        guard chargingOn else {
            windowStartPercent = pct
            windowTicks = 0
            return
        }

 // Rising re-anchors the window; a full window with no rise latches.
        if let anchor = windowStartPercent {
            if pct - anchor >= minRisePercent {
                windowStartPercent = pct
                windowTicks = 0
            } else {
                windowTicks += 1
                if windowTicks >= stallTicks { stalled = true }
            }
        } else {
            windowStartPercent = pct
            windowTicks = 0
        }
    }

 /// Clear the latch and the window (leg ended, AC removed, user acted).
    public mutating func reset() {
        windowStartPercent = nil
        windowTicks = 0
        stalled = false
    }
}

// MARK: - Calibration session (S5b)
//
// Full calibration cycle on top of the S5a primitives: charge to full
// (effective target 100, same override as Top Up — the user's config is
// never touched, so there is nothing to back up or restore), dwell at
// full, then a daemon-owned discharge to the floor. When the discharge
// leg ends the normal policy simply recharges toward the user's limit.
//
// The engine drives one tick per poll and applies the returned event.

public struct CalibrationConfig {
 /// Discharge leg floor in %.
    public var dischargeFloorPercent: Int = 10
 /// How long to hold full charge before discharging (seconds).
    public var fullDwellSeconds: Double = 600

    public init(dischargeFloorPercent: Int = 10, fullDwellSeconds: Double = 600) {
        self.dischargeFloorPercent = dischargeFloorPercent
        self.fullDwellSeconds = fullDwellSeconds
    }
}

public struct CalibrationSession {
    public enum Phase: String, Equatable {
        case chargingToFull
        case holdingFull
        case discharging
    }

    public enum Event: Equatable {
 /// Start the daemon discharge leg (floor = config floor).
        case beginDischarge
 /// The discharge leg reached its floor; cycle complete.
        case completed
 /// Wall power gone during a charging phase, or the daemon discharge
 /// never came up; cycle cannot continue.
        case aborted
    }

    public private(set) var phase: Phase = .chargingToFull
    public private(set) var fullSince: Date?
    private var dischargeStartedAt: Date?
 /// The daemon session was seen active in THIS run (the mirror is
 /// synced); only then may an inactive mirror complete the leg at once.
    private var sawDischargeActive = false
 /// The leg was confirmed active in this or a previous run (persisted);
 /// decides completed vs aborted once the resume grace expires.
    public private(set) var legConfirmedActive = false
    private var finished = false

    public var isFinished: Bool { finished }

    public init() {}
 /// Restore a persisted session. `now` anchors the resume grace window:
 /// a fresh mirror needs a tick or two to sync after a relaunch, so an
 /// inactive reading right after resume must not be interpreted as the
 /// end of the leg.
    public init(
        resuming phase: Phase, fullSince: Date?,
        legConfirmedActive: Bool = false, now: Date = Date()
    ) {
        self.phase = phase
        self.fullSince = fullSince
        self.legConfirmedActive = legConfirmedActive
        if phase == .discharging { dischargeStartedAt = now }
    }

 /// One evaluation per engine tick. `dischargeActive` mirrors the daemon
 /// session (NOT set optimistically — the 15 s grace below absorbs the
 /// XPC/poll latency and detects a session that never started).
    public mutating func tick(
        batteryPercent pct: Double,
        acAttached: Bool,
        dischargeActive: Bool,
        now: Date,
        config: CalibrationConfig
    ) -> Event? {
        guard !finished else { return nil }
        switch phase {
        case .chargingToFull:
            guard acAttached else { finished = true; return .aborted }
            guard pct >= SessionRules.topUpEndedThreshold else { return nil }
            phase = .holdingFull
            fullSince = now
            return nil
        case .holdingFull:
            guard acAttached else { finished = true; return .aborted }
            guard let since = fullSince,
                  now.timeIntervalSince(since) >= config.fullDwellSeconds else { return nil }
            phase = .discharging
            dischargeStartedAt = now
            return .beginDischarge
        case .discharging:
 // The daemon owns this leg: floor enforcement, re-asserted cut,
 // fail-safe restore. AC loss is fine — the battery is the power
 // source either way.
            if dischargeActive {
                sawDischargeActive = true
                legConfirmedActive = true
                return nil
            }
 // Mirror reads inactive. Only an inactive reading from a SYNCED
 // mirror (active seen this run) completes the leg at once; a
 // fresh/resumed run stays quiet through the grace window first.
            if sawDischargeActive {
                finished = true
                return .completed
            }
            guard let started = dischargeStartedAt,
                  now.timeIntervalSince(started) <= 15 else {
                finished = true
                return legConfirmedActive ? .completed : .aborted
            }
            return nil  // grace window: XPC/poll lag, or post-resume sync
        }
    }
}
