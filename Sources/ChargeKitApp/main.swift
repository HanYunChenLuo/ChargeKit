import AppKit
import Combine
import SwiftUI
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications
import SMCKit
import ChargeKitCore

// ChargeKit — macOS menu-bar charge limiter (adapter mode).
// Reads telemetry unprivileged; privileged writes go through ChargeKitHelper.

/// The macOS native charge limit (System Settings → Battery), read from
/// powerd's policy plist. Third-party writes are impossible — third-party writes are impossible — but
/// the plist is world-readable. Returns nil when unreadable or absent.
func macOSChargeLimit() -> Int? {
    let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    guard let data = try? Data(contentsOf: url),
          let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let policies = outer["policies"] as? Data,
          let inner = try? PropertyListSerialization.propertyList(from: policies, format: nil) as? [String: Any],
          let objects = inner["$objects"] as? [Any]
    else { return nil }
 // NSKeyedArchiver: find the ChargeCtrlPolicy dict carrying soclimit.
    for case let obj as [String: Any] in objects {
        if let limit = obj["soclimit"] as? Int { return limit }
    }
    return nil
}

extension NSImage {
 /// Colored copy of a template symbol image (source-in composite).
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        color.set()
        rect.fill(using: .sourceIn)
        out.unlockFocus()
        return out
    }
}

extension ChargePhase {
    var symbolName: String {
        switch self {
        case .idle: return "battery.100"
        case .charging: return "bolt.fill"
        case .holding: return "battery.75"
        case .heatPaused: return "thermometer.high"
        case .discharging: return "arrow.down.circle.fill"
        }
    }

    var statusColor: NSColor {
        switch self {
        case .idle: return .secondaryLabelColor
        case .charging: return .systemGreen
        case .holding: return .systemOrange
        case .heatPaused: return .systemRed
        case .discharging: return .systemBlue
        }
    }

 /// Colored (non-template) symbol for the menu bar; nil (idle) means
 /// keep the template image so the system renders it adaptively.
    var menuBarImage: NSImage? {
        switch self {
        case .idle: return nil
        default:
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .tinted(statusColor)
        }
    }
}

// MARK: - Helper XPC client

@objc protocol HelperProtocolObjC {
    func version(withReply reply: @escaping (String) -> Void)
    func adapterState(withReply reply: @escaping (Bool, Error?) -> Void)
    func setAdapter(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func chargingState(withReply reply: @escaping (Bool, Error?) -> Void)
    func setCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, withReply reply: @escaping (Error?) -> Void)
    func dischargeState(withReply reply: @escaping (Bool, Int, Error?) -> Void)
    func writeKey(_ key: String, value: Data, withReply reply: @escaping (Error?) -> Void)
    func setLowPowerMode(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
    func setExitRestoresCharging(enabled: Bool, withReply reply: @escaping (Error?) -> Void)
}

final class HelperClient {
    static let shared = HelperClient()
    private var connection: NSXPCConnection?

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: "com.chargekit.helper", options: [])
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocolObjC.self)
 // A daemon restart (version mismatch on a new selector, crash,
 // reinstall) invalidates the connection; drop it so the next call
 // rebuilds — the MachService on-demand launch spins up the fresh
 // daemon. Without this the cached dead connection silences every
 // helper write for the rest of the app's life.
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    var proxy: HelperProtocolObjC? {
        ensureConnection().remoteObjectProxyWithErrorHandler { error in
            NSLog("[ChargeKit] helper error: \(error.localizedDescription)")
        } as? HelperProtocolObjC
    }

    func setAdapter(enabled: Bool, completion: @escaping (Error?) -> Void) {
        proxy?.setAdapter(enabled: enabled, withReply: completion)
    }

    func setCharging(enabled: Bool, completion: @escaping (Error?) -> Void) {
        proxy?.setCharging(enabled: enabled, withReply: completion)
    }

 /// Blocking variant for the sleep-entry path: the system freezes right
 /// after willSleep handlers return, so an async fire-and-forget write
 /// can lose the race (measured: cut landed on one sleep, missed on the
 /// next). Bounded at 2 s so a dead daemon never blocks sleep.
    func setChargingSync(enabled: Bool) {
        let proxy = ensureConnection().remoteObjectProxyWithErrorHandler { error in
            NSLog("[ChargeKit] sleep-stop XPC error: \(error.localizedDescription)")
        } as? HelperProtocolObjC
        let sem = DispatchSemaphore(value: 0)
        proxy?.setCharging(enabled: enabled) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    func setDischarge(enabled: Bool, floorPercent: Int, hardwarePercent: Bool, completion: @escaping (Error?) -> Void) {
        proxy?.setDischarge(enabled: enabled, floorPercent: floorPercent, hardwarePercent: hardwarePercent, withReply: completion)
    }

    func dischargeState(completion: @escaping (Bool, Int, Error?) -> Void) {
        proxy?.dischargeState(withReply: completion)
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
        proxy?.writeKey("ACLC", value: Data([color]), withReply: completion)
    }

 /// macOS Low Power Mode toggle (daemon-side root pmset; no public
 /// setter API exists). Fire-and-forget.
    func setLowPowerMode(_ enabled: Bool, completion: @escaping (Error?) -> Void = { _ in }) {
        proxy?.setLowPowerMode(enabled: enabled, withReply: completion)
    }

 /// Exit-behavior preference ("Stop Charging when App Closed"
 /// parity): when false the daemon's exit path keeps the current
 /// charging state instead of restoring. Fire-and-forget — the daemon
 /// defaults to restore (safe) until told otherwise.
    func setExitRestoresCharging(enabled: Bool, completion: @escaping (Error?) -> Void = { _ in }) {
        proxy?.setExitRestoresCharging(enabled: enabled, withReply: completion)
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
func powerSourceSnapshot() -> (acAttached: Bool, macosPercent: Int?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
          !list.isEmpty else { return (true, nil) }
    var ac = false
    var percent: Int?
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?
            .takeUnretainedValue() as? [String: Any] else { continue }
        if (desc[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue {
            ac = true
        }
        if (desc[kIOPSTypeKey as String] as? String) == internalBatteryType,
           let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int {
            percent = capacity
        }
    }
    return (ac, percent)
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
 /// Apple-reported battery health percent ("MaxCapacity").
    var healthPercent: Int? = nil
    var cycleCount: Int? = nil
    var serial: String? = nil
 /// Negotiated PD contract from AdapterDetails — the adapter's
 /// capability tier, not instantaneous draw (that is dcInPower/PDTR).
    var adapterVolts: Double? = nil
    var adapterWatts: Int? = nil
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
            statics.designCapacitymAh = dict["DesignCapacity"] as? Int
            statics.healthPercent = dict["MaxCapacity"] as? Int
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
        info.healthPercent = statics.healthPercent
        info.cycleCount = statics.cycleCount
        info.serial = statics.serial
        return info
    }

    private func applyAdapter(_ adapter: [String: Any], to info: inout BatteryInfo) {
        if let millivolts = adapter["AdapterVoltage"] as? Int {
            info.adapterVolts = Double(millivolts) / 1000
        }
        info.adapterWatts = adapter["Watts"] as? Int
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
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
    struct Snapshot {
        var batteryPercent: Double = 0
 /// Raw BMS percent (BUIC), independent of the selected basis: the
 /// stall detector watches the physical value and the battery-info
 /// dual-percent row shows it. nil on read error.
        var hardwareBatteryPercent: Double?
        var dcInPower: Double = 0
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
        var chargingEnabled: Bool = true
        var phase: ChargePhase = .idle
        var readError: String?
    }

    @Published var snapshot = Snapshot()
 /// Battery health + adapter details (public IORegistry/IOPS sources),
 /// refreshed every tick; independent of the SMC reads, so the info
 /// views keep their data across snapshot read errors.
    @Published var batteryInfo = BatteryInfo()
 /// Caching reader behind batteryInfo — full AppleSmartBattery dump only
 /// at launch / every ~5 min / on AC-edge changes.
    private let batteryInfoReader = BatteryInfoReader()
 /// Previous tick's AC state — drives the reader's AC-edge full dump.
    private var lastACAttached: Bool?
    @Published var limitingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(limitingEnabled, forKey: "limitingEnabled")
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
 /// Popover「电池信息」折叠区状态。住在 engine 而非视图 @State：隐藏
 /// measurer 持有另一个 PopoverView 实例，@State 会让两者高度永久分裂
 /// （展开后 measurer 仍量收起态，2s tick 把高度压回）；共享 + 发布即
 /// 触发重测，展开/收起一个 runloop 内生效。持久化记住用户偏好。
    @Published var batteryInfoExpanded: Bool {
        didSet { UserDefaults.standard.set(batteryInfoExpanded, forKey: "batteryInfoExpanded") }
    }
 /// Natural height of the battery-info panel, measured by the view itself
 /// (it lays out at natural height even while collapsed) so the collapse
 /// frame can animate a numeric 0 ↔ natural height. View-derived, not
 /// persisted.
    @Published var batteryInfoHeight: CGFloat = 0
 /// Live panel height while the AppDelegate resize timer drives the
 /// disclosure — SINGLE-CLOCK animation: the SwiftUI animation modifier
 /// is gone; the timer publishes this per tick and the window follows
 /// the same tick, so border, content and footer cannot phase-wobble.
 /// nil at rest; the view derives the static height then.
    @Published var displayPanelHeight: CGFloat? = nil
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
            HelperClient.shared.setExitRestoresCharging(enabled: exitRestoresCharging)
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
 /// macOS Low Power Mode mirror. `ProcessInfo.isLowPowerModeEnabled`
 /// (public read-only API) is re-read every tick, so changes from
 /// System Settings, the battery menu and scheduled LPM actions all
 /// show within 2 s; writes go through the daemon's pmset path.
    @Published var lowPowerModeEnabled = false
 /// Local toggle writes suppress the tick mirror briefly — otherwise a
 /// tick landing between the optimistic set and pmset taking effect
 /// would bounce the switch back.
    private var lastLocalLPMWriteAt: Date?

    func setLowPowerMode(_ on: Bool) {
 // Optimistic; the tick mirror corrects within 2 s when the XPC
 // call fails or pmset rejects the change.
        lowPowerModeEnabled = on
        lastLocalLPMWriteAt = Date()
        HelperClient.shared.setLowPowerMode(on) { [weak self] error in
            DispatchQueue.main.async {
                if let error { self?.helperError = "省电模式：\(error.localizedDescription)" }
            }
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
        } catch {
            helperError = "登录项：\(error.localizedDescription)"
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
            if !magsafeLedEnabled, lastMagSafeColor != nil {
 // Hand control back to macOS once; the daemon also restores
 // 0x00 on exit, so a crash never pins a stale color.
                lastMagSafeColor = nil
                HelperClient.shared.setMagSafeColor(MagSafeColor.system)
            }
        }
    }
    @Published var helperError: String?
 /// macOS native charge limit (System Settings → Battery), polled each
 /// tick. Our configured limit can never exceed it; the UI slider is
 /// clamped to this ceiling. nil = unreadable (treated as 100).
    @Published var systemChargeLimit: Int = 100

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
    private var smc: AppleSMCClient?
    private var timer: Timer?
 /// Last MagSafe color we asserted (nil = unknown / not yet written).
 /// Read-compare against ACLC each tick: the system resets ACLC on adapter
 /// replug, so we re-assert only when the key actually differs.
    private var lastMagSafeColor: UInt8?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
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
        self.batteryInfoExpanded = d.object(forKey: "batteryInfoExpanded") as? Bool ?? false
        self.hardwareBatteryPercent = d.object(forKey: "hardwareBatteryPercent") as? Bool ?? false
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
        if calibrationActive {
            let phase = d.string(forKey: "calibrationPhase")
                .flatMap(CalibrationSession.Phase.init(rawValue:))
            calibration = CalibrationSession(
                resuming: phase ?? .chargingToFull,
                fullSince: d.object(forKey: "calibrationFullSince") as? Date,
                legConfirmedActive: d.bool(forKey: "calibrationLegConfirmed"))
        }
        self.smc = try? AppleSMCClient()
        persistScheduleBookkeeping()
        self.workdayCalendarStatus = workdayStatusMessage()
    }

    func start() {
        stop()
 // XPC protocol gate (review round 2, P2-2): an older daemon does not
 // know the setDischarge hardwarePercent selector — discharge would
 // fail silently and auto-discharge would retry every tick. Surface
 // an actionable message instead; the limiter itself is unaffected.
        HelperClient.shared.version { [weak self] version in
            DispatchQueue.main.async {
                guard let self, let version, version < "0.5.3" else { return }
                self.helperError = "Helper 版本 \(version) 过旧（需要 0.5.3+）：请运行 sudo ./scripts/install-helper.sh 重装后再使用放电功能"
            }
        }
 // Push the exit-behavior preference so the daemon knows it before
 // any exit path fires (defaults to restore on the daemon side).
        HelperClient.shared.setExitRestoresCharging(enabled: exitRestoresCharging)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
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
            guard let self, self.sleepStopCharging else { return }
            self.sleepPauseLatch = true
            NSLog("[ChargeKit] will-sleep: cutting charging (sleep-stop)")
            HelperClient.shared.setChargingSync(enabled: false)
            self.recordHistory(.sessionCancelled, "睡眠 · 已切断充电")
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.sleepPauseLatch {
                NSLog("[ChargeKit] did-wake: releasing sleep-stop latch")
                self.recordHistory(.sessionStarted, "唤醒 · 恢复充电")
            }
            self.sleepPauseLatch = false
        }
        refreshWorkdayCalendarData()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for o in [sleepObserver, wakeObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        sleepObserver = nil
        wakeObserver = nil
    }

 // MARK: session control (UI actions)

    func startTopUp() {
        guard limitingEnabled, !nativeLimitStallActive else { return }
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

    func startDischarge() {
        guard limitingEnabled else { return }
        if topUpActive { topUpActive = false }
        let floor = targetPercent
        recordHistory(.sessionStarted, "放电至 \(floor)%")
 // Optimistic latch so the very next tick does not fight the daemon
 // by restoring the adapter it just cut. Bumping the mirror epoch
 // drops the in-flight poll reply that predates this start (it
 // would otherwise report "inactive" and wipe the latch).
        dischargeMirrorEpoch += 1
        dischargeActive = true
        dischargeFloor = floor
        suppressDischargeEvent = false
        dischargeMirrorConfirmed = false
        HelperClient.shared.setDischarge(enabled: true, floorPercent: floor, hardwarePercent: hardwareBatteryPercent) { [weak self] error in
            DispatchQueue.main.async {
                self?.helperError = error.map { "\($0.localizedDescription)" }
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
        guard limitingEnabled, !calibrationActive, !nativeLimitStallActive else { return }
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
    }

 // MARK: schedule control (S7)

    func makeScheduleRuleDraft() -> ScheduleRule {
        let c = Calendar.current
        let now = Date()
        return ScheduleRule(
            hour: c.component(.hour, from: now),
            minute: c.component(.minute, from: now),
            repeatMode: .daily, action: .setLimit(80))
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

    private func applyScheduled(_ action: ScheduleAction, batteryPercent pct: Double) {
 // Record the scheduled action before executing it.
        recordHistory(.scheduledAction, action.historyDetail)
        switch action {
        case .setLimit(let v):
            targetPercent = min(max(v, 50), max(systemChargeLimit, 50))
        case .dischargeTo(let v):
            limitingEnabled = true
            targetPercent = min(max(v, 50), max(systemChargeLimit, 50))
            startDischarge()
        case .pauseCharging:
 // Limit = current battery: charging and discharging stop
 // (pause-charging semantics). Below the slider floor on purpose —
 // clamping up would resume charging.
            limitingEnabled = true
            targetPercent = min(max(Int(pct), 10), 100)
        case .topUp:
            limitingEnabled = true
            startTopUp()
        case .startCalibration:
            limitingEnabled = true
            startCalibration()
        case .setLowPowerMode(let on):
            HelperClient.shared.setLowPowerMode(on) { [weak self] error in
                DispatchQueue.main.async {
                    self?.helperError = error.map { "\($0.localizedDescription)" }
                }
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

    private func tick() {
        guard let smc else {
            DispatchQueue.main.async {
                self.snapshot.readError = "SMC unavailable"
            }
            return
        }
        let controller = ChargeController(client: smc)

 // One IOPowerSources snapshot per tick (two separate
 // copies was pure main-thread waste): AC state, the macOS gauge
 // percent for the battery-info view and the basis selection, and
 // the AC-edge signal for the caching reader.
        let powerSources = powerSourceSnapshot()
        let macosPercent = powerSources.macosPercent
        let acChanged = (lastACAttached ?? powerSources.acAttached) != powerSources.acAttached
        lastACAttached = powerSources.acAttached

 // Battery health + adapter details, read before the SMC block so
 // every tick exit path (including SMC failures) keeps the info
 // views fed. Gated publish: unchanged values cost nothing (P1-3 —
 // every publish runs a hidden-measurer layout while the popover
 // is shown).
        let batteryInfo = batteryInfoReader.read(macosPercent: macosPercent, acChanged: acChanged)
        DispatchQueue.main.async {
            guard self.batteryInfo != batteryInfo else { return }
            self.batteryInfo = batteryInfo
        }

        let pct: Double
        let hardwarePct: Double   // raw BUIC: stall detector + dual-percent row
        let power: Double
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
            power = try controller.dcInPower()
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
            DispatchQueue.main.async { self.snapshot.readError = "\(error)" }
            return
        }

 // Power flow: battery power from the gauge keys (V × I); host draw
 // follows from the energy balance (adapter input charges the battery
 // or runs the machine). Clamped ≥ 0: the two ADCs can disagree by a
 // few percent near zero net flow.
        let batteryVolts: Double?
        let batteryAmps: Double?
        let batteryPower: Double?
        if let v = try? controller.batteryVoltage(), let i = try? controller.batteryCurrent() {
            batteryVolts = v
            batteryAmps = i
            batteryPower = v * i
        } else {
            batteryVolts = nil
            batteryAmps = nil
            batteryPower = nil
        }
        let hostPower = batteryPower.map { max(power - $0, 0) }

 // Poll the macOS native limit: it caps everything we can do. The
 // plist changes when the user edits System Settings. Our configured
 // limit is clamped down to it — a setting above the system limit
 // would silently never take effect.
        let sysLimit = macOSChargeLimit() ?? 100
        DispatchQueue.main.async {
            self.systemChargeLimit = sysLimit
            if self.targetPercent > sysLimit { self.targetPercent = sysLimit }
        }

 // Wall-power presence (used by the session rules and the phase
 // override below). NB: during a daemon discharge session IOPowerSources
 // also reports battery — the session branch below takes precedence.
        let acAttached = powerSources.acAttached

 // Low Power Mode mirror (public read-only API; the daemon owns
 // writes). Skipped briefly after a local toggle so the optimistic
 // value survives until pmset lands.
        if Date().timeIntervalSince(lastLocalLPMWriteAt ?? .distantPast) > 3 {
            lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }

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
                self.snapshot = Snapshot(
                    batteryPercent: pct, hardwareBatteryPercent: hardwarePct,
                    dcInPower: power, batteryTemp: temp,
                    batteryPower: batteryPower, hostPower: hostPower,
                    batteryVolts: batteryVolts, batteryAmps: batteryAmps,
                    chargingEnabled: chargingOn, phase: phase, readError: nil)
            }
            return
        }

 // Scheduled tasks: explicit planned actions, so they fire even
 // during a discharge (they may replace it) — but never while the
 // sleep latch holds (lid closed / DarkWake maintenance wake).
 // Same-day catch-up happens naturally: dueRules sees any
 // occurrence whose time already passed today.
        refreshWorkdayCalendarIfNeeded()
        let scheduleYear = WorkdayCalendar.gregorianYear(for: Date(), calendar: .current)
        let waitingForWorkdayCalendar = workdayCalendarRegion == .mainlandChina
            && workdayCalendarClient.isLoading(year: scheduleYear)
            && !workdayCalendarClient.hasCalendar(year: scheduleYear)
        let rulesToEvaluate: [ScheduleRule]
        if waitingForWorkdayCalendar {
 // Wait for the first complete regional calendar before deciding
 // whether a weekday rule is due. Other repeat modes are unaffected.
            rulesToEvaluate = scheduleRules.filter {
                if case .weekdays = $0.repeatMode { return false }
                return true
            }
        } else {
            rulesToEvaluate = scheduleRules
        }
        let due = schedule.dueRules(
            rulesToEvaluate,
            now: Date(),
            calendar: .current,
            workdayCalendar: scheduleWorkdayCalendar)
        if !due.isEmpty {
            for fired in due {
                NSLog("[ChargeKit] schedule fired: \(fired.action) at "
                    + String(format: "%02d:%02d", fired.hour, fired.minute)
                    + " (\(String(describing: fired.repeatMode)))")
                applyScheduled(fired.action, batteryPercent: pct)
                if !fired.enabled, let i = scheduleRules.firstIndex(where: { $0.id == fired.id }) {
 // One-shot (never-repeat) rule spent: disable in place.
                    scheduleRules[i].enabled = false
                }
            }
            persistScheduleBookkeeping()
        }

 // Track the daemon-owned discharge session (async; next tick uses it).
 // A true→false mirror transition is a completed drain — but only
 // when the daemon actually confirmed the session (an optimistic
 // start that never came up must not read as completion) and this
 // side did not cancel it; the calibration discharge leg reports
 // through its own completed event. Replies predating the latest
 // start/cancel (epoch mismatch) are dropped — they would describe
 // a world that no longer exists.
        let mirrorEpoch = dischargeMirrorEpoch
        HelperClient.shared.dischargeState { active, floor, error in
            DispatchQueue.main.async {
                guard self.dischargeMirrorEpoch == mirrorEpoch else { return }
                if let error {
                    self.helperError = "\(error.localizedDescription)"
                    return
                }
                let wasActive = self.dischargeActive
                let endedFloor = self.dischargeFloor
                self.dischargeActive = active
                self.dischargeFloor = active ? floor : nil
                if active {
                    self.dischargeMirrorConfirmed = true
                    return
                }
                if wasActive {
                    if self.dischargeMirrorConfirmed,
                       !self.suppressDischargeEvent,
                       !self.calibrationActive,
                       let endedFloor
                    {
                        self.onEvent?(.dischargeFinished(floor: endedFloor))
                        self.recordHistory(.sessionCompleted, "放电完成 · 到达 \(endedFloor)%")
                    }
                    self.suppressDischargeEvent = false
                    self.dischargeMirrorConfirmed = false
                }
            }
        }

 // Drive the calibration cycle (charge/dwell legs evaluate here; the
 // discharge leg is daemon-owned and falls into the branch below).
        if calibrationActive {
            if !limitingEnabled { endCalibration() }
            if calibrationActive {
                let event = calibration.tick(
                    batteryPercent: pct, acAttached: acAttached,
                    dischargeActive: dischargeActive, now: Date(),
                    config: calibrationConfig)
                switch event {
                case .beginDischarge:
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
                self.snapshot = Snapshot(
                    batteryPercent: pct, hardwareBatteryPercent: hardwarePct,
                    dcInPower: power, batteryTemp: temp,
                    batteryPower: batteryPower, hostPower: hostPower,
                    batteryVolts: batteryVolts, batteryAmps: batteryAmps,
                    chargingEnabled: chargingOn, phase: .discharging, readError: nil)
            }
            return
        }

 // Charging-switch mode never cuts the adapter; if it is off (stale
 // adapter-mode state, an external cut, or a just-finished discharge),
 // restore wall power.
        if controller.chargingKey != nil, !adapterOn {
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
        if SessionRules.autoDischargeShouldStart(
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
            chargingEnabled: chargingOn, phase: decision.phase, readError: nil)

 // Without wall power the limiter is not actively doing anything and
 // the battery carries the machine — phase labels like "已停在 X%（适配器
 // 供电）" would be wrong. statusText separates this from a discharge
 // session via dischargeActive.
        if !acAttached {
            newSnapshot.phase = .discharging
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

 // Adapter plug / unplug edges (physical events that change behavior).
        if acAttached, prevACAttached == false {
            recordHistory(.sessionStarted, "适配器已接入")
        }
        if !acAttached, prevACAttached == true {
            recordHistory(.sessionCancelled, "适配器已拔出")
        }
        prevACAttached = acAttached

        prevPhase = newSnapshot.phase

        if decision.chargingOn != chargingOn {
            let wanted = decision.chargingOn
            HelperClient.shared.setCharging(enabled: wanted) { [weak self] error in
                DispatchQueue.main.async {
                    self?.helperError = error.map { "\($0.localizedDescription)" }
                }
            }
            newSnapshot.chargingEnabled = wanted
        }
        DispatchQueue.main.async { self.snapshot = newSnapshot }

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

 // MagSafe LED sync (industry-standard): green at the limit, orange
 // while charging toward it, off when the adapter is cut. Read-compare
 // against ACLC each tick and re-assert only on mismatch — the system
 // resets the key on adapter replug.
        if magsafeLedEnabled {
            let expected: UInt8 = !adapterOn ? MagSafeColor.off
                : (newSnapshot.chargingEnabled ? MagSafeColor.orange : MagSafeColor.green)
            if let current = try? smc.read(SMCKey("ACLC")), current.first != expected {
                lastMagSafeColor = expected
                HelperClient.shared.setMagSafeColor(expected)
            }
        }
    }
}

// MARK: - UI

/// Small gray section label - the first-party popover grouping idiom
/// (Wi-Fi/Bluetooth popovers) instead of bare dividers between blocks.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// System Settings slider idiom: label left, live value right, slider on
/// its own full-width line (values align across rows).
struct SliderRow: View {
    let label: String
    let value: Int
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    let onEdit: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)\(unit)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            Slider(value: Binding(
                get: { Double(value) },
                set: { onEdit(Int($0)) }),
                   in: range, step: step)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text("\(value)\(unit)"))
        }
    }
}

struct PopoverView: View {
    @ObservedObject var engine: ChargeEngine
    var onOpenSettings: @MainActor () -> Void = {}
 /// Called right after the disclosure toggles so the AppDelegate can
 /// start the window interpolation in the same runloop turn as the
 /// state change (single clock — the chevron's tiny rotation is the
 /// only SwiftUI animation left in the popover).
    var onBatteryInfoToggled: (@MainActor () -> Void)? = nil

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
        if let bp = snapshot.batteryPower, bp < -0.5, snapshot.phase != .discharging {
            switch snapshot.phase {
            case .holding, .charging:
                return "电池放电中 · macOS 系统限制生效"
            default:
                break
            }
        }
        switch snapshot.phase {
        case .idle:
            return "未限制充电"
        case .charging:
            return engine.topUpActive ? "充满中 → 100%" : "充电中 → \(engine.targetPercent)%"
        case .holding:
 // Current percent lives in the merged header gauge once; the
 // menu-bar title carries it too. Only the semantics stay here.
            return "已停在上限 · 适配器供电"
        case .heatPaused:
            let t = snapshot.batteryTemp.map { String(format: "%.1f", $0) } ?? "—"
            return "充电已暂停 · 电池过热 \(t)°C"
        case .discharging:
            if engine.dischargeActive {
                return "放电中 → \(engine.dischargeFloor ?? engine.targetPercent)% · 适配器已断开"
            }
            return "电池放电中 · 未接电源"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
 // Merged header: one element carries battery + state (gauge
 // capsule tinted by phase) + status text (no duplicated
 // percent) + temperature when heat protection is armed.
            HStack(spacing: 8) {
                BatteryGaugeView(
                    percent: engine.snapshot.readError == nil
                        ? engine.snapshot.batteryPercent : nil,
                    phase: engine.snapshot.phase,
                    lowPowerMode: engine.lowPowerModeEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if engine.heatProtectionEnabled {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium")
                            Text(engine.snapshot.batteryTemp.map { String(format: "%.0f°C", $0) } ?? "—")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            PowerFlowView(
                dcInPower: engine.snapshot.readError == nil ? engine.snapshot.dcInPower : 0,
                batteryPower: engine.snapshot.readError == nil ? engine.snapshot.batteryPower : nil,
                hostPower: engine.snapshot.readError == nil ? engine.snapshot.hostPower : nil)
                .frame(height: 108)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "充电")
                Toggle("限制充电", isOn: $engine.limitingEnabled)
                if engine.limitingEnabled {
                    SliderRow(label: "上限", value: engine.targetPercent, unit: "%",
                              range: 50...Double(max(engine.systemChargeLimit, 50)), step: 5) {
                        engine.targetPercent = $0
                    }
                    if engine.targetPercent >= engine.systemChargeLimit, engine.systemChargeLimit < 100 {
                        Text("已到 macOS 系统上限 \(engine.systemChargeLimit)% · 系统设置 → 电池可调高")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    SliderRow(label: "缓冲", value: engine.sailBufferPercent, unit: "%",
                              range: 2...15, step: 1) {
                        engine.sailBufferPercent = $0
                    }
                    Text("达到 \(engine.targetPercent)% 停止充电 · 跌至 \(engine.targetPercent - engine.sailBufferPercent)% 恢复")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if engine.calibrationActive {
                    HStack {
                        Label("校准运行中", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundColor(.purple)
                        Spacer()
                        Button("取消") { engine.cancelCalibration() }
                            .buttonStyle(.borderless)
                    }
                } else if engine.dischargeActive {
                    HStack {
                        Label("放电至 \(engine.dischargeFloor ?? engine.targetPercent)%", systemImage: "arrow.down.circle")
                            .foregroundColor(.blue)
                        Spacer()
                        Button("取消") { engine.cancelDischarge() }
                            .buttonStyle(.borderless)
                    }
                } else if engine.topUpActive {
                    HStack {
                        Label("充满中 → 100%", systemImage: "bolt.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Button("取消") { engine.cancelTopUp() }
                            .buttonStyle(.borderless)
                    }
                } else if engine.limitingEnabled {
                    HStack(spacing: 8) {
                        Button("充满一次") { engine.startTopUp() }
                            .disabled(engine.fullChargeLegBlocked)
                            .frame(maxWidth: .infinity)
                        Button("放电至 \(engine.targetPercent)%") { engine.startDischarge() }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

 // Disclosure built by hand (Button + chevron, no DisclosureGroup:
 // its internal animation can't be coordinated with). The panel
 // height is driven per tick by the AppDelegate resize timer
 // (single clock for window + content — engine.displayPanelHeight);
 // the background GeometryReader keeps the natural height measured
 // for the static state.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    engine.batteryInfoExpanded.toggle()
                    onBatteryInfoToggled?()
                } label: {
                    HStack(spacing: 4) {
                        Label("电池信息", systemImage: "info.circle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(engine.batteryInfoExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15),
                                       value: engine.batteryInfoExpanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

 // Height-driven disclosure: the content stays in the layout
 // (fixedSize keeps it at natural height, so the background
 // GeometryReader measures it even while collapsed) and the
 // frame height follows engine.displayPanelHeight while the
 // resize timer runs, the static state otherwise. The footer
 // tracks the frame's bottom edge — no conditional insertion,
 // so nothing ever travels THROUGH the content's area.
                BatteryInfoView(
                    info: engine.batteryInfo,
                    telemetry: engine.snapshot.readError == nil ? engine.snapshot : nil)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: BatteryInfoHeightKey.self,
                                value: geo.size.height)
                        })
                    .frame(height: engine.displayPanelHeight
                           ?? (engine.batteryInfoExpanded
                               ? (engine.batteryInfoHeight > 0 ? engine.batteryInfoHeight : nil)
                               : 0),
                           alignment: .top)
                    .clipped()
                    .opacity(engine.batteryInfoExpanded ? 1 : 0)
                    .accessibilityHidden(!engine.batteryInfoExpanded)
            }

            Divider()
            HStack {
                Spacer()
                Button(action: onOpenSettings) {
                    Label("设置…", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 320)
        .toggleStyle(.switch)
 // No SwiftUI animation on the disclosure: the AppDelegate resize
 // timer drives the panel height per tick (engine.displayPanelHeight)
 // and the window follows the same tick — a single clock, so border,
 // content and footer cannot drift or wobble against each other.
        .onPreferenceChange(BatteryInfoHeightKey.self) { engine.batteryInfoHeight = $0 }
    }
}

/// Popover root: a ScrollView that greedily fills whatever contentSize
/// AppDelegate assigns to the popover (measured final content height, capped
/// to the anchoring screen's visible frame — never covers the menu bar,
/// never runs off the bottom; overflow scrolls).
struct PopoverRootView: View {
    @ObservedObject var engine: ChargeEngine
    var onOpenSettings: @MainActor () -> Void = {}
    var onBatteryInfoToggled: (@MainActor () -> Void)? = nil

    var body: some View {
 // No scroll indicators: overflow is rare (screen cap) and any brief
 // mid-animation size mismatch would flash one.
        ScrollView(.vertical, showsIndicators: false) {
            PopoverView(engine: engine, onOpenSettings: onOpenSettings,
                        onBatteryInfoToggled: onBatteryInfoToggled)
        }
        .frame(width: 320)
    }
}

/// Natural height of the battery-info panel (measured via the background
/// GeometryReader inside the disclosure; always available because the
/// content lays out at natural height even while collapsed).
private struct BatteryInfoHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = ChargeEngine()
    private var popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?
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

        let openSettings: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.showSettings()
        }
        popover.behavior = .transient
 // Disclosure toggle → single-clock resize: one 60 Hz timer drives
 // BOTH the window contentSize and the panel height published to
 // SwiftUI (its animation modifier is gone), starting synchronously
 // in the button action. One clock = border, content and footer
 // cannot phase-wobble against each other.
        let animateDisclosure: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let natural = self.engine.batteryInfoHeight
 // Start from the CURRENT panel height: a retoggle mid-animation
 // reverses smoothly instead of jumping to an endpoint.
            let startPanel = self.engine.displayPanelHeight
                ?? (self.engine.batteryInfoExpanded ? 0 : natural)
            let endPanel: CGFloat = self.engine.batteryInfoExpanded ? natural : 0
            let baseTotal = self.popover.contentSize.height - startPanel
            let available = (self.anchorScreen ?? NSScreen.main)?.visibleFrame.height ?? 800
            let cap = max(available - Self.popoverChrome, 100)
            self.animatePopoverResize(
                tick: { [weak self] progress in
                    guard let self else { return }
 // Whole points only: fractional window geometry makes
 // the popover origin (arrow attachment) wobble per tick.
                    let panel = (startPanel + (endPanel - startPanel) * progress).rounded()
                    self.engine.displayPanelHeight = panel
                    let total = min(baseTotal + panel, cap).rounded()
                    if total != self.popover.contentSize.height {
                        self.popover.contentSize = NSSize(width: 320, height: total)
                    }
                },
                onEnd: { [weak self] in
                    self?.engine.displayPanelHeight = nil
                })
        }
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                engine: engine,
                onOpenSettings: openSettings,
                onBatteryInfoToggled: animateDisclosure))
 // Hidden off-window measurer: gives the popover's FINAL content
 // height — its layout runs at the animation target, so the answer
 // is available the moment the disclosure state flips.
        measurer = NSHostingController(
            rootView: PopoverView(engine: engine, onOpenSettings: openSettings))
        measurer.view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)

 // Any other height-affecting engine change (session banners, text
 // reflow): measure the final height and animate the window to it,
 // capped to the anchoring screen. The same-end guard below keeps a
 // routine re-measure (several publishes per tick carry the same
 // height) from arming an idle 60 Hz timer — and, worse, from
 // having the in-flight guard drop a REAL height change that lands
 // within the same 250 ms window.
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePopoverHeight() }
            }
            .store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

 // Menu bar: state symbol + live battery percent.
        engine.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusBar(snapshot)
            }
            .store(in: &cancellables)

        engine.start()
    }

    @MainActor
    private func showSettings() {
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(engine: engine)
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
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc @MainActor
    private func openSettingsFromMenu() {
        showSettings()
    }

    private var lastMenuBarPhase: ChargePhase?

    private func updateStatusBar(_ snapshot: ChargeEngine.Snapshot) {
        guard let button = statusItem.button else { return }
        let title = snapshot.readError == nil
            ? "\(Int(snapshot.batteryPercent))%"
            : "—%"
        let phase = snapshot.phase

 // Rebuild the tinted symbol only when the phase actually changes;
 // off-screen rasterizing on every 2 s tick is wasted work.
        if phase != lastMenuBarPhase {
            lastMenuBarPhase = phase
            if let colored = phase.menuBarImage {
                button.image = colored
            } else if let template = NSImage(systemSymbolName: phase.symbolName,
                                             accessibilityDescription: nil) {
                template.isTemplate = true
                button.image = template
            }
        }
        let attrs: [NSAttributedString.Key: Any] =
            phase.menuBarImage == nil
            ? [.font: NSFont.menuBarFont(ofSize: 0)]
            : [.font: NSFont.menuBarFont(ofSize: 0),
               .foregroundColor: phase.statusColor]
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        button.toolTip = PopoverView.statusText(for: snapshot, engine: engine)
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

 /// Final-height sizing via the hidden measurer: called on every
 /// height-affecting engine change (the objectWillChange sink) and right
 /// before popover.show (`force` bypasses the isShown guard there — the
 /// plain call would no-op before the popover is shown). Live changes
 /// animate through the shared resize interpolator; the force path
 /// applies instantly so the popover opens at the right size.
    private func updatePopoverHeight(force: Bool = false) {
 // While a resize animation runs, its per-tick engine publishes
 // would retarget this path every tick — the animation owns the
 // window until it finishes.
        if resizeTimer?.isValid == true { return }
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
 /// built-in resize animation (measured) — so the
 /// window is interpolated here. The SAME tick also drives the SwiftUI
 /// panel height for the disclosure (engine.displayPanelHeight; no
 /// SwiftUI animation modifier): one clock for border, content and
 /// footer, so the two update streams cannot phase-wobble.
    private var resizeTimer: Timer?
    private var resizeBegan = Date.distantPast
    private var resizeTick: ((CGFloat) -> Void)?
    private var resizeOnEnd: (() -> Void)?
    private static let resizeDuration: TimeInterval = 0.25

 /// `tick` receives the eased progress (0…1) and applies it; `onEnd`
 /// runs once the animation completes (or is replaced by a new one,
 /// which drops the old end handler with it).
    private func animatePopoverResize(tick: @escaping (CGFloat) -> Void,
                                      onEnd: @escaping () -> Void = {}) {
        resizeTimer?.invalidate()
        resizeBegan = Date()
        resizeTick = tick
        resizeOnEnd = onEnd
 // .common so slider drags and menu tracking cannot stall the
 // animation (scheduledTimer's default mode pauses
 // during event tracking).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = min(Date().timeIntervalSince(self.resizeBegan) / Self.resizeDuration, 1)
            self.resizeTick?(Self.easeInOut(t))
            if t >= 1 {
                self.resizeTimer?.invalidate()
                self.resizeTimer = nil
                let end = self.resizeOnEnd
                self.resizeTick = nil
                self.resizeOnEnd = nil
                end?()
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
