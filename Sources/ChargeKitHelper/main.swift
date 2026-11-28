import Foundation
import SMCKit
import ChargeKitCore
import ChargeKitIPC
import IOKit.pwr_mgt
import IOKit.ps

// ChargeKitHelper — root LaunchDaemon owning privileged SMC writes.
// MachService: com.chargekit.helper
// An active discharge records adapter recovery before cutting wall power.

let machServiceName = "com.chargekit.helper"
let adapterKey = ChargeController.AdapterKey(rawValue: "CHIE")!
let installedHelperBinary = "/Library/PrivilegedHelperTools/\(machServiceName)"
let installedHelperPlist = "/Library/LaunchDaemons/\(machServiceName).plist"
let adapterRecoveryMarker = URL(fileURLWithPath: "/var/db/com.chargekit.helper.adapter-recovery")

var chargeKitAppPaths: [String] = {
    var paths = ["/Applications/ChargeKit.app"]
    if let configured = ProcessInfo.processInfo.environment["CHARGEKIT_APP_PATH"],
       !configured.isEmpty {
        paths.insert(configured, at: 0)
    }
    return paths
}()

func chargeKitAppIsInstalled() -> Bool {
    let fm = FileManager.default
    return chargeKitAppPaths.contains { path in
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

func domainError(_ message: String) -> NSError {
    NSError(domain: "com.chargekit.helper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// macOS gauge percent via IOPowerSources, filtered to the internal
/// battery (a UPS would otherwise feed the discharge floor with its own
/// wall-backed 100% — review round 2, P2-1). nil when IOPS is unreadable
/// or has no internal battery; callers fall back to the BMS percent.
func internalBatteryDescription() -> [String: Any]? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
          !list.isEmpty else { return nil }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?
            .takeUnretainedValue() as? [String: Any] else { continue }
        if (desc[kIOPSTypeKey as String] as? String) == "InternalBattery" {
            return desc
        }
    }
    return nil
}

func macOSBatteryPercent() -> Int? {
    internalBatteryDescription()?[kIOPSCurrentCapacityKey as String] as? Int
}

// MARK: - Discharge session (daemon-owned)
//
// Cutting the adapter (CHIE off) physically removes wall power, so the
// session must NOT depend on the user-session app staying alive: the
// daemon itself polls BUIC every 2 s, re-asserts the cut, and restores
// the adapter when the floor is reached, when cancelled, when reads
// fail repeatedly, or on any exit path.

// MARK: - Discharge sleep guard

/// Holds a PreventSystemSleep assertion for the duration of a discharge
/// session. With the adapter cut, macOS sees the machine as battery
/// powered, so idle sleep — and lid-close in clamshell mode — would
/// stall the discharge indefinitely (keeping sleep off during the
/// whole Discharge feature for the same reason). Session-owned: every
/// end path (floor reached, cancel, read failures, daemon exit)
/// releases it, and the assertion dies with the process regardless.
final class DischargeSleepGuard {
    private var assertionID: IOPMAssertionID = 0

 /// kIOPMAssertionLevelOn is a plain #define (255) the Swift importer
 /// does not expose.
    private static let levelOn = IOPMAssertionLevel(255)

    func setPreventSystemSleep(_ on: Bool) {
        if on, assertionID == 0 {
            var id = IOPMAssertionID(0)
            let kr = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                Self.levelOn,
                "ChargeKit: discharge to floor" as CFString,
                &id)
            if kr == kIOReturnSuccess {
                assertionID = id
            } else {
 // Best effort: without the assertion a discharge still
 // converges whenever the machine happens to be awake.
                NSLog("[ChargeKitHelper] discharge: PreventSystemSleep create failed 0x%08x", kr)
            }
        } else if !on, assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}

final class DischargeManager {
    static let shared = DischargeManager()

    private(set) var floorPercent: Int?
    private(set) var sessionID: String?
    private(set) var phase: DischargePhase = .idle
    private var resultAfterRestore: DischargePhase = .failed
 /// Battery-percent basis for the floor comparison, matching the app's
 /// "hardware battery percentage" toggle at session start.
    private var useHardwarePercent = true
 /// Per-session IOPS-fallback log latch (review round 2, P2-4).
    private var loggedIOPSFallback = false
    private var timer: DispatchSourceTimer?
    private var consecutiveReadFailures = 0
    private let maxReadFailures = 3
    private let sleepGuard = DischargeSleepGuard()

    var active: Bool { phase.ownsAdapter }

 /// All state is touched on the main queue only (XPC handlers and the
 /// timer both run there), so no locking is needed.
    private func controller() throws -> ChargeController {
        ChargeController(client: try AppleSMCClient())
    }

 /// Session battery percent on the given basis; the BMS value is the
 /// fallback when IOPowerSources is unreadable in the daemon.
 /// Parameterized (review round 2, P1-1): start's pre-check passes the
 /// INCOMING basis — the property still holds the previous session's
 /// basis until this start succeeds.
    private func currentPercent(_ c: ChargeController, useHardware: Bool) throws -> Double {
        if useHardware { return try c.batteryPercent() }
        if let macos = macOSBatteryPercent() { return Double(macos) }
        if !loggedIOPSFallback {
            loggedIOPSFallback = true
            NSLog("[ChargeKitHelper] discharge: IOPowerSources unreadable, falling back to BMS percent")
        }
        return try c.batteryPercent()
    }

    func start(floorPercent floor: Int, hardwarePercent: Bool) throws {
        guard !active else { throw domainError("放电或供电恢复仍在进行") }
        let clamped = min(max(floor, 5), 95)
        let c = try controller()
 // Pre-check on the INCOMING basis; useHardwarePercent is committed
 // only after the guard — a refused start must not rewrite the basis
 // of a session that is still running (review round 2, P1-1).
        let pct = try currentPercent(c, useHardware: hardwarePercent)
        guard pct > Double(clamped) else {
            NSLog("[ChargeKitHelper] discharge: battery \(pct) already at/below floor \(clamped)")
            throw domainError("电量已达到放电下限")
        }
        // launchd keeps this job alive while the marker exists, including after a crash.
        try Data().write(to: adapterRecoveryMarker, options: .atomic)
        sessionID = UUID().uuidString
        floorPercent = clamped
        do {
            try c.setAdapter(enabled: false)
        } catch {
            stop(with: .failed)
            throw error
        }
        phase = .discharging
        useHardwarePercent = hardwarePercent
        loggedIOPSFallback = false
        consecutiveReadFailures = 0
        sleepGuard.setPreventSystemSleep(true)
        NSLog("[ChargeKitHelper] discharge: floor=\(clamped) from \(pct)")
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func cancel() {
        if phase == .discharging { stop(with: .cancelled) }
    }

    func recoverAfterRestart() {
        guard FileManager.default.fileExists(atPath: adapterRecoveryMarker.path) else { return }
        stop(with: .failed)
    }

    private func stop(with result: DischargePhase) {
        phase = .restoring
        resultAfterRestore = result
        startTimer()
        retryRestore()
    }

    private func retryRestore() {
        do {
            let c = try controller()
            try c.setAdapter(enabled: true)
            guard try c.isAdapterEnabled() else { throw domainError("适配器恢复未确认") }
            if SessionRules.wallAttached(dcInVoltage: try? c.dcInVoltage()) {
                let source = internalBatteryDescription()?[kIOPSPowerSourceStateKey as String] as? String
                guard source == kIOPSACPowerValue else { throw domainError("等待 macOS 确认外接供电") }
            }
            try FileManager.default.removeItem(at: adapterRecoveryMarker)
        } catch {
            NSLog("[ChargeKitHelper] adapter recovery retry: %@", error.localizedDescription)
            return
        }
        sleepGuard.setPreventSystemSleep(false)
        timer?.cancel()
        timer = nil
        phase = resultAfterRestore
    }

    private func tick() {
        if phase == .restoring { retryRestore(); return }
        guard phase == .discharging, let floorPercent else { return }
        guard let c = try? controller() else { failRead(); return }
        guard let pct = try? currentPercent(c, useHardware: useHardwarePercent), pct.isFinite else {
            failRead()
            return
        }
        consecutiveReadFailures = 0
        if pct <= Double(floorPercent) {
            NSLog("[ChargeKitHelper] discharge: floor \(floorPercent) reached at \(pct), restoring adapter")
            stop(with: .reachedFloor)
            return
        }
 // Re-assert the cut: covers an adapter re-plug or an external write
 // that re-enabled it mid-session.
        do { try c.setAdapter(enabled: false) }
        catch { stop(with: .failed) }
    }

    private func failRead() {
        consecutiveReadFailures += 1
        NSLog("[ChargeKitHelper] discharge: read failure \(consecutiveReadFailures)/\(maxReadFailures)")
        if consecutiveReadFailures >= maxReadFailures {
            NSLog("[ChargeKitHelper] discharge: reads failing, fail-safe restore")
            stop(with: .failed)
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        guard pid > 0 else { return false }
        if newConnection.effectiveUserIdentifier != 0 {
            guard let hash = ProcessInfo.processInfo.environment["CHARGEKIT_CLIENT_CDHASH"],
                  hash.utf8.count == 40,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return false
            }
            newConnection.setCodeSigningRequirement("cdhash H\"\(hash)\"")
        }
        NSLog("[ChargeKitHelper] client pid=\(pid) accepted")

        let interface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedInterface = interface
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

final class HelperService: NSObject, HelperProtocol {
    private static let powerModeQueue = DispatchQueue(label: "com.chargekit.helper.low-power-mode")

    func version(withReply reply: @escaping (String) -> Void) {
        reply("0.5.9")
    }

    func adapterState(withReply reply: @escaping (Bool, Error?) -> Void) {
        do {
            let enabled = try ChargeController(client: AppleSMCClient()).isAdapterEnabled()
            reply(enabled, nil)
        } catch {
            reply(false, error as NSError)
        }
    }

    func setAdapter(enabled: Bool, withReply reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            do {
                guard enabled else { throw domainError("请使用带电量下限的放电会话") }
                guard !DischargeManager.shared.active else { throw domainError("放电会话持有适配器") }
                let controller = try ChargeController(client: AppleSMCClient())
                try controller.setAdapter(enabled: true)
                guard try controller.isAdapterEnabled() else { throw domainError("适配器恢复未确认") }
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func chargingState(withReply reply: @escaping (Bool, Error?) -> Void) {
        do {
            let enabled = try ChargeController(client: AppleSMCClient()).isChargingEnabled()
            reply(enabled, nil)
        } catch {
            reply(false, error as NSError)
        }
    }

    func setCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            do {
                let controller = try ChargeController(client: AppleSMCClient())
                guard controller.chargingKey != nil else { throw domainError("缺少独立充电开关") }
                try controller.setCharging(enabled: enabled)
                guard try controller.isChargingEnabled() == enabled else {
                    throw domainError("充电开关写入未确认")
                }
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, withReply reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            do {
                if enabled {
                    try DischargeManager.shared.start(floorPercent: floorPercent, hardwarePercent: hardwarePercent)
                } else {
                    DischargeManager.shared.cancel()
                }
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func dischargeState(withReply reply: @escaping (Bool, Int, Error?) -> Void) {
        DispatchQueue.main.async {
            let manager = DischargeManager.shared
            reply(manager.active, manager.active ? manager.floorPercent ?? 0 : 0, nil)
        }
    }

    func dischargeStatus(withReply reply: @escaping (Int, Int, String?) -> Void) {
        DispatchQueue.main.async {
            let manager = DischargeManager.shared
            reply(manager.phase.rawValue, manager.floorPercent ?? 0, manager.sessionID)
        }
    }

    func readKey(_ key: String, withReply reply: @escaping (Data?, Error?) -> Void) {
        guard key == "ACLC" else { reply(nil, domainError("key not allowed")); return }
        do {
            reply(Data(try AppleSMCClient().read(SMCKey(key))), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func writeKey(_ key: String, value: Data, withReply reply: @escaping (Error?) -> Void) {
        guard key == "ACLC", value.count == 1 else {
            reply(domainError("key \(key) not whitelisted")); return
        }
        do {
            try AppleSMCClient().write(SMCKey(key), [UInt8](value))
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func setLowPowerMode(enabled: Bool, withReply reply: @escaping (Error?) -> Void) {
 // macOS exposes no public setter API for Low Power Mode (SDK IOKit
 // headers carry none; ProcessInfo.isLowPowerModeEnabled is read-only).
 // `pmset -a lowpowermode` is the standard privileged path — fixed
 // argv, no shell, no user-controlled text. Runs off the main queue:
 // XPC handlers and the DischargeManager timer share it, and a hung
 // pmset must not stall discharge floor checks.
        Self.powerModeQueue.async {
            let pmset = "/usr/bin/pmset"
            guard FileManager.default.isExecutableFile(atPath: pmset) else {
                reply(domainError("pmset not found")); return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pmset)
            p.arguments = ["-a", "lowpowermode", enabled ? "1" : "0"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    NSLog("[ChargeKitHelper] low power mode \(enabled ? "on" : "off")")
                    reply(nil)
                } else {
                    reply(domainError("pmset exited \(p.terminationStatus)"))
                }
            } catch {
                reply(error as NSError)
            }
        }
    }

    func setExitRestoresCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            exitRestoresCharging = enabled
            reply(nil)
        }
    }
}

// MARK: - Safety: restore charging + adapter on every exit path

/// Exit-behavior preference pushed by the app (XPC): true = restore
/// charging + adapter on exit (safe default); false = keep the current
/// charging state ("Stop Charging when App Closed" parity).
/// Daemon restarts (reboot, reinstall) reset it to the safe default
/// until the app reconnects.
var exitRestoresCharging = true
var uninstallingSelf = false

func restoreState() {
    DischargeManager.shared.cancel()
    if let client = try? AppleSMCClient() {
        let controller = ChargeController(client: client)
 // Exit preference, except on firmware without a charging-switch key:
 // there "keep the current charging state" means leaving the adapter
 // cut, and nothing would ever restore wall power after the app is
 // gone (measured 26.7.3: every CH* key except CHIE is read-only, so
 // the adapter cut is the only stop-charging mechanism). Safety rule:
 // a machine may never be left running on battery unattended.
        let canKeepChargingOff = controller.chargingKey != nil
        if exitRestoresCharging || !canKeepChargingOff {
            if !exitRestoresCharging {
                NSLog("[ChargeKitHelper] exit-keeps-charging ignored: no charging-switch key, restoring adapter")
            }
 // Charging switch: leaving it off stops the battery at its current
 // level while the adapter keeps powering the machine — safe, but
 // restore anyway so a dead daemon never pins the state.
            _ = try? controller.setCharging(enabled: true)
            _ = try? controller.setAdapter(enabled: true)
 // MagSafe LED: hand control back to the system so a dead daemon never
 // pins a stale color (e.g. green while actually charging).
            _ = try? client.write(SMCKey("ACLC"), [0x00])
        }
    }
}

func restoreAndExit(_ code: Int32) {
    restoreState()
    exit(code)
}

func deleteInstalledHelperFiles() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: installedHelperPlist)
    try? fm.removeItem(atPath: installedHelperBinary)
}

/// App removed → helper removes itself: restore state first, then ask
/// launchd to boot the service out; the SIGTERM handler finishes the
/// file cleanup before the process dies.
func uninstallSelfIfAppMissing() {
    guard !uninstallingSelf, !chargeKitAppIsInstalled(),
          !DischargeManager.shared.active else { return }
    NSLog("[ChargeKitHelper] ChargeKit.app missing — uninstalling helper")
    uninstallingSelf = true
    restoreState()

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "system/\(machServiceName)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() }
    catch { uninstallingSelf = false }
}

// signal handlers must be re-entrant; use DispatchSource
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        if uninstallingSelf {
            deleteInstalledHelperFiles()
            exit(0)
        }
        NSLog("[ChargeKitHelper] signal \(sig) — restoring charging + adapter, exiting")
        restoreAndExit(0)
    }
    src.resume()
    return src
}

// MARK: - Run

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
DischargeManager.shared.recoverAfterRestart()
listener.delegate = delegate
listener.resume()
NSLog("[ChargeKitHelper] listening on \(machServiceName)")

// Keep a canary read loop: if SMC dies, log it.
DispatchQueue.global().async {
    while true {
        Thread.sleep(forTimeInterval: 60)
        DispatchQueue.main.async { uninstallSelfIfAppMissing() }
        if let c = try? AppleSMCClient(), (try? ChargeController(client: c).isAdapterEnabled()) != nil {
            continue
        }
        NSLog("[ChargeKitHelper] SMC health check failed")
    }
}

dispatchMain()
