import Foundation

// MARK: - Battery runtime estimate (pure estimator)
//
// The gauge power (B0AV × B0AC) is instantaneous and bursty: consecutive
// ticks can differ several-fold under a spiky load. The estimate feeds
// every tick's battery power through an exponential moving average
// (τ = 30 s) and publishes only after a warm-up window, so the shown
// number settles instead of jumping. Any non-discharging sample
// (charging, or the adapter-hold mode where B0AC reads exactly 0) clears
// the filter — the estimate only ever describes an ongoing, sustained
// discharge.
public struct RuntimeEstimator {
 /// EMA time constant in seconds; larger = steadier, slower to react.
    public let timeConstant: Double
 /// Ticks required after (re)entering discharge before an estimate is
 /// published (8 ticks × 2 s ≈ 16 s after AC detach).
    public let warmupTicks: Int
 /// Sustained draw at or below this (W) counts as "not discharging"
 /// (adapter hold, ADC noise) and keeps the estimate hidden. Real
 /// battery draws sit at a few watts; a sub-watt draw would extrapolate
 /// to hundreds of hours of noise.
    public let minDischargeWatts: Double

 /// Smoothed battery power in W (negative = discharging). nil while idle.
    public private(set) var emaWatts: Double?
    private var ticks = 0

    public init(
        timeConstant: Double = 30,
        warmupTicks: Int = 8,
        minDischargeWatts: Double = 0.5
    ) {
        self.timeConstant = timeConstant
        self.warmupTicks = warmupTicks
        self.minDischargeWatts = minDischargeWatts
    }

 /// Feed one tick of battery power (W; negative = discharging — exactly
 /// what the engine snapshot carries). A sample at or above
 /// −minDischargeWatts (charging, adapter hold, noise) resets the filter.
    public mutating func addSample(batteryPower: Double, dt: Double) {
        guard batteryPower < -minDischargeWatts else {
            reset()
            return
        }
        if let ema = emaWatts {
            let alpha = max(0, 1 - exp(-dt / timeConstant))
            emaWatts = ema + alpha * (batteryPower - ema)
        } else {
            emaWatts = batteryPower
        }
        ticks += 1
    }

    public mutating func reset() {
        emaWatts = nil
        ticks = 0
    }

    public var isReady: Bool { ticks >= warmupTicks }

 /// Estimated minutes until the battery is empty. nil until the filter
 /// is warm AND both inputs are present and positive — a missing
 /// remaining-charge or voltage read never fabricates a number.
    public func estimatedMinutes(remainingMah: Double?, voltage: Double?) -> Double? {
        guard isReady, let ema = emaWatts, ema <= -minDischargeWatts,
              let mah = remainingMah, mah > 0,
              let volts = voltage, volts > 0 else { return nil }
        let remainingWh = mah / 1000 * volts
        return remainingWh / -ema * 60
    }
}
