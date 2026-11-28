import AppKit
import SwiftUI
import ChargeKitCore
import Sparkle

enum SettingsPane: String, CaseIterable {
    case charging
    case battery
    case schedule
    case history
    case general

    var title: String {
        switch self {
        case .charging: return "充电"
        case .battery: return "电池"
        case .schedule: return "定时任务"
        case .history: return "操作历史"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .battery: return "battery.100percent"
        case .schedule: return "calendar"
        case .history: return "clock.arrow.circlepath"
        case .general: return "gearshape"
        }
    }

    var windowTitle: String {
        switch self {
        case .battery: return "电池信息"
        case .schedule, .history: return title
        default: return "\(title)设置"
        }
    }
}

private final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane

    init(pane: SettingsPane) {
        self.pane = pane
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let selection: SettingsSelection
    private static let selectedPaneKey = "chargekit.settingsPane"

    init(engine: ChargeEngine, updater: SPUUpdater) {
        let savedPane = UserDefaults.standard.string(forKey: Self.selectedPaneKey)
            .flatMap(SettingsPane.init(rawValue:))
        let selection = SettingsSelection(pane: savedPane ?? .charging)
        self.selection = selection

        let initialSize = NSSize(width: 700, height: 520)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.title = "ChargeKit 设置"

        super.init(window: window)
        let hostingController = NSHostingController(rootView:
            SettingsNavigationView(engine: engine, updater: updater, selection: selection) { [weak self] pane in
                self?.showPane(pane)
            })
        hostingController.sizingOptions = [.minSize]
        window.contentViewController = hostingController
        window.setContentSize(initialSize)
        window.center()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func showPane(_ pane: SettingsPane) {
        guard pane != selection.pane else { return }
        selection.pane = pane
        UserDefaults.standard.set(pane.rawValue, forKey: Self.selectedPaneKey)
    }
}

private struct SettingsNavigationView: View {
    let engine: ChargeEngine
    let updater: SPUUpdater
    @ObservedObject var selection: SettingsSelection
    let select: (SettingsPane) -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPane?>(
                get: { selection.pane },
                set: { if let pane = $0 { select(pane) } })) {
                    ForEach(SettingsPane.allCases, id: \.self) { pane in
                        Label(pane.title, systemImage: pane.symbol)
                            .tag(pane)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 150)
                .accessibilityLabel("设置分类")
            Divider()
            SettingsPaneView(engine: engine, updater: updater, pane: selection.pane)
                .id(selection.pane)
        }
        .frame(minWidth: 620, minHeight: 400)
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var engine: ChargeEngine
    let updater: SPUUpdater
    let pane: SettingsPane
    @State private var confirmingClearHistory = false
    @State private var canCheckForUpdates = false

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
            Text(pane.windowTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .charging:
            chargingPane
        case .battery:
            BatteryInfoView(
                info: engine.batteryInfo,
                snapshot: engine.snapshot,
                statusText: PopoverView.statusText(for: engine.snapshot, engine: engine),
                lowPowerMode: engine.lowPowerModeEnabled)
        case .schedule:
            ScheduleSection(engine: engine)
        case .history:
            historyPane
        case .general:
            generalPane
        }
    }

    @ViewBuilder
    private var chargingPane: some View {
        if engine.chargeControlMode.controlsCharging {
            legacyChargingPane
        } else {
            Form {
                Section("充电管理") {
                    if engine.chargeControlMode == .systemManaged {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("macOS 管理充电上限", systemImage: "battery.100percent")
                                .font(.headline)
                            Text("可在系统电池设置调整上限，需要满电时可从 macOS 电池菜单选择「立即充满」。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: openSystemBatterySettings) {
                                Label("打开电池设置", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("此 Mac 仅支持电池监控。")
                    }
                }
                lowPowerSection
                adapterSection
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)
        }
    }

    private var legacyChargingPane: some View {
        Form {
            Section {
                Toggle("限制充电", isOn: $engine.limitingEnabled)
                if engine.limitingEnabled {
                    SliderRow(
                        label: "停止充电电量",
                        value: engine.targetPercent,
                        unit: "%",
                        range: 50...100,
                        step: 5
                    ) {
                        engine.targetPercent = $0
                    }
                    SliderRow(
                        label: "恢复充电缓冲",
                        value: engine.sailBufferPercent,
                        unit: "%",
                        range: 2...15,
                        step: 1
                    ) {
                        engine.sailBufferPercent = $0
                    }
                }
                Toggle("按硬件电量执行限充", isOn: $engine.hardwareBatteryPercent)
                    .help("同时用于电量显示和放电目标。关闭时使用 macOS 电量，读不到时回退到硬件电量。")
            } header: {
                Text("充电上限")
            } footer: {
                if engine.limitingEnabled {
                    Text("达到 \(engine.targetPercent)% 停止充电，降至 \(engine.targetPercent - engine.sailBufferPercent)% 恢复。")
                }
            }

            Section("睡眠与退出") {
                Toggle("睡眠时停止充电", isOn: $engine.sleepStopCharging)
                    .help("睡眠期间停止充电，唤醒后按限充规则恢复")
                Toggle("达到上限前防止睡眠", isOn: $engine.preventSleepUntilLimit)
                    .help("充电期间阻止系统闲置睡眠；达到上限或停止充电后恢复，合盖睡眠不受影响")
                Toggle("辅助服务退出时恢复充电", isOn: $engine.exitRestoresCharging)
                    .help("控制充电辅助服务退出时的充电开关。")
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
                        if engine.snapshot.hasTelemetry, let temp = engine.snapshot.batteryTemp {
                            Text(String(format: "当前 %.1f°C", temp))
                                .monospacedDigit()
                                .foregroundStyle(heatStatusColor(temp))
                        }
                    }
                    .font(.caption)
                }
            }

            Section("放电与电池校准") {
                Toggle("自动放电至充电上限", isOn: $engine.autoDischargeEnabled)
                    .help("开启限充后，接电且电量高于充电上限时，满足条件便自动放电。")
                if engine.dischargeStartPending {
                    ProgressView("正在准备放电…")
                        .controlSize(.small)
                } else if engine.calibrationActive {
                    sessionRow("取消校准", icon: "arrow.triangle.2.circlepath", cancel: engine.cancelCalibration)
                } else if engine.dischargeActive {
                    sessionRow("取消放电", icon: "arrow.down.circle", cancel: engine.cancelDischarge)
                } else if engine.topUpActive {
                    sessionRow("取消充满", icon: "bolt.fill", cancel: engine.cancelTopUp)
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

            if engine.nativeLimitStalled {
                Section("macOS 充电上限") {
                    Label("系统上限阻止本次充满", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("已结束本次充满或校准。请在系统设置的电池页面将上限调到 100% 后重试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            lowPowerSection
            adapterSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }

    private func sessionRow(_ cancelTitle: String, icon: String, cancel: @escaping () -> Void) -> some View {
        HStack {
            Label(PopoverView.statusText(for: engine.snapshot, engine: engine), systemImage: icon)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(cancelTitle, action: cancel)
                .buttonStyle(.bordered)
        }
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
        VStack(spacing: 0) {
            if engine.actionHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("暂无操作记录")
                        .font(.headline)
                    Text("充放电、定时任务和电源变化会记录在这里。")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
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
                        .padding(.vertical, 5)
                        .help(entry.timestamp.formatted(
                            .dateTime.year().month().day().hour().minute().second()))
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    Text("\(engine.actionHistory.count) 条记录")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除历史…") { confirmingClearHistory = true }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .alert("清除所有历史记录？", isPresented: $confirmingClearHistory) {
            Button("取消", role: .cancel) {}
            Button("清除历史", role: .destructive) { engine.clearHistory() }
        } message: {
            Text("清除后无法恢复。")
        }
    }

    private var lowPowerSection: some View {
        Section {
            Toggle("低电量模式", isOn: Binding(
                get: { engine.lowPowerModeSwitchValue },
                set: { engine.setLowPowerMode($0) }))
                .disabled(engine.lowPowerModeSwitchBusy)
            if engine.lowPowerModeNeedsAuthorization {
                ProgressView("等待管理员授权…").controlSize(.small)
            } else if engine.lowPowerModeSwitchBusy {
                ProgressView("正在切换低电量模式…").controlSize(.small)
            } else if let error = engine.lowPowerModeError {
                Label("无法切换低电量模式 · \(error)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            Toggle("按电量自动切换", isOn: $engine.automaticLowPowerMode)
            if engine.automaticLowPowerMode {
                let thresholdRange = LowPowerModePolicy.thresholdRange
                SliderRow(
                    label: "自动开启阈值",
                    value: engine.lowPowerModeThreshold,
                    unit: "%",
                    range: Double(thresholdRange.lowerBound)...Double(thresholdRange.upperBound),
                    step: 1,
                    showsTickMarks: false,
                    allowsTextEntry: true
                ) {
                    engine.lowPowerModeThreshold = $0
                }
            }
        } header: {
            Text("低电量模式")
        } footer: {
            Text("手动切换优先于自动规则，下次接入电源时恢复自动规则。")
            if engine.automaticLowPowerMode {
                Text("使用电池且电量低于阈值时自动开启，接入电源时关闭。")
            }
        }
    }

    private var adapterSection: some View {
        Section("电源适配器") {
            Toggle("由 ChargeKit 管理 MagSafe 灯色", isOn: $engine.magsafeLedEnabled)
                .help("充电时显示橙色，适配器供电且停止充电时显示绿色。关闭后由 macOS 管理。")
            if let error = engine.helperError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var generalPane: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 ChargeKit", isOn: Binding(
                    get: { engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) }))
                    .help("可在系统设置的登录项页面查看")
                if engine.launchAtLoginNeedsApproval {
                    Button("在系统设置中批准") { engine.openLoginItemsSettings() }
                }
                if let error = engine.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            Section("通知") {
                Toggle("充放电事件提醒", isOn: $engine.notificationsEnabled)
                    .help("达到上限、充满、放电或校准完成，以及系统上限阻止充满时提醒")
                if engine.notificationsEnabled {
                    Button("发送测试通知") {
                        Notifier.shared.post(
                            title: "ChargeKit 测试通知", body: "权限、图标与横幅样式验证")
                    }
                    .help("发送一条示例通知，验证系统通知权限与横幅图标是否正常")
                }
            }
            Section("软件更新") {
                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                    .help("定期检查是否有 ChargeKit 新版本")
                Button("检查更新…") {
                    guard updater.canCheckForUpdates else { return }
                    updater.checkForUpdates()
                }
                .disabled(!canCheckForUpdates)
                .onReceive(updater.publisher(for: \.canCheckForUpdates)) { available in
                    canCheckForUpdates = available
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }
}
