import AppKit
import SwiftUI
import ChargeKitCore
import Sparkle

private enum SettingsPane: String, CaseIterable {
    case charging
    case schedule
    case history
    case general

    var title: String {
        switch self {
        case .charging: return "充电"
        case .schedule: return "定时"
        case .history: return "历史"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "battery.100percent"
        case .schedule: return "calendar"
        case .history: return "clock.arrow.circlepath"
        case .general: return "gearshape"
        }
    }
}

/// Native settings window with a stable toolbar for the app's related panes.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let engine: ChargeEngine
    private let updater: SPUUpdater
    private let contentController: NSHostingController<SettingsPaneView>
    private var selectedPane: SettingsPane

    private static let toolbarIdentifier = NSToolbar.Identifier("com.chargekit.settings")
    private static let selectedPaneKey = "chargekit.settingsPane"

    init(engine: ChargeEngine, updater: SPUUpdater) {
        self.engine = engine
        self.updater = updater
        let savedPane = UserDefaults.standard.string(forKey: Self.selectedPaneKey)
            .flatMap(SettingsPane.init(rawValue:))
        selectedPane = savedPane ?? .charging

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
 // macOS System Settings behavior: fixed width, vertical-only resize,
 // and a dimmed zoom button — full screen would force a mode switch
 // (the resolution "jump" observed on this machine), so it is off.
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.contentMaxSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.title = "\(selectedPane.title)设置"
        let contentController = NSHostingController(
            rootView: SettingsPaneView(engine: engine, updater: updater, pane: selectedPane))
        self.contentController = contentController
        window.contentViewController = contentController

        super.init(window: window)

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        window.center()
    }

    required init?(coder: NSCoder) {
        return nil
    }

 // MARK: - toolbar items

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.segmentIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.segmentIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.segmentIdentifier else { return nil }

 // A segmented control in the .preference toolbar gives the standard
 // macOS Settings experience: icon + label per segment, native hover
 // highlight, selected state and click-to-switch — no custom drawing.
        let segmented = NSSegmentedControl()
        segmented.segmentCount = SettingsPane.allCases.count
        segmented.segmentStyle = .capsule
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(selectSegment(_:))
        for (index, pane) in SettingsPane.allCases.enumerated() {
            segmented.setLabel(pane.title, forSegment: index)
            if let symbol = NSImage(
                systemSymbolName: pane.symbol,
                accessibilityDescription: pane.title) {
                segmented.setImage(symbol, forSegment: index)
            }
            segmented.setToolTip(pane.title, forSegment: index)
        }
        if let index = SettingsPane.allCases.firstIndex(of: selectedPane) {
            segmented.setSelected(true, forSegment: index)
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = segmented
        paneControl = segmented
        return item
    }

    private static let segmentIdentifier =
        NSToolbarItem.Identifier("com.chargekit.settings.tabs")

    private weak var paneControl: NSSegmentedControl?

    @objc private func selectSegment(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard SettingsPane.allCases.indices.contains(index) else { return }
        showPane(SettingsPane.allCases[index])
    }

    private func showPane(_ pane: SettingsPane) {
        selectedPane = pane
        UserDefaults.standard.set(pane.rawValue, forKey: Self.selectedPaneKey)
        if let index = SettingsPane.allCases.firstIndex(of: pane) {
            paneControl?.setSelected(true, forSegment: index)
        }
        guard let window else { return }
        let frame = window.frame
        contentController.rootView = SettingsPaneView(engine: engine, updater: updater, pane: pane)
        window.title = "\(pane.title)设置"
 // Reuse the installed controller and preserve the complete frame.
 // Replacing contentViewController reattaches the host view and can
 // make AppKit recompute its screen-relative origin on toolbar clicks.
        window.setFrame(frame, display: true)
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var engine: ChargeEngine
    let updater: SPUUpdater
    let pane: SettingsPane

 /// Semantic color for the live heat reading: green in the safe band,
 /// orange inside the hysteresis zone, red at/over the threshold.
 /// Mirrors the charge-policy layers (heat > hysteresis band > safe).
    private func heatStatusColor(_ temp: Double) -> Color {
        let threshold = Double(engine.heatThresholdC)
        let lowerBound = threshold - ChargeConfig.heatHysteresisC
        if temp >= threshold { return .red }
        if temp >= lowerBound { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = engine.helperError {
                Label("助手连接失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, maxWidth: 560, minHeight: 400)
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .charging:
            chargingPane
        case .schedule:
            ScrollView {
                ScheduleSection(engine: engine)
                    .padding(20)
            }
        case .history:
            historyPane
        case .general:
            generalPane
        }
    }

    private var chargingPane: some View {
        Form {
            Section("充电上限") {
                Toggle("限制充电", isOn: $engine.limitingEnabled)
                if engine.limitingEnabled {
                    SliderRow(
                        label: "上限",
                        value: engine.targetPercent,
                        unit: "%",
                        range: 50...Double(max(engine.systemChargeLimit, 50)),
                        step: 5
                    ) {
                        engine.targetPercent = $0
                    }
                    SliderRow(
                        label: "缓冲",
                        value: engine.sailBufferPercent,
                        unit: "%",
                        range: 2...15,
                        step: 1
                    ) {
                        engine.sailBufferPercent = $0
                    }
                    Text("达到 \(engine.targetPercent)% 停止充电 · 跌至 \(engine.targetPercent - engine.sailBufferPercent)% 恢复")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if engine.systemChargeLimit < 100,
                       engine.targetPercent >= engine.systemChargeLimit {
                        Text("已到 macOS 系统上限 \(engine.systemChargeLimit)% · 可在系统设置的电池页面调高")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("充电行为") {
                Toggle("睡眠时停止充电", isOn: $engine.sleepStopCharging)
                    .help("睡眠期间停止充电，唤醒后按限充规则恢复")
                Toggle("达到上限前防止睡眠", isOn: $engine.preventSleepUntilLimit)
                    .help("充电期间阻止系统闲置睡眠；达到上限或停止充电后恢复，合盖睡眠不受影响")
                Toggle("自动放电", isOn: $engine.autoDischargeEnabled)
                    .help("接电且电量超过上限 2% 以上时，自动放电到上限")
                Toggle("退出时恢复充电", isOn: $engine.exitRestoresCharging)
                    .help("开启后 daemon 退出时（关机、重启、卸载）恢复充电和适配器；关闭时保持当前充电状态")
            }

            Section("过热保护") {
                Toggle("启用过热保护", isOn: $engine.heatProtectionEnabled)
                if engine.heatProtectionEnabled {
                    SliderRow(
                        label: "暂停阈值",
                        value: engine.heatThresholdC,
                        unit: "°C",
                        range: 30...45,
                        step: 1
                    ) {
                        engine.heatThresholdC = $0
                    }
 // Apple Settings pattern: explanation on the left
 // (secondary), live reading on the right with semantic
 // color — green in the safe band, orange inside the
 // hysteresis zone, red at/over the threshold. No
 // redundant threshold repeat (the slider shows it).
                    HStack {
                        Text("达到阈值暂停充电 · 温度下降 \(Int(ChargeConfig.heatHysteresisC))°C 后恢复")
                            .foregroundColor(.secondary)
                        Spacer()
                        if let temp = engine.snapshot.batteryTemp {
                            Text(String(format: "当前 %.1f°C", temp))
                                .monospacedDigit()
                                .foregroundStyle(heatStatusColor(temp))
                        }
                    }
                    .font(.caption)
                }
            }

            Section("操作") {
                if engine.calibrationActive {
                    Label("校准运行中", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.purple)
                    Button("取消校准") { engine.cancelCalibration() }
                        .buttonStyle(.borderless)
                } else if engine.dischargeActive {
                    Label("放电至 \(engine.dischargeFloor ?? engine.targetPercent)%", systemImage: "arrow.down.circle")
                        .foregroundColor(.blue)
                    Button("取消放电") { engine.cancelDischarge() }
                        .buttonStyle(.borderless)
                } else if engine.topUpActive {
                    Label("充满中 → 100%", systemImage: "bolt.fill")
                        .foregroundColor(.green)
                    Button("取消充满") { engine.cancelTopUp() }
                        .buttonStyle(.borderless)
                } else if !engine.limitingEnabled {
                    Text("开启限充后可使用这些操作。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack {
                        Button("充满一次") { engine.startTopUp() }
                            .disabled(engine.fullChargeLegBlocked)
                            .frame(maxWidth: .infinity)
                        Button("放电至 \(engine.targetPercent)%") { engine.startDischarge() }
                            .frame(maxWidth: .infinity)
                        Button("校准") { engine.startCalibration() }
                            .disabled(engine.fullChargeLegBlocked)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Text("校准流程：充电至 100% → 保持 10 分钟 → 放电至 10% → 恢复限充（全程约 3–4 小时，受 macOS 系统上限约束）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("电池信息") {
                BatteryInfoView(
                    info: engine.batteryInfo,
                    telemetry: engine.snapshot.readError == nil ? engine.snapshot : nil)
            }

            if engine.nativeLimitStalled {
                Section("macOS 充电上限") {
                    Label("系统上限阻止本次充满", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("已结束本次充满或校准。请在系统设置的电池页面将上限调到 100% 后重试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }

 /// Smart timestamp with seconds: "刚刚" / "15:42:07" (today) /
 /// "昨天 15:42:07" / "10月20日 15:42:07" — audit-grade precision
 /// (no hover needed).
    private func historyTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .standard))
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = now.timeIntervalSince(date) / 60
            if minutes < 1 { return "刚刚" }
            return time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        let day = date.formatted(.dateTime.month().day())
        return "\(day) \(time)"
    }

    private var historyPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if engine.actionHistory.isEmpty {
                    Text("暂无记录")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(engine.actionHistory) { entry in
                        HStack(alignment: .top, spacing: 12) {
 // Apple Settings/Notifications pattern: colored
 // icon circle leading — instantly scannable by
 // event type without reading the text.
                            Image(systemName: entry.kind.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(entry.kind.color, in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.detail)
                                    .font(.callout)
                                Text(historyTimestamp(entry.timestamp))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 5)
                        .help(entry.timestamp.formatted(
                            .dateTime.year().month().day().hour().minute().second()))
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            if !engine.actionHistory.isEmpty {
                Button("清除历史") { engine.clearHistory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding()
            }
        }
    }

    private var generalPane: some View {
        Form {
            Section("硬件") {
                Toggle("硬件电池百分比", isOn: $engine.hardwareBatteryPercent)
                    .help("开启后充电限制、航海模式、放电等功能以电池管理系统直报电量为基准；关闭时使用 macOS 显示电量，与系统菜单栏一致，两者最多可相差 7%")
                Toggle("MagSafe 指示灯", isOn: $engine.magsafeLedEnabled)
                    .help("到上限变绿、充电中变橙、断电熄灭；睡眠时由系统接管")
                Toggle("省电模式", isOn: Binding(
                    get: { engine.lowPowerModeEnabled },
                    set: { engine.setLowPowerMode($0) }))
                    .help("切换 macOS 低电量模式；定时任务也可以自动切换")
            }

            Section("系统集成") {
                Toggle("登录时启动 ChargeKit", isOn: Binding(
                    get: { engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) }))
                    .help("可在系统设置的登录项页面查看")
                if engine.launchAtLoginNeedsApproval {
                    Button("在系统设置中批准") { engine.openLoginItemsSettings() }
                }
                Toggle("通知", isOn: $engine.notificationsEnabled)
                    .help("达到上限、充满、放电或校准完成，以及系统上限阻止充满时提醒")
                if engine.notificationsEnabled {
                    Button("发送测试通知") {
                        Notifier.shared.post(
                            title: "ChargeKit 测试通知", body: "权限、图标与横幅样式验证")
                    }
                    .help("发送一条示例通知，验证系统通知权限与横幅图标是否正常")
                }
                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                    .help("定期检查 ChargeKit 新版本并在后台下载；应用菜单中的“检查更新…”始终可用")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }
}
