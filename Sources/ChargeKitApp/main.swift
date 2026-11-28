import AppKit
import Combine
import SwiftUI
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import Security
import UserNotifications
import SMCKit
import ChargeKitCore
import ChargeKitIPC
import Sparkle

// ChargeKit — macOS menu-bar charge limiter (adapter mode).
// Reads telemetry unprivileged; privileged writes go through ChargeKitHelper.

func openSystemBatterySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
}

// MARK: - Helper XPC client

typealias HelperProtocolObjC = HelperProtocol

final class HelperClient {
    static let shared = HelperClient()
    private var connection: NSXPCConnection?
    func resetConnection() {
        let previous = connection
        connection = nil
        previous?.invalidate()
    }

    var isConnected: Bool { connection != nil }
    var exitRestoresCharging = true {
        didSet {
            guard oldValue != exitRestoresCharging, let connection else { return }
            configureExitBehavior(on: connection)
        }
    }

    private func configureExitBehavior(on connection: NSXPCConnection) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            NSLog("[ChargeKit] helper configuration: \(error.localizedDescription)")
        } as? HelperProtocolObjC
        proxy?.setExitRestoresCharging(enabled: exitRestoresCharging) { _ in }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocolObjC.self)
 // A daemon restart (version mismatch on a new selector, crash,
 // reinstall) invalidates the connection; drop it so the next call
 // rebuilds — the MachService on-demand launch spins up the fresh
 // daemon. Without this the cached dead connection silences every
 // helper write for the rest of the app's life.
        c.invalidationHandler = { [weak self, weak c] in
            DispatchQueue.main.async {
                guard let self, let c, self.connection === c else { return }
                self.connection = nil
            }
        }
        c.resume()
        connection = c
        configureExitBehavior(on: c)
        return c
    }

    var proxy: HelperProtocolObjC? {
        ensureConnection().remoteObjectProxyWithErrorHandler { error in
            NSLog("[ChargeKit] helper error: \(error.localizedDescription)")
        } as? HelperProtocolObjC
    }

    func setAdapter(enabled: Bool, completion: @escaping (Error?) -> Void) {
        reportingProxy(completion)?.setAdapter(enabled: enabled, withReply: completion)
    }

    func restoreAdapter(completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.setAdapter(enabled: true, withReply: reply)
        }
    }

    func cancelStaleDischarge(hardwarePercent: Bool, completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.setDischarge(enabled: false, floorPercent: 0, hardwarePercent: hardwarePercent, withReply: reply)
        }
    }

    func releaseMagSafeColor(completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.writeKey("ACLC", value: Data([MagSafeColor.system]), withReply: reply)
        }
    }

    private func performTimedWrite(
        completion: @escaping (Error?) -> Void,
        send: (HelperProtocolObjC, @escaping (Error?) -> Void) -> Void
    ) {
        let connection = ensureConnection()
        let deadline = DispatchTime.now() + .seconds(4)
        var request = HelperReplyDeadline(deadline: deadline.uptimeNanoseconds)
        func finish(receivedReply: Bool, error: Error?) {
            switch request.resolve(at: DispatchTime.now().uptimeNanoseconds, receivedReply: receivedReply) {
            case .reply:
                completion(error)
            case .timedOut:
                if self.connection === connection {
                    self.connection = nil
                    connection.invalidate()
                }
                completion(NSError(domain: "com.chargekit.helper", code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "Helper 响应超时"]))
            case nil:
                break
            }
        }
        let reply: (Error?) -> Void = { error in
            DispatchQueue.main.async { finish(receivedReply: true, error: error) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { reply($0) } as? HelperProtocolObjC
        guard let proxy else {
            reply(CocoaError(.xpcConnectionInvalid))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { finish(receivedReply: false, error: nil) }
        send(proxy, reply)
    }

    private func reportingProxy(_ completion: @escaping (Error?) -> Void) -> HelperProtocolObjC? {
        let remote = ensureConnection().remoteObjectProxyWithErrorHandler(completion) as? HelperProtocolObjC
        if remote == nil { completion(CocoaError(.xpcConnectionInvalid)) }
        return remote
    }

    func setCharging(enabled: Bool, completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.setCharging(enabled: enabled, withReply: reply)
        }
    }

 /// Blocking variant for the sleep-entry path: the system freezes right
 /// after willSleep handlers return, so an async fire-and-forget write
 /// can lose the race (measured: cut landed on one sleep, missed on the
 /// next). Bounded at 2 s so a dead daemon never blocks sleep.
    func setChargingSync(enabled: Bool) -> Result<Void, Error> {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Void, Error>?
        let complete: (Error?) -> Void = { error in
            lock.lock()
            if result == nil {
                result = error.map { .failure($0) } ?? .success(())
                sem.signal()
            }
            lock.unlock()
        }
        reportingProxy(complete)?.setCharging(enabled: enabled, withReply: complete)
        guard sem.wait(timeout: .now() + 2) == .success else {
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(CocoaError(.xpcConnectionInvalid))
    }

    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.setDischarge(
                enabled: enabled, floorPercent: floorPercent, hardwarePercent: hardwarePercent, withReply: reply)
        }
    }

    func dischargeStatus(completion: @escaping (DischargePhase?, Int, String?, Error?) -> Void) {
        reportingProxy { completion(nil, 0, nil, $0) }?.dischargeStatus { phase, floor, id in
            completion(DischargePhase(rawValue: phase), floor, id, nil)
        }
    }

 /// Daemon version (XPC protocol gate): nil when the daemon cannot be
 /// reached at all.
    func version(completion: @escaping (String?) -> Void) {
        let proxy = ensureConnection().remoteObjectProxyWithErrorHandler { _ in
            completion(nil)
        } as? HelperProtocolObjC
        proxy?.version(withReply: completion)
    }

 /// MagSafe LED color write (ACLC, daemon-whitelisted). Fire-and-forget.
    func setMagSafeColor(_ color: UInt8, completion: @escaping (Error?) -> Void = { _ in }) {
        reportingProxy(completion)?.writeKey("ACLC", value: Data([color]), withReply: completion)
    }

    func setLowPowerMode(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        performTimedWrite(completion: completion) { proxy, reply in
            proxy.setLowPowerMode(enabled: enabled, withReply: reply)
        }
    }

}

/// One-time privileged helper install from the app bundle. Runs the
/// bundled install-helper.sh via AppleScript's administrator
/// authorization so the LaunchDaemon and CHARGEKIT_APP_PATH stay in
/// sync with the running app.
final class HelperInstaller {
    static let shared = HelperInstaller()

    private let helperPath = "/Library/PrivilegedHelperTools/com.chargekit.helper"
    private let daemonPlist = "/Library/LaunchDaemons/com.chargekit.helper.plist"
    private let installerScriptName = "install-helper.sh"
    private(set) var installInProgress = false
    private var installWaiters: [(Error?) -> Void] = []
    private var lastInstallError: Error?
    private lazy var clientHash: String? = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let data = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }()

    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: helperPath) && fm.fileExists(atPath: daemonPlist)
    }

    func allowRetry() {
        lastInstallError = nil
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "com.chargekit.installer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    var needsInstall: Bool {
        guard isInstalled,
              let data = try? Data(contentsOf: URL(fileURLWithPath: daemonPlist)),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              let env = dict["EnvironmentVariables"] as? [String: Any],
              let installedPath = env["CHARGEKIT_APP_PATH"] as? String,
              let installedVersion = env["CHARGEKIT_APP_VERSION"] as? String,
              let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else { return true }
        guard let clientHash else { return true }
        return installedPath != Bundle.main.bundlePath || installedVersion != bundleVersion
            || env["CHARGEKIT_CLIENT_CDHASH"] as? String != clientHash
    }

    func installIfNeeded(completion: @escaping (Error?) -> Void) {
        guard !installInProgress else {
            installWaiters.append(completion)
            return
        }
        if !needsInstall {
            lastInstallError = nil
            completion(nil)
            return
        }
        if let lastInstallError {
            completion(lastInstallError)
            return
        }
        installInProgress = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runPrivilegedInstall()
            DispatchQueue.main.async {
                self.installInProgress = false
                self.lastInstallError = result
                if result == nil { HelperClient.shared.resetConnection() }
                let waiters = self.installWaiters
                self.installWaiters.removeAll()
                completion(result)
                for waiter in waiters { waiter(result) }
            }
        }
    }

    private func runPrivilegedInstall() -> Error? {
        guard let resources = Bundle.main.resourceURL else {
            return error("App bundle missing Resources")
        }
        let script = resources.appendingPathComponent(installerScriptName).path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            return error("Bundled helper installer missing")
        }

        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(escaped)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return error
        }
        guard p.terminationStatus == 0 else {
            return error("helper 安装未完成（可能取消了授权）")
        }
        return needsInstall ? error("helper 安装未生效") : nil
    }
}

// MARK: - Charge engine (heat + sailing policy layers, charging-switch mode)

/// IOPowerSources reports the internal battery's Type as this value.
/// (kIOPSInternalBatteryTypeValue lives in a private header; the string
/// itself is what the public IOPowerSources data documents.)
private let internalBatteryType = "InternalBattery"

/// One IOPowerSources snapshot per tick: AC-attach state (any source on AC
/// counts, mirroring the historical isACAttached fallback for an empty
/// list — desktops, read failure) and the internal battery's gauge percent
/// (type-filtered — a UPS would otherwise masquerade as the battery).
func powerSourceSnapshot() -> (
    acAttached: Bool, macosPercent: Int?, internalBatterySource: LowPowerModePolicy.PowerSource?,
    isCharging: Bool?
) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
          !list.isEmpty else { return (true, nil, nil, nil) }
    var ac = false
    var percent: Int?
    var internalBatterySource: LowPowerModePolicy.PowerSource?
    var isCharging: Bool?
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?
            .takeUnretainedValue() as? [String: Any] else { continue }
        let state = desc[kIOPSPowerSourceStateKey as String] as? String
        if state == kIOPSACPowerValue {
            ac = true
        }
        if (desc[kIOPSTypeKey as String] as? String) == internalBatteryType {
            percent = desc[kIOPSCurrentCapacityKey as String] as? Int
            isCharging = desc[kIOPSIsChargingKey as String] as? Bool
            if state == kIOPSACPowerValue {
                internalBatterySource = .external
            } else if state == kIOPSBatteryPowerValue {
                internalBatterySource = .battery
            }
        }
    }
    return (ac, percent, internalBatterySource, isCharging)
}

// MARK: - Battery info (public IORegistry / IOPowerSources)

/// Battery health + adapter details from public sources only: the
/// AppleSmartBattery IORegistry properties (the same dictionary
/// `ioreg -rn AppleSmartBattery` prints) plus IOPowerSources for the
/// macOS gauge percent. Static fields are nil on machines that don't
/// publish them; adapter fields are nil with no adapter attached.
/// Equatable so the engine can skip publishing unchanged values (review
/// P1-3: the struct used to be reassigned every tick, forcing a hidden
/// measurer layout per publish).
struct BatteryInfo: Equatable {
    var designCapacitymAh: Int? = nil
    var fullChargeCapacitymAh: Int? = nil
 /// Apple-reported battery health percent ("MaxCapacity").
    var healthPercent: Int? = nil
    var cycleCount: Int? = nil
    var serial: String? = nil
 /// Reported adapter voltage and power rating from AdapterDetails.
    var adapterVolts: Double? = nil
    var adapterWatts: Int? = nil
    var adapterContractAmps: Double? = nil
    var adapterProtocol: String? = nil

    var adapterNegotiatedWatts: Double? {
        guard let adapterVolts, let adapterContractAmps else { return nil }
        return adapterVolts * adapterContractAmps
    }
 /// macOS gauge percent (IOPowerSources), shown next to the raw hardware
 /// percent (BUIC) in the battery-info dual-percent row.
    var macosPercent: Int? = nil
}

/// Caching reader for the battery-info block (the
/// AppleSmartBattery property dictionary carries a huge BatteryData blob
/// the views never use, and the tick runs on the main thread — every
/// avoided copy is frame budget). The FULL dump (static identity fields:
/// design capacity / health / cycle count / serial) runs at launch, every
/// ~5 minutes, and when the AC state changes (adapter replug); per-tick
/// reads fetch only the small AdapterDetails dictionary, and the macOS
/// gauge percent comes from the tick's shared IOPS snapshot.
final class BatteryInfoReader {
    private var statics = BatteryInfo()   // identity fields only
    private var lastFullDump: Date?

    func read(macosPercent: Int?, acChanged: Bool) -> BatteryInfo {
        var info = BatteryInfo()
        info.macosPercent = macosPercent
        let now = Date()
 // Keyed on lastFullDump, not on a field value: a machine whose
 // dictionary lacks DesignCapacity would otherwise full-dump every
 // tick forever (review round 2, P2-3). A failed dump leaves
 // lastFullDump nil → per-tick retry, the pre-fix failure path.
        let stale = lastFullDump.map { now.timeIntervalSince($0) > 300 } ?? true
        let fullDump = acChanged || stale
        if fullDump, let dict = Self.fullDump() {
            statics.designCapacitymAh = (dict["DesignCapacity"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            statics.fullChargeCapacitymAh = (dict["AppleRawMaxCapacity"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            statics.healthPercent = (dict["MaxCapacity"] as? Int).flatMap { (1...100).contains($0) ? $0 : nil }
            statics.cycleCount = dict["CycleCount"] as? Int
            statics.serial = (dict["BatterySerialNumber"] as? String)
                ?? (dict["BatteryData"] as? [String: Any])?["Serial"] as? String
            if let adapter = dict["AdapterDetails"] as? [String: Any] {
                applyAdapter(adapter, to: &info)
            }
            lastFullDump = now
        } else if !fullDump, let adapter = Self.adapterDetails() {
            applyAdapter(adapter, to: &info)
        }
        info.designCapacitymAh = statics.designCapacitymAh
        info.fullChargeCapacitymAh = statics.fullChargeCapacitymAh
        info.healthPercent = statics.healthPercent
        info.cycleCount = statics.cycleCount
        info.serial = statics.serial
        return info
    }

    private func applyAdapter(_ adapter: [String: Any], to info: inout BatteryInfo) {
        if let millivolts = adapter["AdapterVoltage"] as? Int, millivolts > 0 {
            info.adapterVolts = Double(millivolts) / 1000
        }
        info.adapterWatts = adapter["Watts"] as? Int
        let description = (adapter["Description"] as? String)?.lowercased() ?? ""
        let words = description.split { !$0.isLetter && !$0.isNumber }
        if words.contains("pd") || description.contains("usb power delivery") {
            info.adapterProtocol = "USB PD"
            if let milliamps = adapter["Current"] as? Int, milliamps > 0 {
                info.adapterContractAmps = Double(milliamps) / 1000
            }
        }
    }

 /// The complete AppleSmartBattery property dictionary.
    private static func fullDump() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

 /// Single-key read of the (small) AdapterDetails dictionary.
    private static func adapterDetails() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
                  service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [String: Any] else { return nil }
        return raw
    }

 /// True when the battery firmware reports a reason for not charging
 /// (optimized charging, end-of-charge management, etc.).
    static func chargePaused() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
                  service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [String: Any],
              let reason = raw["NotChargingReason"] as? Int else { return nil }
        return reason != 0
    }

 /// Remaining charge in mAh (AppleRawCurrentCapacity) — per-tick
 /// single-key read; the runtime estimate needs real mAh resolution
 /// (1% of a ~6 Ah pack is ±60 mAh, vs the gauge's whole-percent steps).
    static func currentCapacity() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
                  service, "AppleRawCurrentCapacity" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? Int else { return nil }
        return Double(raw)
    }
}

// MARK: - MagSafe LED

/// ACLC color codes (Battery-Toolkit SMCComm+MagSafe values; ui8).
/// The system resets ACLC on adapter replug, so we read-compare each tick
/// and re-assert only when the key actually differs.
private enum MagSafeColor {
    static let system: UInt8 = 0x00  // hand control back to macOS
    static let off: UInt8 = 0x01
    static let green: UInt8 = 0x03
    static let orange: UInt8 = 0x04
}

// MARK: - Idle-sleep guard ("prevent sleep until the charge limit")

/// Holds a PreventUserIdleSystemSleep assertion while the battery charges
/// toward the limit so the machine does not idle-sleep mid-charge (
/// "Disable Sleep until Charge Limit"). Lid-close sleep is not affected —
/// no public assertion type covers it. The assertion is process-owned: it
/// disappears automatically if the app dies.
final class SleepGuard {
    private var assertionID: IOPMAssertionID = 0

 /// kIOPMAssertionLevelOn is a plain #define (255) the Swift importer
 /// does not expose.
    private static let levelOn = IOPMAssertionLevel(255)

    func setPreventIdleSleep(_ on: Bool) {
        if on, assertionID == 0 {
            var id = IOPMAssertionID(0)
            let kr = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                Self.levelOn,
                "ChargeKit: charging to limit" as CFString,
                &id)
            assertionID = kr == kIOReturnSuccess ? id : 0
        } else if !on, assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit { setPreventIdleSleep(false) }
}

// MARK: - Notifications (S7)

/// Engine lifecycle events surfaced to the user (when notifications are
/// enabled). Emitted on the main thread.
enum EngineEvent {
 /// Charging reached the user's limit from a meaningfully lower level
 /// (sailing top-ups do not count).
    case limitReached(target: Int)
 /// A Top Up leg finished by reaching (near) full charge.
    case topUpCompleted
 /// A daemon discharge session ended by reaching its floor (manual or
 /// automatic; cancels and the calibration leg do not emit this).
    case dischargeFinished(floor: Int)
 /// The calibration cycle ran to completion.
    case calibrationCompleted
 /// The macOS native charge limit capped a full-charge leg.
    case nativeLimitStalled
}

// MARK: - Action history (task history parity)

/// One executed action record — scheduled tasks, session completions, and
/// session cancellations. Persisted as JSON (most recent first, capped at
/// 100 entries) so the History pane answers "did my calibration run
/// yesterday?" without guesswork.
struct ActionHistoryEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var kind: Kind
 /// Short user-facing description (e.g. "设置上限 80%" / "校准完成").
    var detail: String

    enum Kind: String, Codable {
        case scheduledAction
        case sessionStarted
        case sessionCompleted
        case sessionCancelled
        case limitReached
        case nativeLimitStall
    }
}

extension ScheduleAction {
 /// User-facing description for the history log.
    var historyDetail: String {
        switch self {
        case .setLimit(let v): return "定时：设置上限 \(v)%"
        case .dischargeTo(let v): return "定时：放电至 \(v)%"
        case .pauseCharging: return "定时：暂停充电"
        case .topUp: return "定时：充满一次"
        case .startCalibration: return "定时：开始校准"
        case .setLowPowerMode(let on): return "定时：\(on ? "开启" : "关闭")省电模式"
        }
    }
}

extension ActionHistoryEntry.Kind {
    var icon: String {
        switch self {
        case .scheduledAction: return "clock.badge.checkmark"
        case .sessionStarted: return "play.circle"
        case .sessionCompleted: return "checkmark.circle.fill"
        case .sessionCancelled: return "xmark.circle"
        case .limitReached: return "flag.checkered"
        case .nativeLimitStall: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .scheduledAction: return .secondary
        case .sessionStarted: return .blue
        case .sessionCompleted: return .green
        case .sessionCancelled: return .secondary
        case .limitReached: return .blue
        case .nativeLimitStall: return .orange
        }
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let icon = Self.iconAttachment() { content.attachments = [icon] }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

 /// macOS 26 renders the banner's leading app-icon slot only for
 /// Apple-issued signing identities; ad-hoc builds get a blank
 /// placeholder there (A/B-verified on 26.6.2: icns/Assets.car, path,
 /// LaunchServices, cache and notification-DB records were all ruled
 /// out). Attaching the bundle icon as an image keeps notifications
 /// visually branded. The PNG is rewritten per post — one bounded
 /// temp file, never stale after an app update.
    private static func iconAttachment() -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.chargekit.notification-icon.png")
        do {
            if let png = iconPNG(side: 128) {
                try png.write(to: url, options: .atomic)
            } else if !FileManager.default.fileExists(atPath: url.path) {
                return nil
            }
            return try UNNotificationAttachment(
                identifier: "app-icon", url: url, options: nil)
        } catch {
            return nil
        }
    }

    private static func iconPNG(side: Int) -> Data? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL),
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

 /// Present banners even while the popover happens to be open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

final class ChargeEngine: ObservableObject {
 /// Poll period the timer runs at (s); also the dt fed to the runtime
 /// estimator's EMA — keep the two in sync.
    static let tickInterval: TimeInterval = 2

    struct Snapshot: Equatable {
        var batteryPercent: Double = 0
 /// Raw BMS percent (BUIC), independent of the selected basis: the
 /// stall detector watches the physical value and the battery-info
 /// dual-percent row shows it. nil on read error.
        var hardwareBatteryPercent: Double?
        var dcInPower: Double?
        var batteryTemp: Double?
 /// Battery power in W: positive = charging, negative = discharging.
 /// nil when the gauge keys are unreadable.
        var batteryPower: Double?
 /// Host (system) power draw in W = adapter input − battery power.
        var hostPower: Double?
 /// Live gauge readings (nil when the keys are unreadable), shown
 /// in the battery info telemetry rows.
        var batteryVolts: Double?
        var batteryAmps: Double?
 /// EMA-smoothed runtime until empty (minutes); nil while charging,
 /// adapter-holding, warming up after AC detach, or when the capacity /
 /// voltage reads are unavailable.
        var runtimeEstimateMinutes: Double?
        var chargingEnabled: Bool = true
        var phase: ChargePhase = .idle
        var readError: String?
 /// macOS optimized-charging / native environment paused the charge
 /// (ChargerData.NotChargingReason != 0) even though the SMC charging
 /// switch is on.
        var chargePaused: Bool = false
        var adapterRecoveryNeeded = false
        var systemPowerSource: LowPowerModePolicy.PowerSource?
        var systemIsCharging: Bool?
        var systemBatteryPercent: Int?

        var hasTelemetry: Bool { readError == nil && hardwareBatteryPercent != nil }
        var hasBatteryPercent: Bool { hasTelemetry || systemBatteryPercent != nil }
        var liveAdapterPower: Double? { readError == nil ? dcInPower : nil }
        var liveBatteryPower: Double? { readError == nil ? batteryPower : nil }
        var liveHostPower: Double? { readError == nil ? hostPower : nil }

        var isDrainingWhileChargeManaged: Bool {
            guard let batteryPower, batteryPower < -0.5 else { return false }
            return phase == .holding || phase == .charging || phase == .systemManaged
        }
    }

    @Published var snapshot = Snapshot()
    let chargeControlMode: SessionRules.ChargeControlMode
    private var adapterRestoreAfter: TimeInterval = 0
    private var adapterRestoreInFlight = false
    private var adapterProbeAttempts = 0
    private var adapterProbeEpoch = 0
    private var awaitingAdapterPower = false
    private var adapterProbeRetryAfter: TimeInterval = 0
    private var pendingDischargeCancellation = false
    private var dischargeCancellationInFlight = false

    private func publishSnapshot(_ updated: Snapshot) {
        if snapshot != updated { snapshot = updated }
    }

    private func publishReadError(_ message: String) {
        if snapshot.readError != message { snapshot.readError = message }
    }
 /// Battery health + adapter details (public IORegistry/IOPS sources),
 /// refreshed every tick; independent of the SMC reads, so the info
 /// views keep their data across snapshot read errors.
    @Published var batteryInfo = BatteryInfo()
 /// Caching reader behind batteryInfo — full AppleSmartBattery dump only
 /// at launch / every ~5 min / on AC-edge changes.
    private let batteryInfoReader = BatteryInfoReader()
 /// Previous tick's AC state — drives the reader's AC-edge full dump.
    private var lastACAttached: Bool?
 /// EMA filter behind snapshot.runtimeEstimateMinutes (pure Core
 /// logic, fed once per tick).
    private var runtimeEstimator = RuntimeEstimator()
    @Published var limitingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(limitingEnabled, forKey: "limitingEnabled")
            if limitingEnabled && !oldValue { HelperInstaller.shared.allowRetry() }
            recordHistory(.scheduledAction, limitingEnabled ? "开启限制充电" : "关闭限制充电")
        }
    }
    @Published var targetPercent: Int {
        didSet {
            UserDefaults.standard.set(targetPercent, forKey: "targetPercent")
 // The limit moved: any running charge leg was aiming at the
 // old target, so it no longer counts as "reached the limit"
 // (notification false positive/obs 5).
            chargeLegStartPercent = nil
 // Debounced history: a slider drag fires didSet dozens of
 // times; record once after the value settles for 1 s.
            targetDebounce?.invalidate()
            targetDebounce = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.recordHistory(.scheduledAction, "充电上限改为 \(self.targetPercent)%")
            }
        }
    }
    @Published var sailBufferPercent: Int {
        didSet { UserDefaults.standard.set(sailBufferPercent, forKey: "sailBufferPercent") }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { UserDefaults.standard.set(heatProtectionEnabled, forKey: "heatProtectionEnabled") }
    }
    @Published var heatThresholdC: Int {
        didSet { UserDefaults.standard.set(heatThresholdC, forKey: "heatThresholdC") }
    }
 /// Session: charge to ~100% once; ends at 99%+ or when AC is removed.
    @Published var topUpActive: Bool {
        didSet { UserDefaults.standard.set(topUpActive, forKey: "topUpActive") }
    }
 /// Session: drain the battery to the target (daemon-owned; mirror of
 /// the daemon state, optimistically set when the app starts it).
    @Published var dischargeActive = false
    @Published var dischargeFloor: Int?
 /// Session: calibration cycle (charge to full -> dwell -> discharge to
 /// floor); survives an app relaunch (phase + timestamp persisted).
    @Published var calibrationActive: Bool {
        didSet { UserDefaults.standard.set(calibrationActive, forKey: "calibrationActive") }
    }
    @Published var sleepStopCharging: Bool {
        didSet { UserDefaults.standard.set(sleepStopCharging, forKey: "sleepStopCharging") }
    }
 /// Prevent idle sleep while charging toward the limit (S7). The
 /// assertion is held only while the policy actively charges below the
 /// effective target — sailing holds, heat pauses, discharges and
 /// battery operation all allow sleep.
    @Published var preventSleepUntilLimit: Bool {
        didSet { UserDefaults.standard.set(preventSleepUntilLimit, forKey: "preventSleepUntilLimit") }
    }
 /// Auto-discharge (S7): plugged in and meaningfully above the limit ->
 /// start a daemon discharge session down to the limit (
 /// "Automatic Discharge").
    @Published var autoDischargeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDischargeEnabled, forKey: "autoDischargeEnabled") }
    }
 /// Notifications (S7): limit reached, discharge / calibration done,
 /// native-limit stall. Enabling asks the system for authorization
 /// once; the gate itself lives here so all events route through it.
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { Notifier.shared.requestAuthorization() }
        }
    }
 /// Battery-percent basis for every feature ("Hardware Battery
 /// Percentage" parity): off = the macOS gauge value users see in the
 /// system UI, on = the BMS-direct value. See
 /// SessionRules.effectiveBatteryPercent; the daemon discharge session
 /// receives the same flag at start.
    @Published var hardwareBatteryPercent: Bool {
        didSet { UserDefaults.standard.set(hardwareBatteryPercent, forKey: "hardwareBatteryPercent") }
    }
 /// Route for engine lifecycle events (wired by AppDelegate to
 /// Notifier). Always invoked on the main thread.
    var onEvent: ((EngineEvent) -> Void)?
 /// Exit-behavior toggle (parity): on = the daemon restores
 /// charging + adapter on its exit paths (safe default); off = keeps
 /// the current charging state. Sent to the daemon on change and at
 /// engine start.
    @Published var exitRestoresCharging: Bool {
        didSet {
            UserDefaults.standard.set(exitRestoresCharging, forKey: "exitRestoresCharging")
            HelperClient.shared.exitRestoresCharging = !chargeControlMode.controlsCharging || exitRestoresCharging
        }
    }
 /// Action history (task history parity): most recent first,
 /// capped at 100 entries. Persisted as JSON in UserDefaults.
    @Published private(set) var actionHistory: [ActionHistoryEntry] = []
 /// Scheduled tasks (S7). Persisted as JSON; the firing bookkeeping
 /// (lastFiredDay) lives in the ScheduleEngine and is persisted
 /// alongside so a relaunch never refires today's tasks.
    @Published var scheduleRules: [ScheduleRule] {
        didSet {
            if let data = try? JSONEncoder().encode(scheduleRules) {
                UserDefaults.standard.set(data, forKey: "scheduleRules")
            }
            schedule.prune(ids: Set(scheduleRules.map(\.id)))
            persistScheduleBookkeeping()
            refreshWorkdayCalendarData()
        }
    }
    private var schedule = ScheduleEngine()
    private var scheduledActionInFlight = false
    private var scheduledPauseInFlight = false
    private var scheduleRetryAfter: [UUID: Date] = [:]
    @Published var workdayCalendarRegion: WorkdayCalendarRegion {
        didSet {
            UserDefaults.standard.set(workdayCalendarRegion.rawValue, forKey: "workdayCalendarRegion")
            refreshWorkdayCalendarData()
        }
    }
    @Published private(set) var workdayCalendarStatus = ""
    private let workdayCalendarClient = WorkdayCalendarClient()
    private var workdayCalendarRequestYear: Int?
    private var workdayCalendarLastCheckAt: Date?
 /// Login item (S7) via SMAppService. The system's login-item state is
 /// the source of truth (no UserDefaults mirror); `launchAtLogin` is
 /// re-read from SMAppService on every launch.
    @Published var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private var pendingManualLowPowerMode: Bool?
    @Published private(set) var lowPowerModeError: String?
    @Published var automaticLowPowerMode: Bool {
        didSet {
            UserDefaults.standard.set(automaticLowPowerMode, forKey: "automaticLowPowerMode")
            if automaticLowPowerMode && !oldValue { HelperInstaller.shared.allowRetry() }
        }
    }
    @Published var lowPowerModeThreshold: Int {
        didSet { UserDefaults.standard.set(lowPowerModeThreshold, forKey: "lowPowerModeThreshold") }
    }
    @Published private(set) var lowPowerModeWriteInFlight = false
    @Published private(set) var lowPowerModeNeedsAuthorization = false
    private var queuedLowPowerMode: Bool?
    private var lastLowPowerModeWrite = -Double.infinity
    private static let manualLowPowerModeKey = "manualLowPowerModeSession"
    private var manualLowPowerMode: LowPowerModePolicy.ManualSession {
        didSet {
            if oldValue.state != manualLowPowerMode.state {
                UserDefaults.standard.set(manualLowPowerMode.state?.rawValue, forKey: Self.manualLowPowerModeKey)
            }
        }
    }
    private var managedLowPowerModeTarget: Bool?

    var lowPowerModeSwitchValue: Bool { pendingManualLowPowerMode ?? lowPowerModeEnabled }
    var lowPowerModeSwitchBusy: Bool { pendingManualLowPowerMode != nil || lowPowerModeWriteInFlight }

    func setLowPowerMode(_ on: Bool) {
        HelperInstaller.shared.allowRetry()
        let sources = powerSourceSnapshot()
        manualLowPowerMode.observe(lowPowerModeSource(
            internalSource: sources.internalBatterySource, dcInVoltage: readDCInVoltage()))
        manualLowPowerMode.set(on)
        pendingManualLowPowerMode = on
        requestLowPowerMode(on)
    }

    private func requestLowPowerMode(_ on: Bool) {
        if lowPowerModeWriteInFlight {
            queuedLowPowerMode = on
        } else {
            queuedLowPowerMode = nil
            writeLowPowerMode(on)
        }
    }

    private func updateLowPowerMode(source: LowPowerModePolicy.PowerSource?, batteryPercent: Int?) {
        let current = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPowerModeEnabled != current { lowPowerModeEnabled = current }
        manualLowPowerMode.observe(source)
        let target = manualLowPowerMode.target ?? LowPowerModePolicy.target(
            enabled: automaticLowPowerMode, source: source,
            batteryPercent: batteryPercent, threshold: lowPowerModeThreshold)
        if let pending = pendingManualLowPowerMode {
            if target != nil && target != pending {
                pendingManualLowPowerMode = nil
            } else if !lowPowerModeWriteInFlight, queuedLowPowerMode == nil {
                if current == pending {
                    pendingManualLowPowerMode = nil
                } else if ProcessInfo.processInfo.systemUptime - lastLowPowerModeWrite >= 3 {
                    pendingManualLowPowerMode = nil
                    lowPowerModeError = "macOS 尚未确认切换"
                }
            }
        }
        managedLowPowerModeTarget = target
        if let target, queuedLowPowerMode != target { queuedLowPowerMode = nil }
        guard !sleepPauseLatch, !lowPowerModeWriteInFlight else { return }
        if let queued = queuedLowPowerMode {
            queuedLowPowerMode = nil
            writeLowPowerMode(queued)
        } else if let target, current != target || manualLowPowerMode.needsRestore,
                  ProcessInfo.processInfo.systemUptime - lastLowPowerModeWrite >= 3 {
            writeLowPowerMode(target)
        }
    }

    private func writeLowPowerMode(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        lowPowerModeWriteInFlight = true
        lowPowerModeNeedsAuthorization = HelperInstaller.shared.needsInstall
        let complete: (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastLowPowerModeWrite = ProcessInfo.processInfo.systemUptime
                self.lowPowerModeWriteInFlight = false
                self.lowPowerModeNeedsAuthorization = false
                if error == nil { self.manualLowPowerMode.didWrite(on) }
                if error != nil && self.pendingManualLowPowerMode == on {
                    self.pendingManualLowPowerMode = nil
                }
                let message = error?.localizedDescription
                if self.lowPowerModeError != message { self.lowPowerModeError = message }
                completion?(error == nil)
            }
        }
        HelperInstaller.shared.installIfNeeded { [weak self] error in
            self?.lowPowerModeNeedsAuthorization = false
            if let error { complete(error) }
            else { HelperClient.shared.setLowPowerMode(on, completion: complete) }
        }
    }
    var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法修改登录项 · \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

 /// MagSafe LED sync: green at the configured limit, orange while charging
 /// toward it, off when the adapter is cut. industry-standard semantics.
    @Published var magsafeLedEnabled: Bool {
        didSet {
            UserDefaults.standard.set(magsafeLedEnabled, forKey: "magsafeLedEnabled")
            if magsafeLedEnabled && !oldValue { HelperInstaller.shared.allowRetry() }
            releaseMagSafeColorIfNeeded()
        }
    }
    @Published var helperError: String?

    private var calibration = CalibrationSession()
    private let calibrationConfig = CalibrationConfig()
    var calibrationPhase: CalibrationSession.Phase { calibration.phase }
    var calibrationFloorPercent: Int { calibrationConfig.dischargeFloorPercent }
 /// Detects the macOS native charge limit capping a full-charge leg
 /// (Top Up / calibration): CHTE held on, AC present, yet the battery
 /// fails to rise. The user must raise the system limit to 100% by hand.
    private var stallDetector = NativeLimitStall()
 /// Latched while a full-charge leg makes no progress (see stallDetector).
 /// Held for a few ticks after the leg auto-ends so the warning is
 /// actually visible (the leg ending resets the detector the next tick).
    @Published var nativeLimitStalled = false
    private var nativeLimitStalledUntil: Date?
 /// Blocks starting a new full-charge leg while a stall warning is up:
 /// the macOS limit caps below 100, so a fresh leg would just stall again.
    private var nativeLimitStallActive: Bool {
        stallDetector.stalled
            || (nativeLimitStalledUntil.map { Date() < $0 } ?? false)
    }
 /// UI-facing mirror of nativeLimitStallActive for button disablement.
    @Published var fullChargeLegBlocked = false

    private var policy = ChargePolicy()
    private let sleepGuard = SleepGuard()
 /// Phase of the previous tick's snapshot — detects charging→holding
 /// transitions (limit reached) without spamming on every hold tick.
    private var prevPhase: ChargePhase = .idle
 /// Previous tick's AC-attached state — drives adapter plug/unplug
 /// history edges.
    private var prevACAttached: Bool?
 /// Debounce timer for target-percent history: slider drags fire didSet
 /// many times; record once after the value settles.
    private var targetDebounce: Timer?
 /// Battery percent when the current charging leg began; a leg that
 /// rose by more than the sailing buffer is a fresh charge, not
 /// sailing maintenance (see SessionRules.chargeLegNotifies).
    private var chargeLegStartPercent: Double?
 /// Set when a discharge is cancelled from this side; suppresses the
 /// mirror's session-end event (only daemon floor completion counts).
    private var suppressDischargeEvent = false
 /// The daemon mirror has actually reported the session active at
 /// least once; an optimistic-only start that never came up must not
 /// read as a completed discharge.
    private var dischargeMirrorConfirmed = false
 /// Generation counter for discharge-mirror requests. XPC replies are
 /// ordered, so a poll issued BEFORE startDischarge/cancel is
 /// guaranteed to answer "inactive" after the optimistic latch is set;
 /// without this guard that stale reply would wipe the latch, the
 /// adapter-restore defense would fight the daemon's cut, and the next
 /// tick would start a second session.
    private var dischargeMirrorEpoch = 0
    @Published private(set) var dischargeStartPending = false
    private var observedDischargeID: String?
    private var calibrationDischargeID: String?
    private var calibrationDischargeResult: DischargePhase?
    private var smc: AppleSMCClient?
 /// Firmware has a user-writable charging-switch key (CHTE/CH0C): the
 /// adapter keeps powering the machine while charging is off. On
 /// keyless firmware (26.7.3) a hold means the adapter is cut and the
 /// battery carries the machine — the status text must say which. The
 /// SMC key table is firmware-level, so one probe at init is enough.
 /// Default-value expression: the engine init reads `self` early, so
 /// this must not be assigned inside the init body.
    let chargingSwitchAvailable: Bool = (try? AppleSMCClient())
        .flatMap { ChargeController(client: $0).chargingKey } != nil
    private var timer: Timer?
 /// Last MagSafe color we asserted (nil = unknown / not yet written).
 /// Read-compare against ACLC each tick: the system resets ACLC on adapter
 /// replug, so we re-assert only when the key actually differs.
    private var lastMagSafeColor: UInt8?
    private var magSafeReleaseInFlight = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var powerSourceObserver: CFRunLoopSource?
 /// Main-queue latch set at will-sleep: while set, the tick never writes
 /// charging/adapter state. Keeps the sleep-stop cut in place even when
 /// the machine half-wakes for maintenance (DarkWake) with the lid still
 /// closed. Cleared on wake.
    private var sleepPauseLatch = false

    init() {
        let d = UserDefaults.standard
        self.limitingEnabled = d.object(forKey: "limitingEnabled") as? Bool ?? false
        self.targetPercent = d.object(forKey: "targetPercent") as? Int ?? 80
        self.sailBufferPercent = d.object(forKey: "sailBufferPercent") as? Int ?? 5
        self.heatProtectionEnabled = d.object(forKey: "heatProtectionEnabled") as? Bool ?? false
        self.heatThresholdC = d.object(forKey: "heatThresholdC") as? Int ?? 35
        self.topUpActive = d.object(forKey: "topUpActive") as? Bool ?? false
        self.sleepStopCharging = d.object(forKey: "sleepStopCharging") as? Bool ?? false
        self.preventSleepUntilLimit = d.object(forKey: "preventSleepUntilLimit") as? Bool ?? false
        self.autoDischargeEnabled = d.object(forKey: "autoDischargeEnabled") as? Bool ?? false
        self.notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? false
        self.hardwareBatteryPercent = d.object(forKey: "hardwareBatteryPercent") as? Bool ?? false
        self.automaticLowPowerMode = d.bool(forKey: "automaticLowPowerMode")
        self.manualLowPowerMode = LowPowerModePolicy.ManualSession(
            state: d.string(forKey: Self.manualLowPowerModeKey)
                .flatMap(LowPowerModePolicy.ManualSession.State.init(rawValue:)))
        let threshold = d.object(forKey: "lowPowerModeThreshold") as? Int
        self.lowPowerModeThreshold = threshold.flatMap {
            LowPowerModePolicy.thresholdRange.contains($0) ? $0 : nil
        } ?? LowPowerModePolicy.defaultThreshold
        self.exitRestoresCharging = d.object(forKey: "exitRestoresCharging") as? Bool ?? true
        self.actionHistory = (d.data(forKey: "actionHistory")
            .flatMap { try? JSONDecoder().decode([ActionHistoryEntry].self, from: $0) }) ?? []
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.scheduleRules = (UserDefaults.standard.data(forKey: "scheduleRules")
            .flatMap { try? JSONDecoder().decode([ScheduleRule].self, from: $0) }) ?? []
        self.workdayCalendarRegion = d.string(forKey: "workdayCalendarRegion")
            .flatMap(WorkdayCalendarRegion.init(rawValue:))
            ?? WorkdayCalendarRegion.defaultRegion
        var lastFired: [UUID: Date] = [:]
        if let data = d.data(forKey: "scheduleLastFiredDay.localDate.v2"),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastFired = Dictionary(
                uniqueKeysWithValues: dict.compactMap { k, v in
                    UUID(uuidString: k).map { ($0, v) } })
        } else if let data = d.data(forKey: "scheduleLastFiredDay"),
                  let legacy = try? JSONDecoder().decode([String: Date].self, from: data) {
 // Legacy values were local start-of-day instants. Convert once to
 // stable local-date keys so a time-zone change cannot refire today.
            lastFired = Dictionary(
                uniqueKeysWithValues: legacy.compactMap { key, value in
                    UUID(uuidString: key).map {
                        ($0, ScheduleEngine.localDayKey(for: value, calendar: .current))
                    } })
        }
        schedule = ScheduleEngine(lastFiredDay: lastFired)
        self.calibrationActive = d.object(forKey: "calibrationActive") as? Bool ?? false
        self.magsafeLedEnabled = d.object(forKey: "magsafeLedEnabled") as? Bool ?? false
        let smc = try? AppleSMCClient()
        self.smc = smc
        let nativeLimitSupported: Bool
        #if arch(arm64)
        if #available(macOS 26.4, *) {
            nativeLimitSupported = true
        } else {
            nativeLimitSupported = false
        }
        #else
        nativeLimitSupported = false
        #endif
        chargeControlMode = .init(
            nativeLimitSupported: nativeLimitSupported,
            independentSwitchAvailable: smc.flatMap { ChargeController(client: $0).chargingKey } != nil)
        if calibrationActive {
            calibrationDischargeID = d.string(forKey: "calibrationDischargeID")
            let phase = d.string(forKey: "calibrationPhase")
                .flatMap(CalibrationSession.Phase.init(rawValue:))
            calibration = CalibrationSession(
                resuming: phase ?? .chargingToFull,
                fullSince: d.object(forKey: "calibrationFullSince") as? Date,
                legConfirmedActive: d.bool(forKey: "calibrationLegConfirmed"))
        }
        persistScheduleBookkeeping()
        self.workdayCalendarStatus = workdayStatusMessage()
    }

    func start() {
        stop()
        HelperClient.shared.exitRestoresCharging = !chargeControlMode.controlsCharging || exitRestoresCharging
        if !chargeControlMode.controlsCharging {
            if topUpActive { cancelTopUp() }
            if calibrationActive { endCalibration() }
            // An older build may have left a daemon-owned discharge running.
            pendingDischargeCancellation = true
        }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
 // Sleep stop: cut charging (CHTE off) right before the machine goes
 // down, synchronously — an async write can lose the race against the
 // system freeze. The latch keeps the tick from re-enabling charging
 // during DarkWake maintenance wakes; on full wake the next tick
 // converges back to the policy decision.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.chargeControlMode.controlsCharging, self.sleepStopCharging,
                  !HelperInstaller.shared.needsInstall,
                  let smc = self.smc, ChargeController(client: smc).chargingKey != nil else { return }
            switch HelperClient.shared.setChargingSync(enabled: false) {
            case .success:
                self.sleepPauseLatch = true
                self.recordHistory(.sessionCancelled, "睡眠 · 已切断充电")
            case .failure(let error):
                self.helperError = "睡眠停充失败 · \(error.localizedDescription)"
                self.recordHistory(.sessionCancelled, "睡眠停充未确认 · \(error.localizedDescription)")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.sleepPauseLatch {
                NSLog("[ChargeKit] did-wake: releasing sleep-stop latch")
                self.recordHistory(.sessionStarted, "唤醒 · 恢复充电策略")
            }
            self.sleepPauseLatch = false
            self.resetAdapterProbe()
            self.refreshLowPowerMode()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSourceObserver = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<ChargeEngine>.fromOpaque(context).takeUnretainedValue().refreshLowPowerMode()
        }, context)?.takeRetainedValue()
        if let powerSourceObserver {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceObserver, .commonModes)
        }
        refreshWorkdayCalendarData()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let powerSourceObserver { CFRunLoopSourceInvalidate(powerSourceObserver) }
        powerSourceObserver = nil
        for o in [sleepObserver, wakeObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        sleepObserver = nil
        wakeObserver = nil
    }

    deinit { stop() }

 // MARK: session control (UI actions)

    func startTopUp() {
        guard chargeControlMode.controlsCharging, limitingEnabled, !nativeLimitStallActive else { return }
        if dischargeStartPending { dischargeMirrorEpoch += 1 }
        if dischargeActive { cancelDischarge() }
        topUpActive = true
        recordHistory(.sessionStarted, "充满一次")
    }

    func cancelTopUp() {
        topUpActive = false
 // Leg ended abnormally: it must not read as a fresh charge that
 // reached the (lower, user) limit on the next tick.
        chargeLegStartPercent = nil
        recordHistory(.sessionCancelled, "取消充满")
    }

    func startDischarge(completion: ((Bool) -> Void)? = nil) {
        guard chargeControlMode.controlsCharging, limitingEnabled, !dischargeStartPending else {
            completion?(false)
            return
        }
        let floor = targetPercent
        let epoch = dischargeMirrorEpoch
        dischargeStartPending = true
        HelperInstaller.shared.installIfNeeded { [weak self] error in
            guard let self else { return }
            self.dischargeStartPending = false
            if let error {
                self.helperError = error.localizedDescription
                completion?(false)
                return
            }
            guard self.limitingEnabled, self.targetPercent == floor,
                  self.dischargeMirrorEpoch == epoch, !self.calibrationActive else {
                completion?(false)
                return
            }
            self.beginDischarge(to: floor, completion: completion)
        }
    }

    private func beginDischarge(to floor: Int, completion: ((Bool) -> Void)?) {
        if topUpActive { topUpActive = false }
        recordHistory(.sessionStarted, "放电至 \(floor)%")
 // Optimistic latch so the very next tick does not fight the daemon
 // by restoring the adapter it just cut. Bumping the mirror epoch
 // drops the in-flight poll reply that predates this start (it
 // would otherwise report "inactive" and wipe the latch).
        dischargeMirrorEpoch += 1
        let epoch = dischargeMirrorEpoch
        dischargeActive = true
        dischargeFloor = floor
        suppressDischargeEvent = false
        dischargeMirrorConfirmed = false
        HelperClient.shared.setDischarge(enabled: true, floorPercent: floor, hardwarePercent: hardwareBatteryPercent) { [weak self] error in
            DispatchQueue.main.async {
                if let self, self.dischargeMirrorEpoch == epoch {
                    self.helperError = error?.localizedDescription
                    if error != nil && !self.dischargeMirrorConfirmed {
                        self.dischargeActive = false
                        self.dischargeFloor = nil
                    }
                }
                completion?(error == nil)
            }
        }
    }

    func cancelDischarge() {
        recordHistory(.sessionCancelled, "取消放电")
        HelperClient.shared.setDischarge(enabled: false, floorPercent: 0, hardwarePercent: hardwareBatteryPercent) { [weak self] error in
            DispatchQueue.main.async {
                self?.helperError = error.map { "\($0.localizedDescription)" }
            }
        }
        dischargeMirrorEpoch += 1
        suppressDischargeEvent = true
        dischargeActive = false
        dischargeFloor = nil
    }

 // MARK: calibration control (UI actions)

    func startCalibration() {
        guard chargeControlMode.controlsCharging, limitingEnabled, !calibrationActive, !nativeLimitStallActive else { return }
        topUpActive = false
        if dischargeActive { cancelDischarge() }
        calibration = CalibrationSession()
        calibrationActive = true
        persistCalibration()
        recordHistory(.sessionStarted, "开始校准")
    }

    func cancelCalibration() {
        recordHistory(.sessionCancelled, "取消校准")
        if calibration.phase == .discharging {
            HelperClient.shared.setDischarge(enabled: false, floorPercent: 0, hardwarePercent: hardwareBatteryPercent) { _ in }
            dischargeMirrorEpoch += 1
            suppressDischargeEvent = true
            dischargeActive = false
            dischargeFloor = nil
        }
        endCalibration()
    }

    private func endCalibration() {
        calibrationActive = false
        calibration = CalibrationSession()
        calibrationDischargeID = nil
        calibrationDischargeResult = nil
 // A full-charge leg ended — its charge progress must not read as
 // a fresh leg reaching the user's limit.
        chargeLegStartPercent = nil
        persistCalibration()
    }

    private func persistCalibration() {
        let d = UserDefaults.standard
        d.set(calibration.phase.rawValue, forKey: "calibrationPhase")
        d.set(calibration.fullSince, forKey: "calibrationFullSince")
        d.set(calibration.legConfirmedActive, forKey: "calibrationLegConfirmed")
        d.set(calibrationDischargeID, forKey: "calibrationDischargeID")
    }

 // MARK: schedule control (S7)

    func makeScheduleRuleDraft() -> ScheduleRule {
        let c = Calendar.current
        let now = Date()
        return ScheduleRule(
            hour: c.component(.hour, from: now),
            minute: c.component(.minute, from: now),
            repeatMode: .daily,
            action: chargeControlMode.controlsCharging ? .setLimit(80) : .setLowPowerMode(true))
    }

    func saveScheduleRule(
        _ draft: ScheduleRule,
        isNew: Bool,
        originalRule: ScheduleRule?,
        enabledWasEdited: Bool
    ) {
        if isNew {
            scheduleRules.append(ScheduleRuleCommit.reconcile(
                draft: draft,
                original: nil,
                current: nil,
                enabledWasEdited: enabledWasEdited,
                now: Date()))
        } else if let index = scheduleRules.firstIndex(where: { $0.id == draft.id }) {
            let current = scheduleRules[index]
            if !current.enabled, draft.enabled, enabledWasEdited {
 // A one-shot that fired while the editor was open can be
 // explicitly re-enabled as a new occurrence today.
                schedule.resetLastFiredDay(for: draft.id)
            }
            scheduleRules[index] = ScheduleRuleCommit.reconcile(
                draft: draft,
                original: originalRule,
                current: current,
                enabledWasEdited: enabledWasEdited,
                now: Date())
        }
    }

    func deleteScheduleRule(_ id: UUID) {
        scheduleRules.removeAll { $0.id == id }
    }

 /// Direct enable/disable from the rule list (no editor involved).
    func setScheduleRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == id }) else { return }
        let current = scheduleRules[index]
        guard current.enabled != enabled else { return }
        let outcome = ScheduleRuleCommit.toggling(
            current,
            enabled: enabled,
            hadFired: schedule.lastFiredDay[id] != nil,
            now: Date())
        if outcome.clearsBookkeeping {
            schedule.resetLastFiredDay(for: id)
        }
        scheduleRules[index] = outcome.rule
    }

    private func persistScheduleBookkeeping() {
        let dict = Dictionary(
            uniqueKeysWithValues: schedule.lastFiredDay.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "scheduleLastFiredDay.localDate.v2")
            UserDefaults.standard.removeObject(forKey: "scheduleLastFiredDay")
        }
    }

    private var scheduleWorkdayCalendar: WorkdayCalendar {
        WorkdayCalendar(
            region: workdayCalendarRegion,
            workingDateKeysByYear: workdayCalendarClient.workingDateKeysByYear)
    }

    private func workdayStatusMessage() -> String {
        guard workdayCalendarRegion == .mainlandChina else {
            return workdayCalendarRegion.detail
        }
        guard hasEnabledWorkdayRules else {
            return "没有已启用的工作日规则，未请求节假日服务。"
        }
        let year = WorkdayCalendar.gregorianYear(for: Date(), calendar: .current)
        return workdayCalendarClient.statusSummary(currentYear: year)
    }

    private var hasEnabledWorkdayRules: Bool {
        scheduleRules.contains { rule in
            guard rule.enabled else { return false }
            if case .weekdays = rule.repeatMode { return true }
            return false
        }
    }

    private func refreshWorkdayCalendarData() {
        let currentYear = WorkdayCalendar.gregorianYear(for: Date(), calendar: .current)
        workdayCalendarRequestYear = currentYear
        workdayCalendarLastCheckAt = Date()
        guard workdayCalendarRegion == .mainlandChina else {
            workdayCalendarStatus = workdayCalendarRegion.detail
            return
        }
        guard hasEnabledWorkdayRules else {
            workdayCalendarStatus = "没有已启用的工作日规则，未请求节假日服务。"
            return
        }

        workdayCalendarStatus = workdayCalendarClient.statusSummary(currentYear: currentYear)
        for year in [currentYear, currentYear + 1] {
            workdayCalendarClient.refreshIfNeeded(year: year) { [weak self] in
                guard let self else { return }
                self.workdayCalendarStatus = self.workdayStatusMessage()
            }
        }
    }

    private func refreshWorkdayCalendarIfNeeded() {
        let currentYear = WorkdayCalendar.gregorianYear(for: Date(), calendar: .current)
        guard workdayCalendarRegion == .mainlandChina,
              hasEnabledWorkdayRules
        else {
            return
        }
        let cacheCheckIsDue = Date().timeIntervalSince(
            workdayCalendarLastCheckAt ?? .distantPast) >= 24 * 60 * 60
        guard currentYear != workdayCalendarRequestYear || cacheCheckIsDue else { return }
        refreshWorkdayCalendarData()
    }

 /// Apply a fired scheduled action. Explicit planned actions outrank
 /// running sessions: dischargeTo / topUp replace an active discharge.
 /// Actions that only mean something under limiting (everything except
 /// setLimit / LPM) turn limiting on first — a scheduled task is an
 /// explicit user plan and must not silently no-op.
 /// Record an executed action in the history (newest first, capped).
 /// Called on the main thread from every action exit point.
    func recordHistory(_ kind: ActionHistoryEntry.Kind, _ detail: String) {
        actionHistory.insert(
            ActionHistoryEntry(timestamp: Date(), kind: kind, detail: detail),
            at: 0)
        if actionHistory.count > 100 {
            actionHistory = Array(actionHistory.prefix(100))
        }
        if let data = try? JSONEncoder().encode(actionHistory) {
            UserDefaults.standard.set(data, forKey: "actionHistory")
        }
    }

 /// Clear all history entries.
    func clearHistory() {
        actionHistory = []
        UserDefaults.standard.removeObject(forKey: "actionHistory")
    }

    private func applyScheduled(_ action: ScheduleAction, batteryPercent pct: Double,
                                completion: @escaping (Bool) -> Void) {
        if case .setLowPowerMode(let on) = action,
           let target = managedLowPowerModeTarget {
            if on != target {
                let reason = manualLowPowerMode.target == nil ? "自动规则优先" : "手动设置优先"
                recordHistory(.scheduledAction, "\(action.historyDetail) · \(reason)")
            }
            completion(on == target && lowPowerModeEnabled == on)
            return
        }
        switch action {
        case .setLimit(let v):
            targetPercent = min(max(v, 50), 100)
        case .dischargeTo(let v):
            limitingEnabled = true
            targetPercent = min(max(v, 50), 100)
            startDischarge(completion: completion)
            return
        case .pauseCharging:
            pauseChargingForSchedule(batteryPercent: pct, completion: completion)
            return
        case .topUp:
            guard !nativeLimitStallActive else { completion(false); return }
            limitingEnabled = true
            startTopUp()
        case .startCalibration:
            guard !calibrationActive, !nativeLimitStallActive else { completion(false); return }
            limitingEnabled = true
            startCalibration()
        case .setLowPowerMode(let on):
            guard !lowPowerModeWriteInFlight else { completion(false); return }
            if lowPowerModeEnabled == on { completion(true) }
            else { writeLowPowerMode(on, completion: completion) }
            return
        }
        completion(true)
    }

    private func pauseChargingForSchedule(batteryPercent: Double, completion: @escaping (Bool) -> Void) {
        guard batteryPercent.isFinite, !sleepPauseLatch, !dischargeActive, !dischargeStartPending,
              !calibrationActive, !topUpActive,
              powerSourceSnapshot().internalBatterySource == .external else {
            completion(false)
            return
        }
        scheduledPauseInFlight = true
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            self.scheduledPauseInFlight = false
            if let error {
                self.helperError = "定时停充未确认 · \(error.localizedDescription)"
                completion(false)
                return
            }
            self.limitingEnabled = true
            self.targetPercent = Int(min(max(batteryPercent, 10), 100))
            completion(true)
        }
        HelperInstaller.shared.installIfNeeded { [weak self] error in
            if let error { finish(error); return }
            guard let self, !self.sleepPauseLatch, !self.dischargeActive, !self.dischargeStartPending,
                  !self.calibrationActive, !self.topUpActive,
                  powerSourceSnapshot().internalBatterySource == .external else {
                self?.scheduledPauseInFlight = false
                completion(false)
                return
            }
            HelperClient.shared.setCharging(enabled: false, completion: finish)
        }
    }

    func supportsScheduleAction(_ action: ScheduleAction) -> Bool {
        if case .setLowPowerMode = action { return true }
        return chargeControlMode.controlsCharging
    }

    private func evaluateSchedule(batteryPercent: Double) {
        refreshWorkdayCalendarIfNeeded()
        guard !scheduledActionInFlight else { return }
        let now = Date()
        let calendar = Calendar.current
        scheduleRetryAfter = scheduleRetryAfter.filter { $0.value > now }
        let year = WorkdayCalendar.gregorianYear(for: now, calendar: .current)
        let waitingForCalendar = workdayCalendarRegion == .mainlandChina
            && workdayCalendarClient.isLoading(year: year)
            && !workdayCalendarClient.hasCalendar(year: year)
        let eligible = scheduleRules.filter { rule in
            guard supportsScheduleAction(rule.action) else { return false }
            guard scheduleRetryAfter[rule.id] == nil else { return false }
            if waitingForCalendar, case .weekdays = rule.repeatMode { return false }
            return true
        }
        guard let due = schedule.pendingRules(
            eligible, now: now, calendar: calendar, workdayCalendar: scheduleWorkdayCalendar
        ).first, let original = eligible.first(where: { $0.id == due.id }) else { return }
        scheduledActionInFlight = true
        applyScheduled(due.action, batteryPercent: batteryPercent) { [weak self] succeeded in
            guard let self else { return }
            self.scheduledActionInFlight = false
            guard let index = self.scheduleRules.firstIndex(of: original) else { return }
            if succeeded {
                self.schedule.markFired(due.id, on: now, calendar: calendar)
                if !due.enabled { self.scheduleRules[index].enabled = false }
                self.persistScheduleBookkeeping()
                self.recordHistory(.scheduledAction, due.action.historyDetail)
            } else {
                self.scheduleRetryAfter[due.id] = Date().addingTimeInterval(60)
            }
        }
    }

    private func estimateRuntime(batteryPower: Double?, batteryVolts: Double?) -> Double? {
        if let batteryPower {
            runtimeEstimator.addSample(batteryPower: batteryPower, dt: Self.tickInterval)
        } else {
            runtimeEstimator.reset()
        }
        guard runtimeEstimator.isReady, let batteryVolts, batteryVolts > 0 else { return nil }
        return runtimeEstimator.estimatedMinutes(
            remainingMah: BatteryInfoReader.currentCapacity(), voltage: batteryVolts)
    }

    private func recordAdapterConnection(_ attached: Bool) {
        if let prevACAttached, attached != prevACAttached {
            recordHistory(attached ? .sessionStarted : .sessionCancelled,
                          attached ? "适配器已接入" : "适配器已拔出")
        }
        prevACAttached = attached
    }

    private func syncMagSafeColor(_ color: UInt8, using smc: AppleSMCClient) {
        guard magsafeLedEnabled, !magSafeReleaseInFlight, let current = try? smc.read(SMCKey("ACLC")),
              let currentColor = current.first else { return }
        if currentColor != color, prepareHelperForControl() {
            lastMagSafeColor = color
            HelperClient.shared.setMagSafeColor(color)
        }
    }

    private func prepareHelperForControl() -> Bool {
        let installer = HelperInstaller.shared
        guard !installer.installInProgress else { return false }
        if !installer.needsInstall { return true }
        installer.installIfNeeded { [weak self] error in
            guard let self else { return }
            let message = error?.localizedDescription
            if self.helperError != message { self.helperError = message }
        }
        return false
    }

    private func releaseMagSafeColorIfNeeded() {
        guard !magsafeLedEnabled, lastMagSafeColor != nil, !magSafeReleaseInFlight else { return }
        magSafeReleaseInFlight = true
        HelperClient.shared.releaseMagSafeColor { [weak self] error in
            guard let self else { return }
            self.magSafeReleaseInFlight = false
            if error == nil, !self.magsafeLedEnabled { self.lastMagSafeColor = nil }
        }
    }

    private func cancelStaleDischargeIfNeeded() {
        guard pendingDischargeCancellation, !dischargeCancellationInFlight else { return }
        dischargeCancellationInFlight = true
        HelperClient.shared.cancelStaleDischarge(hardwarePercent: hardwareBatteryPercent) { [weak self] error in
            guard let self else { return }
            self.dischargeCancellationInFlight = false
            if error == nil { self.pendingDischargeCancellation = false }
        }
    }

    private func resetAdapterProbe() {
        adapterProbeAttempts = 0
        adapterProbeRetryAfter = 0
        adapterProbeEpoch += 1
    }

    private func refreshDischargeMirror() {
        let mirrorEpoch = dischargeMirrorEpoch
        HelperClient.shared.dischargeStatus { phase, floor, id, error in
            DispatchQueue.main.async {
                guard self.dischargeMirrorEpoch == mirrorEpoch else { return }
                if let error {
                    self.helperError = error.localizedDescription
                    return
                }
                guard let phase else { return }
                let wasActive = self.dischargeActive
                let matchesPreviousSession = id != nil && id == self.observedDischargeID
                let matchesCalibration = id != nil && id == self.calibrationDischargeID
                self.dischargeActive = phase.ownsAdapter
                self.dischargeFloor = phase.ownsAdapter && floor > 0 ? floor : nil
                if phase.ownsAdapter {
                    self.dischargeMirrorConfirmed = true
                    self.observedDischargeID = id
                    if self.calibrationActive, self.calibration.phase == .discharging,
                       self.calibrationDischargeID == nil, let id {
                        self.calibrationDischargeID = id
                        self.persistCalibration()
                    }
                } else if wasActive {
                    if phase == .reachedFloor, matchesPreviousSession, self.dischargeMirrorConfirmed,
                       !self.suppressDischargeEvent,
                       !self.calibrationActive {
                        self.onEvent?(.dischargeFinished(floor: floor))
                        self.recordHistory(.sessionCompleted, "放电完成 · 到达 \(floor)%")
                    } else if !self.calibrationActive, !self.suppressDischargeEvent, phase == .failed {
                        self.recordHistory(.sessionCancelled, "放电中止 · 适配器已恢复")
                    }
                    self.suppressDischargeEvent = false
                    self.dischargeMirrorConfirmed = false
                }
                if matchesCalibration { self.calibrationDischargeResult = phase.result }
            }
        }
    }

    private func recoverAdapterIfNeeded(_ recovery: SessionRules.ChargeControlMode.AdapterRecovery) {
        let maxProbeAttempts = 3
        if recovery != .probe, adapterProbeAttempts > 0 || adapterProbeRetryAfter > 0 {
            resetAdapterProbe()
        }
        if recovery == .none { awaitingAdapterPower = false }
        guard recovery != .none, !adapterRestoreInFlight else { return }

        let uptime = ProcessInfo.processInfo.systemUptime
        if recovery == .probe, uptime < adapterProbeRetryAfter { return }
        guard uptime >= adapterRestoreAfter else { return }
        adapterRestoreAfter = uptime + 5
        adapterRestoreInFlight = true
        awaitingAdapterPower = true
        let epoch = adapterProbeEpoch
        if recovery == .probe {
            adapterProbeAttempts += 1
            if adapterProbeAttempts >= maxProbeAttempts {
                adapterProbeAttempts = 0
                adapterProbeRetryAfter = uptime + 60
            }
        }
        HelperClient.shared.restoreAdapter { [weak self] error in
            guard let self else { return }
            self.adapterRestoreInFlight = false
            if recovery == .restore || self.adapterProbeEpoch == epoch {
                self.helperError = error.map { "恢复适配器供电失败 · \($0.localizedDescription)" }
            }
        }
    }

    private var chargeConfig: ChargeConfig {
        ChargeConfig(
            limitingEnabled: limitingEnabled,
            targetPercent: targetPercent,
            sailBufferPercent: sailBufferPercent,
            heatProtectionEnabled: heatProtectionEnabled,
            heatThresholdC: Double(heatThresholdC))
    }

    private func readDCInVoltage() -> Double? {
        smc.flatMap { try? ChargeController(client: $0).dcInVoltage() }
    }

    private func lowPowerModeSource(
        internalSource: LowPowerModePolicy.PowerSource?, dcInVoltage: Double?
    ) -> LowPowerModePolicy.PowerSource? {
        if SessionRules.wallAttached(dcInVoltage: dcInVoltage) { return .external }
        return internalSource
    }

    private func refreshLowPowerMode() {
        let sources = powerSourceSnapshot()
        updateLowPowerMode(
            source: lowPowerModeSource(internalSource: sources.internalBatterySource, dcInVoltage: readDCInVoltage()),
            batteryPercent: sources.macosPercent)
    }

    private func tick() {
        releaseMagSafeColorIfNeeded()
 // One IOPowerSources snapshot per tick (two separate
 // copies was pure main-thread waste): AC state, the macOS gauge
 // percent for the battery-info view and the basis selection, and
 // the AC-edge signal for the caching reader.
        let powerSources = powerSourceSnapshot()
        let macosPercent = powerSources.macosPercent
        let acChanged = (lastACAttached ?? powerSources.acAttached) != powerSources.acAttached
        lastACAttached = powerSources.acAttached

 // Keep health and macOS gauge data available even when SMC is unavailable.
        let batteryInfo = batteryInfoReader.read(macosPercent: macosPercent, acChanged: acChanged)
        DispatchQueue.main.async {
            guard self.batteryInfo != batteryInfo else { return }
            self.batteryInfo = batteryInfo
        }

        let controller = smc.map { ChargeController(client: $0) }
        // Voltage distinguishes a physically attached adapter even if a
        // discharge session has cut its input and macOS reports battery power.
        let dcInVoltage = controller.flatMap { try? $0.dcInVoltage() }
        updateLowPowerMode(
            source: lowPowerModeSource(internalSource: powerSources.internalBatterySource, dcInVoltage: dcInVoltage),
            batteryPercent: macosPercent)

        if !chargeControlMode.controlsCharging {
            let adapterEnabled = controller.flatMap { try? $0.isAdapterEnabled() }
            let physicalConnection = SessionRules.wallAttached(dcInVoltage: dcInVoltage)
            let external = powerSources.internalBatterySource == .external
            let rawPercent = controller.flatMap { try? $0.batteryPercent() }
            let recovery = chargeControlMode.adapterRecovery(
                adapterEnabled: adapterEnabled, dcInVoltage: dcInVoltage,
                externalPower: external,
                hasBattery: macosPercent != nil || powerSources.internalBatterySource != nil || rawPercent != nil,
                awaitingPowerConfirmation: awaitingAdapterPower)
            if powerSources.internalBatterySource != nil || physicalConnection {
                recordAdapterConnection(external || physicalConnection)
            }
            if recovery != .none {
                let installer = HelperInstaller.shared
                let confirmedCut = adapterEnabled == false
                if (installer.isInstalled && !installer.needsInstall)
                    || (confirmedCut && prepareHelperForControl()) {
                    cancelStaleDischargeIfNeeded()
                    recoverAdapterIfNeeded(recovery)
                }
            } else {
                recoverAdapterIfNeeded(.none)
            }
            let pct = macosPercent.map(Double.init) ?? rawPercent ?? 0
            evaluateSchedule(batteryPercent: pct)
            let volts = controller.flatMap { try? $0.batteryVoltage() }
            let amps = controller.flatMap { try? $0.batteryCurrent() }
            let power = controller.flatMap { try? $0.dcInPower() }.flatMap { $0.isFinite ? $0 : nil }
            let batteryPower = volts.flatMap { v in amps.map { v * $0 } }
            let phase: ChargePhase
            if powerSources.internalBatterySource == .battery {
                phase = .discharging
            } else if chargeControlMode == .systemManaged {
                phase = .systemManaged
            } else {
                phase = .idle
            }
            publishSnapshot(Snapshot(
                batteryPercent: pct, hardwareBatteryPercent: rawPercent, dcInPower: power,
                batteryTemp: controller.flatMap { try? $0.batteryTemp() }, batteryPower: batteryPower,
                hostPower: power.flatMap { input in batteryPower.map { max(input - $0, 0) } },
                batteryVolts: volts, batteryAmps: amps,
                runtimeEstimateMinutes: estimateRuntime(batteryPower: batteryPower, batteryVolts: volts),
                chargingEnabled: powerSources.isCharging == true, phase: phase,
                chargePaused: external && powerSources.isCharging == false,
                adapterRecoveryNeeded: recovery != .none && (physicalConnection || external),
                systemPowerSource: powerSources.internalBatterySource, systemIsCharging: powerSources.isCharging,
                systemBatteryPercent: macosPercent))
            if external, adapterEnabled != false, let isCharging = powerSources.isCharging, let smc {
                syncMagSafeColor(isCharging ? MagSafeColor.orange : MagSafeColor.green, using: smc)
            }
            return
        }

        guard let smc, let controller else {
            runtimeEstimator.reset()
            DispatchQueue.main.async {
                self.publishReadError("SMC unavailable")
            }
            return
        }
        let pct: Double
        let hardwarePct: Double   // raw BUIC: stall detector + dual-percent row
        let temp: Double?  // nil on read failure; policy treats nil as "no heat check"
        let chargingOn: Bool
        let adapterOn: Bool
        do {
 // Battery-percent basis (parity): the macOS gauge value
 // by default — the number users see in the system UI — with the
 // hardware toggle switching every feature to the BMS-direct
 // value. BMS is the fallback when IOPowerSources is unreadable.
 // hardwarePct stays raw: the stall detector must watch the
 // PHYSICAL value (BUIC pins near-full while the gauge lags —
 // review round 2, P1-2), and the dual-percent row labels it.
            hardwarePct = try controller.batteryPercent()
            pct = SessionRules.effectiveBatteryPercent(
                hardware: hardwarePct,
                macos: macosPercent,
                useHardware: hardwareBatteryPercent)
            temp = try? controller.batteryTemp()
            chargingOn = try controller.isChargingEnabled()
            adapterOn = try controller.isAdapterEnabled()
        } catch {
 // Telemetry lost: release the sleep assertion (its "charging
 // to limit" rationale is stale) and drop the charge-leg
 // anchor so a recovery above the limit does not read as a
 // completed leg.
            sleepGuard.setPreventIdleSleep(false)
            chargeLegStartPercent = nil
            runtimeEstimator.reset()
            DispatchQueue.main.async { self.publishReadError("\(error)") }
            return
        }

 // Power flow: battery power from the gauge keys (V × I); host draw
 // follows from the energy balance (adapter input charges the battery
 // or runs the machine). Clamped ≥ 0: the two ADCs can disagree by a
 // few percent near zero net flow.
        let power = (try? controller.dcInPower()).flatMap { $0.isFinite ? $0 : nil }
        let batteryVolts = try? controller.batteryVoltage()
        let batteryAmps = try? controller.batteryCurrent()
        let batteryPower = batteryVolts.flatMap { volts in batteryAmps.map { volts * $0 } }
        let hostPower = power.flatMap { input in batteryPower.map { max(input - $0, 0) } }

 // Runtime estimate: EMA over the live battery power. A missing gauge
 // reading (nil batteryPower) can't feed the filter — reset so a stale
 // estimate never survives a telemetry gap. Remaining charge is a
 // separate per-tick read; its absence alone just hides the number.
        let runtimeMinutes = estimateRuntime(batteryPower: batteryPower, batteryVolts: batteryVolts)

 // Wall-power presence: IOPowerSources OR the measured DC-in voltage.
 // While CHIE cuts the adapter input, IOPowerSources reports battery,
 // so a re-plug after a cut would be invisible to it forever; VD0R
 // keeps reading the negotiated PD voltage in that state (measured
 // 20.31 V with CHIE off) and is the direct physical signal.
        let acAttached = powerSources.acAttached
            || SessionRules.wallAttached(dcInVoltage: dcInVoltage)

 // Sleep-stop latch: lid still closed (sleep or a maintenance
 // DarkWake) — never write charging/adapter state; the pre-sleep cut
 // stands until the real wake clears the latch.
        if sleepPauseLatch {
            let phase: ChargePhase = dischargeActive || !acAttached
                ? .discharging : .holding
            sleepGuard.setPreventIdleSleep(false)
 // No limit-reached event here: the sleep-stop cut is not the
 // limit; prevPhase still tracks so the wake transition does
 // not misread.
            prevPhase = phase
            chargeLegStartPercent = nil
            DispatchQueue.main.async {
                self.publishSnapshot(Snapshot(
                    batteryPercent: pct, hardwareBatteryPercent: hardwarePct,
                    dcInPower: power, batteryTemp: temp,
                    batteryPower: batteryPower, hostPower: hostPower,
                    batteryVolts: batteryVolts, batteryAmps: batteryAmps,
                    runtimeEstimateMinutes: runtimeMinutes,
                    chargingEnabled: chargingOn, phase: phase, readError: nil))
            }
            return
        }

 // Scheduled tasks: explicit planned actions, so they fire even
 // during a discharge (they may replace it) — but never while the
 // sleep latch holds (lid closed / DarkWake maintenance wake).
 // Same-day catch-up happens naturally: dueRules sees any
 // occurrence whose time already passed today.
        evaluateSchedule(batteryPercent: pct)
        let chargingControlRequested = limitingEnabled || heatProtectionEnabled || sleepStopCharging
            || calibrationActive || dischargeActive
        let chargingHelperReady = chargingControlRequested && prepareHelperForControl()
        let canRestorePower = chargingHelperReady || (!adapterOn && prepareHelperForControl())
            || (!chargingControlRequested && !HelperInstaller.shared.needsInstall)

 // Track the daemon-owned discharge session (async; next tick uses it).
 // A true→false mirror transition is a completed drain — but only
 // when the daemon actually confirmed the session (an optimistic
 // start that never came up must not read as completion) and this
 // side did not cancel it; the calibration discharge leg reports
 // through its own completed event. Replies predating the latest
 // start/cancel (epoch mismatch) are dropped — they would describe
 // a world that no longer exists.
        let shouldMirrorDischarge = canRestorePower && (limitingEnabled || calibrationActive
            || dischargeActive || !adapterOn)
        if shouldMirrorDischarge {
            refreshDischargeMirror()
        }

 // Drive the calibration cycle (charge/dwell legs evaluate here; the
 // discharge leg is daemon-owned and falls into the branch below).
        if calibrationActive, chargingHelperReady {
            if !limitingEnabled { endCalibration() }
            if calibrationActive {
                let event = calibration.tick(
                    batteryPercent: pct, acAttached: acAttached,
                    dischargeActive: dischargeActive, dischargeResult: calibrationDischargeResult, now: Date(),
                    config: calibrationConfig)
                switch event {
                case .beginDischarge:
                    dischargeMirrorEpoch += 1
 // No optimistic mirror: the session's 15 s grace absorbs
 // XPC/poll latency and detects a session that never came up.
                    HelperClient.shared.setDischarge(
                        enabled: true, floorPercent: calibrationConfig.dischargeFloorPercent,
                        hardwarePercent: hardwareBatteryPercent
                    ) { [weak self] error in
                        DispatchQueue.main.async {
                            self?.helperError = error.map { "\($0.localizedDescription)" }
                        }
                    }
                case .completed:
                    endCalibration()
                    onEvent?(.calibrationCompleted)
                    recordHistory(.sessionCompleted, "校准完成")
                case .aborted:
                    recordHistory(.sessionCancelled, "校准被中止 · 充电阶段拔电或会话丢失")
                    endCalibration()
                case nil:
                    break
                }
                if calibrationActive { persistCalibration() }
            }
        }

        if dischargeActive {
 // The daemon owns the adapter during discharge; the engine only
 // enforces the heat-cancel rule (draining under load heats the
 // battery) and must NOT run the adapter-restore defense below.
            if SessionRules.heatCancelsDischarge(
                batteryTemp: temp,
                heatProtectionEnabled: heatProtectionEnabled,
                heatThresholdC: Double(heatThresholdC))
            {
                if calibrationActive { cancelCalibration() } else { cancelDischarge() }
            }
            sleepGuard.setPreventIdleSleep(false)
            prevPhase = .discharging
            chargeLegStartPercent = nil
            DispatchQueue.main.async {
                self.publishSnapshot(Snapshot(
                    batteryPercent: pct, hardwareBatteryPercent: hardwarePct,
                    dcInPower: power, batteryTemp: temp,
                    batteryPower: batteryPower, hostPower: hostPower,
                    batteryVolts: batteryVolts, batteryAmps: batteryAmps,
                    runtimeEstimateMinutes: runtimeMinutes,
                    chargingEnabled: chargingOn, phase: .discharging, readError: nil))
            }
            return
        }

 // Charging-switch mode never cuts the adapter; if it is off (stale
 // adapter-mode state, an external cut, or a just-finished discharge),
 // restore wall power.
        if controller.chargingKey != nil, !adapterOn, canRestorePower {
            HelperClient.shared.setAdapter(enabled: true) { [weak self] error in
                DispatchQueue.main.async {
                    self?.helperError = error.map { "\($0.localizedDescription)" }
                }
            }
        }

        var config = chargeConfig
        let topUpWasActive = topUpActive
        if topUpActive {
            if !limitingEnabled
                || SessionRules.topUpEnded(batteryPercent: pct, acAttached: acAttached)
            {
 // Ended by reaching (near) full — worth telling the user.
 // Unplug or limiting-off ends are silent.
                if acAttached, pct >= SessionRules.topUpEndedThreshold {
                    onEvent?(.topUpCompleted)
                    recordHistory(.sessionCompleted, "充满完成")
                }
                topUpActive = false
                chargeLegStartPercent = nil  // leg ended — no limitReached
            } else {
                config.targetPercent = 100
            }
        }
 // Calibration charge/dwell legs ride the same effective-target
 // override (the user's configured limit is never touched). The
 // buffer is squeezed to 1 so the sailing bottom threshold sits at
 // 99: a cycle started inside the 96–99 dead-band still tops up to
 // a true full charge instead of stalling mid-band.
        if calibrationActive, calibration.phase != .discharging {
            config.targetPercent = 100
            config.sailBufferPercent = 1
        }

        let decision = policy.evaluate(
            batteryPercent: pct, batteryTemp: temp,
            chargingOn: chargingOn, config: config)

 // Prevent idle sleep while charging toward the (effective) limit.
 // config.targetPercent already carries the Top Up / calibration
 // override to 100 at this point. The assertion is held only while
 // the policy actively charges; every other state (sailing hold,
 // heat pause, discharge, battery) releases it.
        sleepGuard.setPreventIdleSleep(SessionRules.preventIdleSleep(
            enabled: preventSleepUntilLimit, limitingEnabled: limitingEnabled,
            acAttached: acAttached, chargingOn: decision.chargingOn,
            batteryPercent: pct, targetPercent: config.targetPercent))

 // Auto-discharge: plugged in and meaningfully above the limit ->
 // drain down to it (daemon session, floor = limit). Explicit
 // sessions and a heat pause take precedence; the guards already
 // exclude Top Up / calibration, so config.targetPercent here
 // equals the user's limit.
        if chargingHelperReady, !dischargeStartPending, !scheduledPauseInFlight, SessionRules.autoDischargeShouldStart(
            enabled: autoDischargeEnabled, limitingEnabled: limitingEnabled,
            acAttached: acAttached, batteryPercent: pct,
            targetPercent: targetPercent,
            dischargeActive: dischargeActive, topUpActive: topUpActive,
            calibrationActive: calibrationActive,
            heatPaused: decision.phase == .heatPaused)
        {
            NSLog("[ChargeKit] auto-discharge: %.1f%% above limit %d, starting session", pct, targetPercent)
 // Distinguish from a manual start in the history log.
            recordHistory(.sessionStarted, "自动放电至 \(targetPercent)%")
            startDischarge()
        }

        var newSnapshot = Snapshot(
            batteryPercent: pct, hardwareBatteryPercent: hardwarePct,
            dcInPower: power, batteryTemp: temp,
            batteryPower: batteryPower, hostPower: hostPower,
            batteryVolts: batteryVolts, batteryAmps: batteryAmps,
            runtimeEstimateMinutes: runtimeMinutes,
            chargingEnabled: chargingOn, phase: decision.phase, readError: nil,
            chargePaused: acAttached && (BatteryInfoReader.chargePaused() ?? false),
            systemIsCharging: powerSources.isCharging)

 // Without wall power the limiter is not actively doing anything and
 // the battery carries the machine — phase labels like "已停在 X%（适配器
 // 供电）" would be wrong. statusText separates this from a discharge
 // session via dischargeActive.
        if !acAttached {
            newSnapshot.phase = .discharging
        } else if newSnapshot.phase == .charging, newSnapshot.chargePaused {
            newSnapshot.phase = .chargePaused
        }

 // Limit-reached notification: only a charging leg that rose more
 // than the sailing buffer crossing into the hold counts — sailing
 // maintenance top-ups and dragging the limit under the battery
 // stay silent (SessionRules.chargeLegNotifies).
        if newSnapshot.phase == .charging, prevPhase != .charging {
            chargeLegStartPercent = pct
        }
        if prevPhase == .charging, newSnapshot.phase == .holding,
           !topUpWasActive, !calibrationActive, limitingEnabled,
           let legStart = chargeLegStartPercent,
           SessionRules.chargeLegNotifies(
               startPercent: legStart, endPercent: pct,
               sailBufferPercent: sailBufferPercent)
        {
            onEvent?(.limitReached(target: targetPercent))
            recordHistory(.limitReached, "达到充电上限 \(targetPercent)%")
        }
        if newSnapshot.phase != .charging { chargeLegStartPercent = nil }

 // Heat-pause / release edges (history audit: "why did charging
 // stop/resume?").
        if newSnapshot.phase == .heatPaused, prevPhase != .heatPaused {
            if let t = temp {
                recordHistory(.sessionCancelled, "过热暂停充电 · \(String(format: "%.1f", t))°C")
            } else {
                recordHistory(.sessionCancelled, "过热暂停充电")
            }
        }
        if prevPhase == .heatPaused, newSnapshot.phase != .heatPaused {

            recordHistory(.sessionStarted, "过热恢复充电")
        }

        recordAdapterConnection(acAttached)

        prevPhase = newSnapshot.phase

        if !scheduledPauseInFlight, controller.chargingKey != nil, decision.chargingOn != chargingOn,
           chargingHelperReady || !chargingControlRequested && decision.chargingOn && canRestorePower {
            let wanted = decision.chargingOn
 // A charging-off transition only applies while wall power is present.
            if wanted || acAttached {
                HelperClient.shared.setCharging(enabled: wanted) { [weak self] error in
                    DispatchQueue.main.async {
                        self?.helperError = error.map { "\($0.localizedDescription)" }
                    }
                }
            }
        }
        DispatchQueue.main.async { self.publishSnapshot(newSnapshot) }

 // Native charge-limit stall: a full-charge leg is stalled only when
 // the policy itself wants a charge toward 100 (decision.chargingOn)
 // yet CHTE reads back off and the battery will not rise. When our
 // sailing layer is holding at the user's own target (decision off),
 // that is a normal hold, never the macOS cap — skip the detector
 // entirely so the window does not run during the hold.
        let fullChargeLegActive = acAttached && (topUpActive
            || (calibrationActive && calibration.phase != .discharging))
        if fullChargeLegActive, decision.chargingOn {
 // Raw BUIC (review round 2, P1-2): the gauge lags near full, so
 // a macOS-basis pct would flat-line under 99 during the trickle
 // tail and read as a native-limit stall.
            stallDetector.tick(batteryPercent: hardwarePct, chargingOn: chargingOn)
            if stallDetector.stalled {
                NSLog("[ChargeKit] native-limit stall: pct=%.1f chargingOn=%@ wantsCharge=%@ target=%d buffer=%d",
                      pct, chargingOn ? "yes" : "no", decision.chargingOn ? "yes" : "no",
                      config.targetPercent, config.sailBufferPercent)
 // The macOS limit caps below 100: the leg can never finish.
 // End it (back to the normal limit) so the user is not left
 // pinned at the system cap; they can raise the macOS limit
 // and start the leg again. Hold the warning for a while so
 // it outlives the leg it just ended.
                NSLog("[ChargeKit] native-limit stall detected — ending full-charge leg")
                nativeLimitStalledUntil = Date().addingTimeInterval(15)
                onEvent?(.nativeLimitStalled)
                recordHistory(.nativeLimitStall, "被 macOS 系统上限卡住 · 已结束本次充满/校准")
                chargeLegStartPercent = nil  // leg ended — no limitReached
                if topUpActive { topUpActive = false }
                if calibrationActive { cancelCalibration() }
            }
        } else {
            stallDetector.reset()
        }
        let stallWarningVisible = stallDetector.stalled
            || (nativeLimitStalledUntil.map { Date() < $0 } ?? false)
        DispatchQueue.main.async {
            self.nativeLimitStalled = stallWarningVisible
            self.fullChargeLegBlocked = self.nativeLimitStallActive
        }

        let expectedColor: UInt8 = !adapterOn ? MagSafeColor.off
            : (newSnapshot.chargingEnabled && !newSnapshot.chargePaused
                ? MagSafeColor.orange : MagSafeColor.green)
        syncMagSafeColor(expectedColor, using: smc)
    }
}

// MARK: - UI

/// System Settings slider idiom: label left, live value right, slider on
/// its own full-width line (values align across rows).
struct SliderRow: View {
    let label: String
    let value: Int
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    var showsTickMarks = true
    var allowsTextEntry = false
    let onEdit: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                if allowsTextEntry {
                    SliderValueField(label: label, value: value, unit: unit, range: range, onEdit: onEdit)
                } else {
                    Text("\(value)\(unit)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)
            slider
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text("\(value)\(unit)"))
        }
    }

    @ViewBuilder
    private var slider: some View {
        let binding = Binding(
            get: { Double(value) },
            set: { onEdit(Int($0.rounded())) })
        if showsTickMarks {
            Slider(value: binding, in: range, step: step)
        } else {
            Slider(value: binding, in: range)
                .accessibilityRepresentation {
                    Slider(value: binding, in: range, step: step)
                        .accessibilityLabel(Text(label))
                        .accessibilityValue(Text("\(value)\(unit)"))
                }
        }
    }
}

private struct SliderValueField: View {
    let label: String
    let value: Int
    let unit: String
    let range: ClosedRange<Double>
    let onEdit: (Int) -> Void
    @State private var draft: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: Binding(
                get: { draft ?? String(value) },
                set: { draft = $0 }))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 50)
                .focused($isFocused)
                .accessibilityLabel(Text(label))
                .accessibilityHint(Text("整数部分须在 \(Int(range.lowerBound)) 到 \(Int(range.upperBound)) 之间，小数部分会舍去"))
                .onSubmit {
                    commit()
                    isFocused = false
                }
                .onChange(of: isFocused) { focused in
                    if !focused { commit() }
                }
                .onChange(of: value) { _ in draft = nil }
                .onDisappear { commit() }
            Text(unit)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .monospacedDigit()
    }

    private func commit() {
        guard let input = draft else { return }
        draft = nil
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let number = Int(parts[0]), range.contains(Double(number)) else {
            NSSound.beep()
            return
        }
        if number != value { onEdit(number) }
    }
}

struct PopoverView: View {
    @ObservedObject var engine: ChargeEngine
    var openSettings: @MainActor (SettingsPane?) -> Void = { _ in }

    var statusText: String { Self.statusText(for: engine.snapshot, engine: engine) }

    static func statusText(for snapshot: ChargeEngine.Snapshot, engine: ChargeEngine) -> String {
        if let err = snapshot.readError { return "SMC 错误：\(err)" }
        if engine.calibrationActive {
            switch engine.calibrationPhase {
            case .chargingToFull: return "校准：充电至满电"
            case .holdingFull: return "校准：满电保持中"
            case .discharging: return "校准：放电至 \(engine.calibrationFloorPercent)%"
            }
        }
 // macOS 原生限制在电量高于系统上限时会主动放电（drain），无论我们
 // 的 phase 意图是什么。电池真实放电（B0AC < 0）时以电气事实为准。
 // 续航估算只在真实放电时出现（状态行 + 电池信息遥测行共用同一份）。
        let runtimeSuffix = snapshot.runtimeEstimateMinutes
            .map { " · 剩余约 \(RuntimeText.short(minutes: $0))" } ?? ""
        if snapshot.adapterRecoveryNeeded {
            return "适配器已连接 · 正在恢复外接供电" + runtimeSuffix
        }
        if !engine.chargeControlMode.controlsCharging {
            switch snapshot.systemPowerSource {
            case .battery: return "电池供电" + runtimeSuffix
            case .external:
                switch snapshot.systemIsCharging {
                case true?: return "适配器供电 · 正在充电"
                case false?: return "适配器供电 · 未充电"
                case nil: return "适配器供电"
                }
            case nil: return "供电状态暂不可用"
            }
        }
        if snapshot.isDrainingWhileChargeManaged {
            return "电池放电中 · macOS 系统限制生效" + runtimeSuffix
        }
        switch snapshot.phase {
        case .idle:
            return "未限制充电"
        case .charging:
            return engine.topUpActive ? "充满中 → 100%" : "充电中 → \(engine.targetPercent)%"
        case .chargePaused:
            return "充电已暂停 · macOS 优化充电中"
        case .holding:
            return "已停在上限 · 适配器供电"
        case .heatPaused:
            let t = snapshot.batteryTemp.map { String(format: "%.1f", $0) } ?? "—"
            return "充电已暂停 · 电池过热 \(t)°C"
        case .discharging:
            if engine.dischargeActive {
                return "放电中 → \(engine.dischargeFloor ?? engine.targetPercent)% · 适配器已断开"
            }
 // 放电会话的进度语义是"到目标电量"，混入"到空"的续航会误导。
            return "电池放电中 · 未接电源" + runtimeSuffix
        case .systemManaged:
            return "由 macOS 管理充电"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                BatteryGaugeView(
                    percent: engine.snapshot.hasBatteryPercent ? engine.snapshot.batteryPercent : nil,
                    phase: engine.snapshot.isDrainingWhileChargeManaged ? .discharging : engine.snapshot.phase,
                    lowPowerMode: engine.lowPowerModeEnabled)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PopoverPowerSummary(snapshot: engine.snapshot, batteryInfo: engine.batteryInfo)

            Divider()

            lowPowerControls
            chargingControls
            if let error = engine.helperError {
                feedback("电源操作未完成 · \(error)", icon: "exclamationmark.circle", color: .red)
            }

            Divider()

            HStack {
                Button {
                    openSettings(.battery)
                } label: {
                    Label("电池信息", systemImage: "info.circle")
                }
                Spacer()
                Button {
                    openSettings(nil)
                } label: {
                    Label("设置…", systemImage: "gearshape")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
        .toggleStyle(.switch)
    }

    private var lowPowerControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { engine.lowPowerModeSwitchValue },
                set: { engine.setLowPowerMode($0) })) {
                    Label("低电量模式", systemImage: "leaf")
                }
                .disabled(engine.lowPowerModeSwitchBusy)
            if engine.lowPowerModeNeedsAuthorization {
                operationProgress("等待管理员授权…")
            } else if engine.lowPowerModeSwitchBusy {
                operationProgress("正在切换低电量模式…")
            } else if let error = engine.lowPowerModeError {
                feedback("无法切换低电量模式 · \(error)", icon: "exclamationmark.circle", color: .red)
            }
        }
    }

    @ViewBuilder
    private var chargingControls: some View {
        switch engine.chargeControlMode {
        case .systemManaged:
            HStack(spacing: 6) {
                Label("macOS 管理充电上限", systemImage: "battery.100percent")
                Spacer(minLength: 6)
                Button("电池设置", action: openSystemBatterySettings)
            }
        case .monitoringOnly:
            Label("此 Mac 仅支持电池监控", systemImage: "battery.100percent")
                .foregroundStyle(.secondary)
        case .independentSwitch:
            VStack(alignment: .leading, spacing: 8) {
                if engine.calibrationActive {
                    sessionButton("取消校准", action: engine.cancelCalibration)
                } else if engine.dischargeStartPending {
                    operationProgress("正在准备放电…")
                } else if engine.dischargeActive {
                    sessionButton("取消放电", action: engine.cancelDischarge)
                } else if engine.topUpActive {
                    sessionButton("取消充满", action: engine.cancelTopUp)
                } else {
                    Toggle("限制充电", isOn: $engine.limitingEnabled)
                    if engine.limitingEnabled {
                        SliderRow(label: "充电上限", value: engine.targetPercent, unit: "%",
                                  range: 50...100, step: 5) {
                            engine.targetPercent = $0
                        }
                        HStack(spacing: 8) {
                            Button {
                                engine.startTopUp()
                            } label: {
                                Label("充满一次", systemImage: "bolt.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(engine.fullChargeLegBlocked)
                            Button {
                                engine.startDischarge()
                            } label: {
                                Label("放电至 \(engine.targetPercent)%", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func sessionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func operationProgress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func feedback(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

 /// First-run auto-update confirmation: one headline, one short line,
 /// two buttons — no NSAlert chrome (empty buttons / suppression box).
private struct AutoUpdatePromptView: View {
    let choice: (_ enabled: Bool, _ remindLater: Bool) -> Void
    @State private var declined = false

    var body: some View {
        Group {
            if declined {
                VStack(spacing: 16) {
                    VStack(spacing: 5) {
                        Text("以后要再次提醒吗？")
                            .font(.headline)
                        Text("仍可随时在设置中开启")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("不再提醒") { choice(false, false) }
                            .keyboardShortcut(.cancelAction)
                        Button("下次提醒") { choice(false, true) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    VStack(spacing: 5) {
                        Text("启用自动检查更新？")
                            .font(.headline)
                        Text("有新版本时自动下载")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("不启用") { declined = true }
                            .keyboardShortcut(.cancelAction)
                        Button("启用") { choice(true, false) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 300)
    }
}

/// Scrolls when the popover content exceeds the anchoring screen's available height.
struct PopoverRootView: View {
    let engine: ChargeEngine
    let openSettings: @MainActor (SettingsPane?) -> Void

    var body: some View {
        ScrollView {
            PopoverView(engine: engine, openSettings: openSettings)
        }
        .frame(width: 320)
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var autoUpdatePromptWindow: NSWindow?

    private var statusItem: NSStatusItem!
    private let engine = ChargeEngine()
    private var popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var anchorScreen: NSScreen?
 /// Hidden off-window controller holding the plain content VStack; its
 /// fitting size is the true content height.
    private var measurer: NSHostingController<PopoverView>!

    func applicationShouldHandleReopen(
        _ application: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
 // Clicking the Dock icon shows the settings window as the app's main
 // interface (the menu-bar popover stays attached to the status item).
        showSettings()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
 // Install the notification-center delegate early and route engine
 // events to user notifications (gated by the toggle).
        _ = Notifier.shared
        engine.onEvent = { [weak self] event in
            guard let self, self.engine.notificationsEnabled else { return }
            switch event {
            case .limitReached(let target):
                Notifier.shared.post(
                    title: "已达到充电上限 \(target)%",
                    body: "充电已停止，适配器持续供电")
            case .topUpCompleted:
                Notifier.shared.post(title: "已充满", body: "恢复正常限充")
            case .dischargeFinished(let floor):
                Notifier.shared.post(
                    title: "放电完成", body: "已放到 \(floor)%，恢复正常充电")
            case .calibrationCompleted:
                Notifier.shared.post(
                    title: "校准完成", body: "充满 → 保持 → 放电循环已完成")
            case .nativeLimitStalled:
                Notifier.shared.post(
                    title: "被 macOS 充电上限卡住",
                    body: "已结束本次充满/校准；系统设置 → 电池 调高上限后可重试")
            }
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(engine: engine) { [weak self] pane in
                self?.showSettings(pane: pane)
            })
        measurer = NSHostingController(rootView: PopoverView(engine: engine))
        measurer.view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)

        // Combine the publishers from a single tick into one layout pass.
        engine.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusBar(self.engine.snapshot)
                self.updatePopoverHeight()
            }
            .store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(handleStatusButtonClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        updateStatusBar(engine.snapshot)

        engine.start()

        DispatchQueue.main.async { [weak self] in
            self?.startUpdaterWithFirstRunPrompt()
        }
    }

    private func startUpdaterWithFirstRunPrompt() {
        if UserDefaults.standard.bool(forKey: "chargekit.autoUpdatePromptShown") {
            updaterController.startUpdater()
            return
        }

 // Hand-rolled NSPanel: a manually shown NSAlert.window leaks odd
 // controls (empty third button, suppression checkbox), and runModal
 // starves the engine tick. A tiny non-modal window is clean and safe.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "自动更新"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(
            rootView: AutoUpdatePromptView { [weak self] enabled, remindLater in
                self?.autoUpdatePromptChoice(enabled: enabled, remindLater: remindLater)
            })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        autoUpdatePromptWindow = window
    }

    private func autoUpdatePromptChoice(enabled: Bool, remindLater: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        if enabled || !remindLater {
            UserDefaults.standard.set(true, forKey: "chargekit.autoUpdatePromptShown")
        }
        autoUpdatePromptWindow?.orderOut(nil)
        autoUpdatePromptWindow = nil
        updaterController.startUpdater()
    }

    @MainActor
    private func showSettings(pane: SettingsPane? = nil) {
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                engine: engine, updater: updaterController.updater)
        }
        if let pane {
            settingsWindowController?.showPane(pane)
        }
        NSApp.activate(ignoringOtherApps: true)
 // Reopen on the screen the status item lives on, like system
 // Settings windows that follow the invoking menu bar item.
        let statusScreen = statusItem.button?.window?.screen
            ?? NSScreen.main
        if let window = settingsWindowController?.window,
           let statusScreen,
           !statusScreen.frame.intersects(window.frame) {
            let visible = statusScreen.visibleFrame
            let size = window.frame.size
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2)
            window.setFrameOrigin(origin)
        }
        settingsWindowController?.showWindow(nil)
        if let window = settingsWindowController?.window {
 // makeKeyAndOrderFront alone does not restore a miniaturized
 // window (AppKit requires an explicit deminiaturize).
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.title = "ChargeKit"

        let appMenu = NSMenu(title: "ChargeKit")
        let aboutItem = NSMenuItem(
            title: "关于 ChargeKit",
            action: #selector(showAbout),
            keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: "u")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 ChargeKit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

 // Standard Edit menu so ⌘C/⌘V/⌘A/⌘Z reach first responders
 // (form fields, search) via responder-chain selectors.
        let editItem = NSMenuItem()
        editItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)

 // Standard Window menu: ⌘W closes and ⌘M miniaturizes the settings
 // window through the responder chain.
        let windowItem = NSMenuItem()
        windowItem.title = "窗口"
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(
            withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: "全部置于前", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        mainMenu.addItem(windowItem)
        mainMenu.setSubmenu(windowMenu, for: windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc @MainActor
    private func showAbout() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        if aboutWindow == nil {
            let contentController = NSHostingController(rootView: AboutView(
                appVersion: version,
                build: build,
                showDiagnostics: { [weak self] in self?.showDiagnosticsWindow() },
                checkForUpdates: { [weak self] in self?.checkForUpdates(nil) }))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "关于 ChargeKit"
            window.isReleasedWhenClosed = false
            window.contentViewController = contentController
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func showDiagnosticsWindow() {
        let view = DiagnosticsView(makeReport: { [engine] in Self.makeDiagnosticsReport(engine: engine) }) { [weak self] in
            self?.diagnosticsWindow?.performClose(nil)
        }
        if diagnosticsWindow == nil {
            let size = NSSize(width: 520, height: 470)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "诊断信息"
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.minSize]
            window.contentViewController = controller
            window.setContentSize(size)
            window.center()
            diagnosticsWindow = window
        } else if let controller = diagnosticsWindow?.contentViewController
            as? NSHostingController<DiagnosticsView> {
            controller.rootView = view
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private static func makeDiagnosticsReport(engine: ChargeEngine) -> DiagnosticsReport {
        let snapshot = engine.snapshot
        let installer = HelperInstaller.shared
        let helperStatus: String
        if installer.installInProgress {
            helperStatus = "正在等待授权或安装"
        } else if !installer.isInstalled {
            helperStatus = "未安装"
        } else if installer.needsInstall {
            helperStatus = "已安装 · 启用特权功能时需更新"
        } else {
            helperStatus = HelperClient.shared.isConnected ? "已安装 · App 已建立连接" : "已安装 · 按需启用"
        }
        let chargingMode: String
        switch engine.chargeControlMode {
        case .systemManaged: chargingMode = "macOS 管理"
        case .independentSwitch: chargingMode = "ChargeKit 管理"
        case .monitoringOnly: chargingMode = "仅监控"
        }
        let source: String
        switch snapshot.systemPowerSource ?? powerSourceSnapshot().internalBatterySource {
        case .external: source = "适配器供电"
        case .battery: source = "电池供电"
        case nil: source = "暂不可用"
        }
        let percent = snapshot.batteryPercent
        func watts(_ value: Double?, signed: Bool = false) -> String {
            guard let value, value.isFinite else { return "暂不可用" }
            return String(format: signed ? "%+.1f W" : "%.1f W", value)
        }
        return DiagnosticsReport(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—",
            helperStatus: helperStatus,
            chargingMode: chargingMode,
            batteryLevel: snapshot.hasBatteryPercent && percent.isFinite
                ? "\(Int(min(max(percent, 0), 100)))%" : "暂不可用",
            powerSource: source,
            chargingState: snapshot.readError == nil
                ? PopoverView.statusText(for: snapshot, engine: engine) : "电池读数暂不可用",
            lowPowerMode: engine.lowPowerModeEnabled ? "已开启" : "已关闭",
            adapterInput: watts(snapshot.liveAdapterPower),
            hostLoad: watts(snapshot.liveHostPower),
            batteryPower: watts(snapshot.liveBatteryPower, signed: true))
    }

    @objc @MainActor
    private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc @MainActor
    private func openSettingsFromMenu() {
        showSettings()
    }

    private var lastMenuBarIcon: MenuBarStatusIcon?
    private var lastMenuBarTitle: String?

    private func updateStatusBar(_ snapshot: ChargeEngine.Snapshot) {
        guard let button = statusItem.button else { return }
        let batteryPercent = snapshot.hasBatteryPercent && snapshot.batteryPercent.isFinite
            ? snapshot.batteryPercent : nil
        let title = batteryPercent.map { "\(Int($0))%" } ?? "—%"
        let lowPowerMode = engine.lowPowerModeEnabled
        let icon = MenuBarStatusIcon(
            phase: snapshot.isDrainingWhileChargeManaged ? .discharging : snapshot.phase,
            batteryPercent: batteryPercent,
            systemIsCharging: snapshot.systemIsCharging,
            readFailed: snapshot.readError != nil,
            lowPowerMode: lowPowerMode)
        if icon != lastMenuBarIcon {
            lastMenuBarIcon = icon
            button.image = icon.makeImage()
        }
        if title != lastMenuBarTitle {
            lastMenuBarTitle = title
            button.title = title
        }
        let status = PopoverView.statusText(for: snapshot, engine: engine)
        let tooltip = lowPowerMode ? "低电量模式已开启 · \(status)" : status
        if button.toolTip != tooltip { button.toolTip = tooltip }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            anchorScreen = button.window?.screen
            updatePopoverHeight(force: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func handleStatusButtonClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu(event)
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu(_ event: NSEvent) {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 ChargeKit",
            action: #selector(showAbout),
            keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 ChargeKit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

 /// Final-height sizing via the hidden measurer: called on every
 /// height-affecting engine change (the objectWillChange sink) and right
 /// before popover.show (`force` bypasses the isShown guard there — the
 /// plain call would no-op before the popover is shown). Live changes
 /// animate through the shared resize interpolator; the force path
 /// applies instantly so the popover opens at the right size.
    private func updatePopoverHeight(force: Bool = false) {
        if force {
            resizeTimer?.invalidate()
            resizeTimer = nil
        } else if resizeTimer?.isValid == true {
            return
        }
 // Skip while closed: the measurer's layout pass costs real CPU per
 // engine tick for nothing.
        guard force || popover.isShown else { return }
        measurer.view.layoutSubtreeIfNeeded()
        let content = measurer.sizeThatFits(
            in: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        if force {
            applyPopoverHeight(content)
        } else {
            let available = (anchorScreen ?? NSScreen.main)?.visibleFrame.height ?? 800
            let cap = max(available - Self.popoverChrome, 100)
            let start = popover.contentSize.height
            let end = min(content.rounded(), cap)
 // Same-end guard: the cap was lost here in a
 // rewrite, and without the guard every routine re-measure armed
 // an idle 60 Hz timer whose in-flight check then dropped real
 // height changes (banners) for up to 2 s.
            guard abs(end - start) > 0.5 else { return }
            animatePopoverResize(tick: { [weak self] progress in
                guard let self else { return }
                let h = (start + (end - start) * progress).rounded()
                if h != self.popover.contentSize.height {
                    self.popover.contentSize = NSSize(width: 320, height: h)
                }
            })
        }
    }

 // MARK: Self-driven popover resize

 /// NSPopover.contentSize sets apply INSTANTLY on this OS — there is no
 /// built-in resize animation, so the window height is interpolated here.
    private var resizeTimer: Timer?
    private static let resizeDuration: TimeInterval = 0.25

    private func animatePopoverResize(tick: @escaping (CGFloat) -> Void) {
        resizeTimer?.invalidate()
        let began = Date()
 // .common so slider drags and menu tracking cannot stall the
 // animation (scheduledTimer's default mode pauses
 // during event tracking).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, self.popover.isShown else {
                timer.invalidate()
                self?.resizeTimer = nil
                return
            }
            let t = min(Date().timeIntervalSince(began) / Self.resizeDuration, 1)
            tick(Self.easeInOut(t))
            if t >= 1 {
                timer.invalidate()
                self.resizeTimer = nil
                // Pick up height changes that arrived during the animation.
                self.updatePopoverHeight()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

 /// CSS ease-in-out (cubic-bezier 0.42, 0, 0.58, 1), evaluated by
 /// bisecting the curve's x(t) for the given time fraction.
    private static func easeInOut(_ x: Double) -> CGFloat {
        func axis(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if axis(0, 0.42, 0.58, 1, mid) < x { lo = mid } else { hi = mid }
        }
        let t = (lo + hi) / 2
        return CGFloat(axis(0, 0, 1, 1, t))
    }

 /// Instant target-height application (pre-show sizing only), capped to
 /// the anchoring screen's visible height with the same sane floor as
 /// the animated paths (the ScrollView scrolls whatever overflows).
 /// Live changes go through animatePopoverResize.
    private func applyPopoverHeight(_ contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        let available = (anchorScreen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let capped = min(contentHeight, max(available - Self.popoverChrome, 100))
        if abs(popover.contentSize.height - capped) > 0.5 {
            popover.contentSize = NSSize(width: 320, height: capped)
        }
    }

 /// Popover border + arrow overhead around the content area, measured as
 /// (window height − contentSize height) on this system.
    private static let popoverChrome: CGFloat = 27
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
