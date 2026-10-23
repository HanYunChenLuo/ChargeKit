import Foundation
import ChargeKitCore

// ChargePolicy acceptance tests (S4): simulated threshold sequences for
// sailing stop/resume, heat pause/clear, and their interactions.
// Zero-dependency runner — this SPM-only CLT has no usable test framework
// runtime. Run: swift run policy-tests

var passed = 0
var failed = 0

func check(
    _ label: String,
    _ condition: @autoclosure () -> Bool,
    file: String = #fileID, line: UInt = #line
) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(file):\(line) \(label)")
    }
}

var policy = ChargePolicy()

func eval(
    _ pct: Double, _ temp: Double?, _ chargingOn: Bool, _ c: ChargeConfig
) -> ChargeDecision {
    policy.evaluate(
        batteryPercent: pct, batteryTemp: temp,
        chargingOn: chargingOn, config: c)
}

// MARK: - Sailing

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, sailBufferPercent: 5)
    check("charging below target", eval(75, 30, true, c).phase == .charging)
    check("at target: charging off", eval(80, 30, true, c).chargingOn == false)
    check("at target: holding", eval(80, 30, true, c).phase == .holding)
    check("mid-band keeps charging off", eval(79, 30, false, c).chargingOn == false)
    check("bottom buffer: charging on", eval(75, 30, false, c).chargingOn == true)
    check("bottom buffer: charging", eval(75, 30, false, c).phase == .charging)
    check("mid-band keeps charging on", eval(79, 30, true, c).chargingOn == true)
}

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 90, sailBufferPercent: 10)
    check("wide buffer: 85 still holding", eval(85, 30, false, c).chargingOn == false)
    check("wide buffer: 80 resumes", eval(80, 30, false, c).chargingOn == true)
}

// MARK: - Limiting master switch

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: false, targetPercent: 80)
    let d = eval(95, 30, false, c)
    check("limiting off restores charging", d.chargingOn == true)
    check("limiting off: idle", d.phase == .idle)
}

// MARK: - Heat protection

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, heatProtectionEnabled: true, heatThresholdC: 35)
    check("below threshold: normal", eval(70, 34.9, true, c).chargingOn == true)
    check("at threshold: pause", eval(70, 35, true, c).chargingOn == false)
    check("at threshold: heatPaused", eval(70, 35, true, c).phase == .heatPaused)
    check("dead-band stays paused", eval(70, 33, false, c).chargingOn == false)
    check("dead-band phase", eval(70, 33, false, c).phase == .heatPaused)
    check("below hysteresis: resume", eval(70, 32, false, c).chargingOn == true)
    check("below hysteresis: charging", eval(70, 32, false, c).phase == .charging)
}

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, heatProtectionEnabled: true, heatThresholdC: 35)
    check("heat overrides sailing recovery", eval(70, 36, false, c).chargingOn == false)
    check("heat phase while below buffer", eval(70, 36, false, c).phase == .heatPaused)
}

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: false, heatProtectionEnabled: true, heatThresholdC: 35)
    check("heat pauses even when limiting off", eval(50, 40, true, c).chargingOn == false)
    check("heat phase with limiting off", eval(50, 40, true, c).phase == .heatPaused)
    check("cooled: charging restores", eval(50, 30, false, c).chargingOn == true)
    check("cooled: idle", eval(50, 30, false, c).phase == .idle)
}

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, heatProtectionEnabled: true, heatThresholdC: 35)
    check("nil temp never blocks", eval(70, nil, true, c).chargingOn == true)
    check("NaN temp never blocks", eval(70, .nan, true, c).chargingOn == true)
    check("Inf temp never blocks", eval(70, .infinity, true, c).chargingOn == true)
    check("nil temp: charging", eval(70, nil, true, c).phase == .charging)
}

do {
    policy = ChargePolicy()
    var c = ChargeConfig(limitingEnabled: true, heatProtectionEnabled: true, heatThresholdC: 35)
    check("heat pause latched", eval(70, 40, true, c).chargingOn == false)
    c.heatProtectionEnabled = false
    check("disabling heat clears pause", eval(70, 40, false, c).chargingOn == true)
    check("disabling heat: charging", eval(70, 40, false, c).phase == .charging)
}

// MARK: - Full sequences (acceptance: simulated threshold crossings)

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, sailBufferPercent: 5)
 // (pct, real adapter state) walk: charge to 80, sag, fall to 75, charge again.
    let script: [(Double, Bool)] = [
        (72, true), (78, true), (80, true), (80, false),
        (79, false), (77, false), (75, false), (75, true), (78, true),
    ]
    let expectedOn = [true, true, false, false, false, false, true, true, true]
    let expectedPhase: [ChargePhase] = [
        .charging, .charging, .holding, .holding,
        .holding, .holding, .charging, .charging, .charging,
    ]
    for (i, (pct, adapter)) in script.enumerated() {
        let d = eval(pct, 30, adapter, c)
        check("seq step \(i) adapter", d.chargingOn == expectedOn[i])
        check("seq step \(i) phase", d.phase == expectedPhase[i])
    }
}

do {
    policy = ChargePolicy()
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 80, sailBufferPercent: 5, heatProtectionEnabled: true, heatThresholdC: 35)
    var charging = true

    var d = eval(80, 30, charging, c); charging = d.chargingOn
    check("sail: holding at target", charging == false)

    d = eval(77, 36, charging, c); charging = d.chargingOn
    check("hot during sail: heatPaused", d.phase == .heatPaused)
    check("hot during sail: charging off", charging == false)

    d = eval(73, 34.5, charging, c); charging = d.chargingOn
    check("hot below buffer: still heatPaused", d.phase == .heatPaused)
    check("hot below buffer: charging off", charging == false)

    d = eval(73, 31, charging, c); charging = d.chargingOn
    check("cooled: resume charging", d.phase == .charging)
    check("cooled: charging on", charging == true)
}

// MARK: - S5a: Top Up / Discharge sessions

do {
    policy = ChargePolicy()
 // Top-up rides the sailing layer with an effective target of 100.
    let c = ChargeConfig(limitingEnabled: true, targetPercent: 100, sailBufferPercent: 5)
    check("topup target100: 95 charges", eval(95, 30, true, c).chargingOn == true)
    check("topup target100: 99 keeps charging", eval(99, 30, true, c).chargingOn == true)
    check("topup target100: 100 stops", eval(100, 30, true, c).chargingOn == false)
    check("topup target100: 100 holding", eval(100, 30, true, c).phase == .holding)
}

do {
    check("topup end: 98.9 with AC continues", !SessionRules.topUpEnded(batteryPercent: 98.9, acAttached: true))
    check("topup end: 99 with AC ends", SessionRules.topUpEnded(batteryPercent: 99, acAttached: true))
    check("topup end: 100 with AC ends", SessionRules.topUpEnded(batteryPercent: 100, acAttached: true))
    check("topup end: unplug ends", SessionRules.topUpEnded(batteryPercent: 50, acAttached: false))
    check("topup end: unplug ends even near full", SessionRules.topUpEnded(batteryPercent: 99.5, acAttached: false))
}

do {
    func hc(_ temp: Double?, _ enabled: Bool, _ threshold: Double) -> Bool {
        SessionRules.heatCancelsDischarge(
            batteryTemp: temp, heatProtectionEnabled: enabled, heatThresholdC: threshold)
    }
    check("discharge heat-cancel: nil temp no", hc(nil, true, 35) == false)
    check("discharge heat-cancel: NaN no", hc(.nan, true, 35) == false)
    check("discharge heat-cancel: Inf no", hc(.infinity, true, 35) == false)
    check("discharge heat-cancel: hot yes", hc(35, true, 35) == true)
    check("discharge heat-cancel: cool no", hc(34.9, true, 35) == false)
    check("discharge heat-cancel: heat off no", hc(40, false, 35) == false)
}

// MARK: - S6: Native charge-limit stall detection

do {
 // Flat battery below full with charging on: anchor + stallTicks flat
 // ticks latch the stall.
    var s = NativeLimitStall()
    s.stallTicks = 5
    s.tick(batteryPercent: 80, chargingOn: true)  // anchor
    for i in 0..<4 {
        s.tick(batteryPercent: 80, chargingOn: true)
        check("stall: tick \(i+1) not yet latched", !s.stalled)
    }
    s.tick(batteryPercent: 80, chargingOn: true)
    check("stall: latched after window", s.stalled)

 // Rising battery re-anchors the window; never latches.
    var r = NativeLimitStall()
    r.stallTicks = 5
    var pct = 80.0
    for _ in 0..<20 {
        r.tick(batteryPercent: pct, chargingOn: true)
        pct += 0.3  // below minRise per tick but accumulates — re-anchors
    }
    check("stall: slow rise never latches", !r.stalled)

 // CHTE off does NOT latch by itself (could be our own sailing write not
 // yet readable); it resets the window instead — and never latches on its
 // own. Only a full window of flat charging WITH CHTE on proves the cap.
    var e = NativeLimitStall()
    e.stallTicks = 5
    e.tick(batteryPercent: 80, chargingOn: false)
    check("stall: CHTE off alone does not latch", !e.stalled)
    for _ in 0..<6 { e.tick(batteryPercent: 80, chargingOn: false) }
    check("stall: CHTE off never latches", !e.stalled)
 // ...but once charging resumes and the battery still will not rise, the
 // flat window latches as before. CHTE off froze the window at anchor=80,
 // ticks=0; from there stallTicks=5 flat ticks latch.
    for _ in 0..<4 { e.tick(batteryPercent: 80, chargingOn: true) }
    check("stall: CHTE back on, flat window not yet latched", !e.stalled)
    e.tick(batteryPercent: 80, chargingOn: true)  // 5th flat tick -> latch
    check("stall: CHTE back on + full flat window latches", e.stalled)

 // At/over the full threshold the leg is complete, never stalled.
    var f = NativeLimitStall()
    f.tick(batteryPercent: 99, chargingOn: true)
    f.tick(batteryPercent: 99, chargingOn: false)
    check("stall: at full never latches", !f.stalled)

 // reset clears latch and window.
    var z = NativeLimitStall()
    z.tick(batteryPercent: 80, chargingOn: false)
    z.reset()
    check("stall: reset clears latch", !z.stalled)
    z.tick(batteryPercent: 80, chargingOn: true)
    check("stall: after reset window restarts", !z.stalled)

 // Recovery while latched: the battery rising again unlatches (user
 // raised the macOS limit; charging resumed under our feet). Latch first
 // via anchor + 5 flat ticks, then recover.
    var rec = NativeLimitStall()
    rec.stallTicks = 5
    rec.tick(batteryPercent: 80, chargingOn: true)  // anchor
    for _ in 0..<4 { rec.tick(batteryPercent: 80, chargingOn: true) }
    rec.tick(batteryPercent: 80, chargingOn: true)  // 5th flat tick -> latch
    check("stall: latched before recovery", rec.stalled)
    rec.tick(batteryPercent: 80, chargingOn: true)
    check("stall: still flat stays latched", rec.stalled)
    rec.tick(batteryPercent: 81, chargingOn: true)
    check("stall: rising battery unlatches", !rec.stalled)

 // A leg that completes while latched clears too.
    var done = NativeLimitStall()
    done.stallTicks = 5
    done.tick(batteryPercent: 80, chargingOn: true)  // anchor
    for _ in 0..<5 { done.tick(batteryPercent: 80, chargingOn: true) }
    check("stall: latched before completion", done.stalled)
    done.tick(batteryPercent: 99, chargingOn: false)
    check("stall: leg complete unlatches", !done.stalled)
}

// MARK: - S5b: Calibration session

do {
    let cfg = CalibrationConfig(dischargeFloorPercent: 10, fullDwellSeconds: 600)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func step(
        _ s: inout CalibrationSession, _ pct: Double, _ ac: Bool,
        _ dis: Bool, _ t: Date, _ c: CalibrationConfig = cfg
    ) -> CalibrationSession.Event? {
        s.tick(batteryPercent: pct, acAttached: ac, dischargeActive: dis, now: t, config: c)
    }

    var cal = CalibrationSession()
    check("cal: below full keeps charging", step(&cal, 80, true, false, t0) == nil)
    check("cal: phase chargingToFull", cal.phase == .chargingToFull)
    check("cal: unplug during charge aborts", {
        var s = CalibrationSession()
        let e = step(&s, 80, false, false, t0)
        return e == .aborted && s.isFinished
    }())
    check("cal: reach full -> dwell", {
        var s = CalibrationSession()
        let e = step(&s, 99, true, false, t0)
        return e == nil && s.phase == .holdingFull && s.fullSince == t0
    }())
    check("cal: dwell not elapsed stays", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        return step(&s, 100, true, false, t0.addingTimeInterval(599)) == nil
            && s.phase == .holdingFull
    }())
    check("cal: unplug during dwell aborts", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        return step(&s, 99, false, false, t0.addingTimeInterval(10)) == .aborted && s.isFinished
    }())
    check("cal: dwell elapsed -> begin discharge", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        let e = step(&s, 100, true, false, t0.addingTimeInterval(600))
        return e == .beginDischarge && s.phase == .discharging
    }())
    check("cal: discharge grace window (daemon not yet visible)", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        return step(&s, 100, true, false, t0.addingTimeInterval(602)) == nil
    }())
    check("cal: daemon never started -> abort after grace", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        let e = step(&s, 60, true, false, t0.addingTimeInterval(620))
        return e == .aborted && s.isFinished
    }())
    check("cal: discharge active holds", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        return step(&s, 50, true, true, t0.addingTimeInterval(605)) == nil
    }())
    check("cal: AC loss during discharge is fine", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        return step(&s, 50, false, true, t0.addingTimeInterval(605)) == nil
    }())
    check("cal: discharge ends -> completed", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        _ = step(&s, 50, true, true, t0.addingTimeInterval(605))
        let e = step(&s, 10, true, false, t0.addingTimeInterval(4000))
        return e == .completed && s.isFinished
    }())
    check("cal: finished session is inert", {
        var s = CalibrationSession()
        _ = step(&s, 80, false, false, t0)  // abort
        return s.tick(batteryPercent: 99, acAttached: true, dischargeActive: false,
                      now: t0, config: cfg) == nil
    }())
    check("cal: resume in dwell keeps timestamp", {
        var s = CalibrationSession(resuming: .holdingFull, fullSince: t0)
        return step(&s, 100, true, false, t0.addingTimeInterval(599)) == nil
            && step(&s, 100, true, false, t0.addingTimeInterval(601)) == .beginDischarge
    }())
    check("cal: resume in discharge re-anchors grace at resume (real sequence)", {
 // fullSince = dwell start; discharge leg began +600 s; app relaunched
 // at +900 s with the daemon session still running. The stale
 // fullSince must NOT expire the grace.
        var s = CalibrationSession(resuming: .discharging, fullSince: t0, now: t0.addingTimeInterval(900))
        return step(&s, 50, true, false, t0.addingTimeInterval(902)) == nil
            && step(&s, 50, true, true, t0.addingTimeInterval(904)) == nil  // mirror synced
            && step(&s, 50, true, false, t0.addingTimeInterval(906)) == .completed
    }())
    check("cal: resume with daemon done while app was dead -> completed", {
 // The leg was confirmed active pre-crash (persisted); the daemon
 // finished at the floor during the app's downtime.
        var s = CalibrationSession(
            resuming: .discharging, fullSince: t0, legConfirmedActive: true, now: t0.addingTimeInterval(900))
        return step(&s, 10, true, false, t0.addingTimeInterval(902)) == nil  // grace
            && step(&s, 10, true, false, t0.addingTimeInterval(916)) == .completed
    }())
    check("cal: resume before daemon ever started -> abort after grace", {
        var s = CalibrationSession(resuming: .discharging, fullSince: t0, now: t0)
        return step(&s, 50, true, false, t0.addingTimeInterval(10)) == nil
            && step(&s, 50, true, false, t0.addingTimeInterval(20)) == .aborted
    }())
    check("cal: confirmed active is persisted through the run", {
        var s = CalibrationSession()
        _ = step(&s, 99, true, false, t0)
        _ = step(&s, 100, true, false, t0.addingTimeInterval(600))
        _ = step(&s, 50, true, true, t0.addingTimeInterval(605))
        return s.legConfirmedActive == true
    }())
}

// MARK: - S7: prevent idle sleep until the charge limit

do {
    func ps(_ enabled: Bool, _ limiting: Bool, _ ac: Bool, _ charging: Bool,
            _ pct: Double, _ target: Int) -> Bool {
        SessionRules.preventIdleSleep(
            enabled: enabled, limitingEnabled: limiting, acAttached: ac,
            chargingOn: charging, batteryPercent: pct, targetPercent: target)
    }
    check("sleep: disabled -> off", ps(false, true, true, true, 60, 80) == false)
    check("sleep: limiting off -> off", ps(true, false, true, true, 60, 80) == false)
    check("sleep: no AC -> off", ps(true, true, false, true, 60, 80) == false)
    check("sleep: sailing hold (charging off) -> off", ps(true, true, true, false, 78, 80) == false)
    check("sleep: charging below target -> on", ps(true, true, true, true, 60, 80) == true)
    check("sleep: just below target -> on", ps(true, true, true, true, 79.9, 80) == true)
    check("sleep: charging at target -> off", ps(true, true, true, true, 80, 80) == false)
    check("sleep: above target -> off", ps(true, true, true, true, 85, 80) == false)
 // Full-charge legs (Top Up / calibration) ride an effective target of 100.
    check("sleep: full-charge leg 95 -> on", ps(true, true, true, true, 95, 100) == true)
    check("sleep: full-charge leg 99.5 -> on", ps(true, true, true, true, 99.5, 100) == true)
    check("sleep: full reached -> off", ps(true, true, true, true, 100, 100) == false)
}

// MARK: - battery-percent basis (hardware-percentage toggle)

do {
    func basis(_ hw: Double, _ macos: Int?, _ useHardware: Bool) -> Double {
        SessionRules.effectiveBatteryPercent(
            hardware: hw, macos: macos, useHardware: useHardware)
    }
    check("basis: hardware on -> BMS value", basis(82, 85, true) == 82)
    check("basis: hardware on, macos nil -> BMS value", basis(82, nil, true) == 82)
    check("basis: hardware off -> macOS value", basis(82, 85, false) == 85)
 // BMS is the fallback when IOPowerSources is unreadable: the limiter
 // must never stall on a missing display value.
    check("basis: hardware off, macos nil -> BMS fallback", basis(82, nil, false) == 82)
    check("basis: equal values -> identical either way", basis(80, 80, false) == 80)
}

// MARK: - S7: auto-discharge

do {
    func ad(
        _ enabled: Bool, _ pct: Double, _ target: Int,
        limiting: Bool = true, ac: Bool = true,
        dis: Bool = false, top: Bool = false, cal: Bool = false, heat: Bool = false
    ) -> Bool {
        SessionRules.autoDischargeShouldStart(
            enabled: enabled, limitingEnabled: limiting, acAttached: ac,
            batteryPercent: pct, targetPercent: target,
            dischargeActive: dis, topUpActive: top,
            calibrationActive: cal, heatPaused: heat)
    }
    check("autodis: disabled", ad(false, 95, 80) == false)
    check("autodis: limiting off", ad(true, 95, 80, limiting: false) == false)
    check("autodis: unplugged", ad(true, 95, 80, ac: false) == false)
    check("autodis: discharge running", ad(true, 95, 80, dis: true) == false)
    check("autodis: top up running", ad(true, 95, 80, top: true) == false)
    check("autodis: calibration running", ad(true, 95, 80, cal: true) == false)
    check("autodis: heat paused", ad(true, 95, 80, heat: true) == false)
    check("autodis: at target -> no", ad(true, 80, 80) == false)
    check("autodis: +1 (noise band) -> no", ad(true, 81, 80) == false)
    check("autodis: +2 hysteresis -> yes", ad(true, 82, 80) == true)
    check("autodis: well above -> yes", ad(true, 95, 80) == true)
    check("autodis: above but below system clamp irrelevant", ad(true, 77, 75) == true)
}

// MARK: - S7: charge-leg notification predicate

do {
    func cn(_ start: Double, _ end: Double, _ buffer: Int) -> Bool {
        SessionRules.chargeLegNotifies(startPercent: start, endPercent: end, sailBufferPercent: buffer)
    }
    check("notify: fresh charge 30->75 notifies", cn(30, 75, 5) == true)
    check("notify: sailing top-up 75->80 silent", cn(75, 80, 5) == false)
    check("notify: sailing top-up 74.9->80 notifies (noise edge)", cn(74.9, 80, 5) == true)
    check("notify: limit dragged below battery (rise 0) silent", cn(85, 85, 5) == false)
    check("notify: exactly buffer rise silent", cn(70, 75, 5) == false)
    check("notify: one over buffer notifies", cn(70, 75.1, 5) == true)
}

// MARK: - S7: scheduled tasks

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!  // fixed, no DST

    func t(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    func rule(
        _ time: (Int, Int), _ repeatMode: ScheduleRepeat,
        createdAt: Date = t(2026, 3, 1, 8, 0),
        action: ScheduleAction = .setLimit(60)
    ) -> ScheduleRule {
        ScheduleRule(hour: time.0, minute: time.1, repeatMode: repeatMode,
                    action: action, createdAt: createdAt)
    }
 // 2026-03-02 is a Monday (weekday index 1=Mon ... 7=Sun).
    func fireCount(
        _ e: inout ScheduleEngine,
        _ rules: [ScheduleRule],
        _ now: Date,
        calendar: Calendar = cal,
        workdayCalendar: WorkdayCalendar = WorkdayCalendar()
    ) -> Int {
        e.dueRules(
            rules,
            now: now,
            calendar: calendar,
            workdayCalendar: workdayCalendar).count
    }

    var e = ScheduleEngine()
 // Daily: fires at the minute, not before, once per day.
    let daily = rule((9, 0), .daily)
    check("sched: daily before time no", fireCount(&e, [daily], t(2026, 3, 2, 8, 59)) == 0)
    check("sched: daily at time fires", fireCount(&e, [daily], t(2026, 3, 2, 9, 0)) == 1)
    check("sched: daily same day dedupe", fireCount(&e, [daily], t(2026, 3, 2, 9, 30)) == 0)
    check("sched: daily next day fires", fireCount(&e, [daily], t(2026, 3, 3, 9, 0)) == 1)

 // Weekdays: Mon–Fri only.
    let wd = rule((9, 0), .weekdays)
    e = ScheduleEngine()
    check("sched: weekdays Mon fires", fireCount(&e, [wd], t(2026, 3, 2, 9, 30)) == 1)
    check("sched: weekdays Fri fires", fireCount(&e, [wd], t(2026, 3, 6, 9, 30)) == 1)
    check("sched: weekdays Sat no", fireCount(&e, [wd], t(2026, 3, 7, 9, 30)) == 0)
    check("sched: weekdays Sun no", fireCount(&e, [wd], t(2026, 3, 8, 9, 30)) == 0)

 // Region work calendars can override the ordinary Monday-Friday rule.
 // The test fixture represents a complete external-service response.
    let regionalWorkdays = WorkdayCalendar(
        region: .mainlandChina,
        workingDateKeysByYear: [2026: [20260303, 20260307]])
    let regionalWeekdayRule = rule((9, 0), .weekdays, createdAt: t(2026, 1, 1))
    e = ScheduleEngine()
    check("sched: regional weekday holiday does not fire",
          fireCount(&e, [regionalWeekdayRule], t(2026, 3, 2, 9, 30),
                    workdayCalendar: regionalWorkdays) == 0)
    e = ScheduleEngine()
    check("sched: regional weekday fires",
          fireCount(&e, [regionalWeekdayRule], t(2026, 3, 3, 9, 30),
                    workdayCalendar: regionalWorkdays) == 1)
    e = ScheduleEngine()
    check("sched: makeup Saturday fires",
          fireCount(&e, [regionalWeekdayRule], t(2026, 3, 7, 9, 30),
                    workdayCalendar: regionalWorkdays) == 1)
    e = ScheduleEngine()
    check("sched: ordinary Saturday remains off",
          fireCount(&e, [regionalWeekdayRule], t(2026, 3, 14, 9, 30),
                    workdayCalendar: regionalWorkdays) == 0)
    let fallbackWorkCalendar = WorkdayCalendar(region: .mainlandChina)
    check("sched: missing regional data falls back to weekdays",
          fallbackWorkCalendar.isWorkingDay(t(2026, 3, 2), calendar: cal)
            && !fallbackWorkCalendar.isWorkingDay(t(2026, 3, 7), calendar: cal))

 // Weekly: only the selected weekdays.
    let weekly = rule((9, 0), .weekly([1, 3, 5]))  // Mon/Wed/Fri
    e = ScheduleEngine()
    check("sched: weekly Mon fires", fireCount(&e, [weekly], t(2026, 3, 2, 9, 30)) == 1)
    check("sched: weekly Tue no", fireCount(&e, [weekly], t(2026, 3, 3, 9, 30)) == 0)
    check("sched: weekly Wed fires", fireCount(&e, [weekly], t(2026, 3, 4, 9, 30)) == 1)
    check("sched: weekly Sun no", fireCount(&e, [weekly], t(2026, 3, 8, 9, 30)) == 0)

 // Biweekly: anchor week Mar 2 — fires, off week Mar 9 does not, Mar 16 does.
    let bi = rule((9, 0), .biweekly(weekdays: [1], anchor: t(2026, 3, 2)))
    e = ScheduleEngine()
    check("sched: biweekly anchor week fires", fireCount(&e, [bi], t(2026, 3, 2, 9, 30)) == 1)
    check("sched: biweekly off week no", fireCount(&e, [bi], t(2026, 3, 9, 9, 30)) == 0)
    check("sched: biweekly next on week fires", fireCount(&e, [bi], t(2026, 3, 16, 9, 30)) == 1)

 // Monthly: the 31st runs only in months that have 31 days .
 // createdAt predates the January occurrence (the default Mar 1 would
 // correctly suppress the earlier date via the retro-fire guard).
    let m31 = rule((9, 0), .monthly(day: 31), createdAt: t(2026, 1, 1))
    e = ScheduleEngine()
    check("sched: monthly 31 Jan fires", fireCount(&e, [m31], t(2026, 1, 31, 9, 30)) == 1)
    check("sched: monthly 31 Feb skipped", fireCount(&e, [m31], t(2026, 2, 28, 9, 30)) == 0)
    check("sched: monthly 31 Mar fires", fireCount(&e, [m31], t(2026, 3, 31, 9, 30)) == 1)

 // Yearly: fixed month/day only.
    let yr = rule((9, 0), .yearly(month: 3, day: 15))
    e = ScheduleEngine()
    check("sched: yearly Mar 15 fires", fireCount(&e, [yr], t(2026, 3, 15, 9, 30)) == 1)
    check("sched: yearly Mar 14 no", fireCount(&e, [yr], t(2026, 3, 14, 9, 30)) == 0)
    check("sched: yearly next year fires", fireCount(&e, [yr], t(2027, 3, 15, 9, 30)) == 1)

 // Don't Repeat: fires once, comes back disabled, never fires again.
    let once = rule((9, 0), .never)
    e = ScheduleEngine()
    let fired = e.dueRules([once], now: t(2026, 3, 2, 9, 30), calendar: cal)
    check("sched: never fires once", fired.count == 1)
    check("sched: never returns disabled", fired.first?.enabled == false)
    let spent = fired.first!
    check("sched: never next day inert", fireCount(&e, [spent], t(2026, 3, 3, 9, 30)) == 0)
    check("sched: never next week inert", fireCount(&e, [spent], t(2026, 3, 9, 9, 30)) == 0)

 // Fresh rule created after its time never fires retroactively.
    let fresh = rule((9, 0), .daily, createdAt: t(2026, 3, 2, 14, 0))
    e = ScheduleEngine()
    check("sched: fresh rule no retro fire", fireCount(&e, [fresh], t(2026, 3, 2, 15, 0)) == 0)
    check("sched: fresh rule next day fires", fireCount(&e, [fresh], t(2026, 3, 3, 9, 0)) == 1)

 // Saving an editor draft must preserve system changes that happened
 // while the sheet was open, especially a one-shot auto-disable.
    let originalOneShot = rule((9, 0), .never, createdAt: t(2026, 1, 1))
    var consumedOneShot = originalOneShot
    consumedOneShot.enabled = false
    var staleEditorDraft = originalOneShot
    staleEditorDraft.hour = 10
    let committedOneShot = ScheduleRuleCommit.reconcile(
        draft: staleEditorDraft,
        original: originalOneShot,
        current: consumedOneShot,
        enabledWasEdited: false,
        now: t(2026, 3, 2, 10, 30))
    check("sched edit: save preserves consumed one-shot disable", !committedOneShot.enabled)
    check("sched edit: save keeps unrelated draft changes", committedOneShot.hour == 10)
    let explicitlyReenabled = ScheduleRuleCommit.reconcile(
        draft: originalOneShot,
        original: originalOneShot,
        current: consumedOneShot,
        enabledWasEdited: true,
        now: t(2026, 3, 2, 10, 30))
    check("sched edit: deliberate re-enable starts at save time",
          explicitlyReenabled.enabled && explicitlyReenabled.createdAt == t(2026, 3, 2, 10, 30))
    let newlySavedRule = ScheduleRuleCommit.reconcile(
        draft: originalOneShot,
        original: nil,
        current: nil,
        enabledWasEdited: false,
        now: t(2026, 3, 2, 10, 30))
    check("sched edit: new rule creation time is save time",
          newlySavedRule.createdAt == t(2026, 3, 2, 10, 30))

 // Explicitly re-enabling a one-shot that already fired today must clear
 // the firing bookkeeping so a later same-day time can fire again.
    let spentOnce = rule((11, 0), .never, createdAt: t(2026, 3, 1))
    var firedOnce = spentOnce
    firedOnce.enabled = false
    e = ScheduleEngine()
    let firstFire = e.dueRules([spentOnce], now: t(2026, 3, 2, 11, 30), calendar: cal)
    check("sched reenable: first fire lands", firstFire.count == 1)
    firedOnce = firstFire.first ?? firedOnce
    check("sched reenable: same day still blocked",
          fireCount(&e, [firedOnce], t(2026, 3, 2, 12, 0)) == 0)
    var reenabledOnce = firedOnce
    reenabledOnce.enabled = true
    e.resetLastFiredDay(for: reenabledOnce.id)
    check("sched reenable: cleared bookkeeping refires same day",
          fireCount(&e, [reenabledOnce], t(2026, 3, 2, 12, 30)) == 1)

 // The persisted firing day must be stable across time-zone changes: the
 // same civil date encodes to the same key in any zone.
    var laCal = Calendar(identifier: .gregorian)
    laCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func tLA(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        laCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    check("sched tz: same civil day keeps one key",
          ScheduleEngine.localDayKey(for: t(2026, 3, 2, 9, 30), calendar: cal)
            == ScheduleEngine.localDayKey(for: tLA(2026, 3, 2, 9, 30), calendar: laCal))
    check("sched tz: different civil day changes key",
          ScheduleEngine.localDayKey(for: t(2026, 3, 2, 9, 30), calendar: cal)
            != ScheduleEngine.localDayKey(for: tLA(2026, 3, 3, 9, 30), calendar: laCal))

 // Negative-offset zones: localDayKey's UTC-midnight encoding must not
 // shift the occurrence to midnight (or to the previous day). The
 // occurrence has to be built from the local start of day.
    do {
        func tNY(_ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
            laCal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
        }
        func ruleNY(_ time: (Int, Int), _ repeatMode: ScheduleRepeat,
                    createdAt: Date = tNY(1, 1)) -> ScheduleRule {
            ScheduleRule(hour: time.0, minute: time.1, repeatMode: repeatMode,
                        action: .setLimit(60), createdAt: createdAt)
        }
        var ny = ScheduleEngine()
        let nyDaily = ruleNY((9, 0), .daily)
 // 2026-03-02 08:59 local: not yet due; 09:30: due exactly once.
        check("sched ny: daily before time no",
              ny.dueRules([nyDaily], now: tNY(3, 2, 8, 59), calendar: laCal).count == 0)
        check("sched ny: daily at time fires",
              ny.dueRules([nyDaily], now: tNY(3, 2, 9, 30), calendar: laCal).count == 1)
        check("sched ny: daily same day dedupe",
              ny.dueRules([nyDaily], now: tNY(3, 2, 10, 0), calendar: laCal).count == 0)
 // Midnight must NOT fire a 09:00 rule (regression: UTC-midnight key
 // previously made every recurring rule fire at local 00:00).
        ny = ScheduleEngine()
        check("sched ny: midnight must not fire 9am rule",
              ny.dueRules([nyDaily], now: tNY(3, 2, 0, 2), calendar: laCal).count == 0)
 // One-shot created the previous evening for next morning 09:00.
        ny = ScheduleEngine()
        let nyOnce = ruleNY((9, 0), .never, createdAt: tNY(3, 1, 22, 0))
        check("sched ny: one-shot fires at 9 not midnight",
              ny.dueRules([nyOnce], now: tNY(3, 2, 9, 10), calendar: laCal).count == 1)
    }

 // Biweekly parity follows ISO weeks even when the region calendar starts
 // weeks on Sunday. Anchor 2026-03-08 (Sun) belongs to ISO week Mar 2-8:
 // Monday Mar 9 is the off week, Mar 16 the next on week.
    var sundayFirstCal = Calendar(identifier: .gregorian)
    sundayFirstCal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    sundayFirstCal.firstWeekday = 1  // Sunday, US-style region
    let biSundayFirst = rule((9, 0), .biweekly(weekdays: [1], anchor: t(2026, 3, 8)),
                             createdAt: t(2026, 1, 1))
    e = ScheduleEngine()
    check("sched biweekly: sunday-first adjacent Monday off",
          fireCount(&e, [biSundayFirst], t(2026, 3, 9, 9, 30),
                    calendar: sundayFirstCal) == 0)
    e = ScheduleEngine()
    check("sched biweekly: sunday-first on week fires",
          fireCount(&e, [biSundayFirst], t(2026, 3, 16, 9, 30),
                    calendar: sundayFirstCal) == 1)

 // Same-day catch-up: occurrence missed while asleep fires on the next
 // tick after wake (createdAt precedes the occurrence).
    let sleeping = rule((9, 0), .daily)
    e = ScheduleEngine()
    check("sched: catch-up after wake fires", fireCount(&e, [sleeping], t(2026, 3, 2, 9, 45)) == 1)
    check("sched: catch-up dedupes", fireCount(&e, [sleeping], t(2026, 3, 2, 9, 50)) == 0)

 // Previous days are never caught up: an unfired earlier occurrence
 // (bookkeeping stale from days ago) does not fire before today's time.
    let stale = rule((9, 0), .daily)
    e = ScheduleEngine(lastFiredDay: [stale.id: t(2026, 2, 27)])
    check("sched: stale bookkeeping waits for today", fireCount(&e, [stale], t(2026, 3, 2, 8, 0)) == 0)
    check("sched: stale bookkeeping fires today's", fireCount(&e, [stale], t(2026, 3, 2, 9, 30)) == 1)

 // Disabled rules never fire; prune drops vanished rules.
    var off = rule((9, 0), .daily)
    off.enabled = false
    e = ScheduleEngine()
    check("sched: disabled rule inert", fireCount(&e, [off], t(2026, 3, 2, 9, 30)) == 0)
    _ = e.dueRules([stale], now: t(2026, 3, 3, 9, 30), calendar: cal)
    e.prune(ids: [])
    check("sched: prune empties bookkeeping", e.lastFiredDay.isEmpty)

 // Fire-day predicate edge: first-of-month for monthly(1).
    check("sched: monthly day 1 fires", ScheduleEngine.fires(
        on: t(2026, 3, 1), repeatMode: .monthly(day: 1), calendar: cal))
    check("sched: monthly day 2 no", !ScheduleEngine.fires(
        on: t(2026, 3, 1), repeatMode: .monthly(day: 2), calendar: cal))
 // "Never" matches every day — the one-shot fires at the next occurrence.
    check("sched: never matches any day", ScheduleEngine.fires(
        on: t(2026, 3, 2), repeatMode: .never, calendar: cal))
}

// MARK: - Summary

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
