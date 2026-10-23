import SwiftUI
import ChargeKitCore

// MARK: - 定时 section (S7 scheduling)
//
// Rule list with a compact per-rule editor: time, repeat mode (+ its
// weekday / day-of-month / date extras), action (+ its percent parameter).
// Semantics live in ChargeKitCore.ScheduleEngine; this file is pure UI.

/// UI-facing repeat kinds mapped onto ScheduleRepeat (associated values
/// default sensibly when switching kinds).
enum ScheduleRepeatKind: String, CaseIterable, Identifiable {
    case never = "从不"
    case daily = "每天"
    case weekdays = "工作日"
    case weekly = "每周"
    case biweekly = "每两周"
    case monthly = "每月"
    case yearly = "每年"

    var id: String { rawValue }

    static func of(_ mode: ScheduleRepeat) -> Self {
        switch mode {
        case .never: return .never
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .weekly: return .weekly
        case .biweekly: return .biweekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

 /// Default value for the kind, preserving weekdays where applicable.
    func makeMode(from previous: ScheduleRepeat, now: Date) -> ScheduleRepeat {
        let weekdays: Set<Int>
        switch previous {
        case .weekly(let s), .biweekly(let s, _):
            weekdays = s.isEmpty ? [1] : s
        default:
            weekdays = [1]
        }
        switch self {
        case .never: return .never
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .weekly: return .weekly(weekdays)
        case .biweekly: return .biweekly(weekdays: weekdays, anchor: now)
        case .monthly:
            if case .monthly(let d) = previous { return .monthly(day: d) }
            return .monthly(day: 1)
        case .yearly:
            if case .yearly(let m, let d) = previous { return .yearly(month: m, day: d) }
            let c = Calendar.current.dateComponents([.month, .day], from: now)
            return .yearly(month: c.month ?? 1, day: c.day ?? 1)
        }
    }
}

/// UI-facing action kinds; Low Power Mode on/off are two separate actions
/// (some tools list them as two actions).
enum ScheduleActionKind: String, CaseIterable, Identifiable {
    case setLimit = "设置上限"
    case dischargeTo = "放电至"
    case pauseCharging = "暂停充电"
    case topUp = "充满"
    case startCalibration = "校准"
    case lpmOn = "开低电量模式"
    case lpmOff = "关低电量模式"

    var id: String { rawValue }

    static func of(_ action: ScheduleAction) -> Self {
        switch action {
        case .setLimit: return .setLimit
        case .dischargeTo: return .dischargeTo
        case .pauseCharging: return .pauseCharging
        case .topUp: return .topUp
        case .startCalibration: return .startCalibration
        case .setLowPowerMode(true): return .lpmOn
        case .setLowPowerMode(false): return .lpmOff
        }
    }

 /// Default action value, preserving the percent where applicable.
    func makeAction(from previous: ScheduleAction) -> ScheduleAction {
        let pct: Int
        switch previous {
        case .setLimit(let v), .dischargeTo(let v): pct = v
        default: pct = 80
        }
        switch self {
        case .setLimit: return .setLimit(pct)
        case .dischargeTo: return .dischargeTo(pct)
        case .pauseCharging: return .pauseCharging
        case .topUp: return .topUp
        case .startCalibration: return .startCalibration
        case .lpmOn: return .setLowPowerMode(true)
        case .lpmOff: return .setLowPowerMode(false)
        }
    }
}

struct ScheduleSection: View {
    @ObservedObject var engine: ChargeEngine
    @State private var editingRule: ScheduleRuleDraft?
    @State private var pendingDeletion: ScheduleRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "定时")
                Spacer()
                Button {
                    editingRule = ScheduleRuleDraft(
                        rule: engine.makeScheduleRuleDraft(),
                        isNew: true)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("添加定时任务（错过时间当天内唤醒会补做）")
                .accessibilityLabel(Text("添加定时任务"))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作日地区")
                        .font(.callout)
                    Text(engine.workdayCalendarStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Picker("工作日地区", selection: $engine.workdayCalendarRegion) {
                    ForEach(WorkdayCalendarRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(Text("工作日地区"))
            }
            if engine.scheduleRules.isEmpty {
                Text("无定时任务")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(engine.scheduleRules) { rule in
                ScheduleRuleSummaryRow(
                    rule: rule,
                    onToggle: { enabled in
                        engine.setScheduleRuleEnabled(rule.id, enabled: enabled)
                    },
                    onEdit: {
                        editingRule = ScheduleRuleDraft(rule: rule, isNew: false)
                    },
                    onDelete: {
                        pendingDeletion = rule
                    })
            }
        }
        .sheet(item: $editingRule) { request in
            ScheduleRuleEditor(
                engine: engine,
                rule: request.rule,
                originalRule: request.originalRule,
                isNew: request.isNew,
                onSave: { rule, isNew, enabledWasEdited in
                    engine.saveScheduleRule(
                        rule,
                        isNew: isNew,
                        originalRule: request.originalRule,
                        enabledWasEdited: enabledWasEdited)
                    editingRule = nil
                },
                onCancel: {
                    editingRule = nil
                })
        }
        .confirmationDialog(
            "删除定时任务？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let rule = pendingDeletion {
                    engine.deleteScheduleRule(rule.id)
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }
}

private struct RowIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .accentColor
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovering ? tint : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        isHovering
                            ? tint.opacity(0.15)
                            : Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .onHover { isHovering = $0 }
    }
}

private struct ScheduleRuleDraft: Identifiable {
    let rule: ScheduleRule
    let originalRule: ScheduleRule?
    let isNew: Bool

    var id: UUID { rule.id }

    init(rule: ScheduleRule, isNew: Bool) {
        self.rule = rule
        self.originalRule = isNew ? nil : rule
        self.isNew = isNew
    }
}

private struct ScheduleRuleSummaryRow: View {
    let rule: ScheduleRule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: "%02d:%02d", rule.hour, rule.minute))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(repeatDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: onToggle))
                    .labelsHidden()
                    .help(rule.enabled ? "已启用" : "已停用")
                    .accessibilityLabel(Text("启用此定时任务"))
                    .accessibilityValue(Text(rule.enabled ? "已启用" : "已停用"))
            }
            HStack {
                Text(actionDescription)
                    .font(.callout)
                Spacer(minLength: 4)
                RowIconButton(
                    systemImage: "pencil",
                    label: "编辑定时任务",
                    action: onEdit)
                RowIconButton(
                    systemImage: "trash",
                    label: "删除定时任务",
                    tint: .red,
                    action: onDelete)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
    }

    private var repeatDescription: String {
        switch rule.repeatMode {
        case .never:
            return "仅一次"
        case .daily:
            return "每天"
        case .weekdays:
            return "工作日"
        case .weekly(let days):
            return "每周 · \(weekdaySummary(days))"
        case .biweekly(let days, _):
            return "每两周 · \(weekdaySummary(days))"
        case .monthly(let day):
            return "每月 \(day) 日"
        case .yearly(let month, let day):
            return "每年 \(month) 月 \(day) 日"
        }
    }

    private func weekdaySummary(_ selectedDays: Set<Int>) -> String {
        let labels = selectedDays.sorted().compactMap { day -> String? in
            guard (1...7).contains(day) else { return nil }
            return Self.weekdayLabels[day - 1]
        }
        return labels.isEmpty ? "未选择星期" : labels.joined(separator: "、")
    }

    private var actionDescription: String {
        switch rule.action {
        case .setLimit(let value): return "设置上限 \(value)%"
        case .dischargeTo(let value): return "放电至 \(value)%"
        case .pauseCharging: return "暂停充电"
        case .topUp: return "充满"
        case .startCalibration: return "校准"
        case .setLowPowerMode(true): return "开启低电量模式"
        case .setLowPowerMode(false): return "关闭低电量模式"
        }
    }
}

private struct ScheduleRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleRule
    @State private var enabledWasEdited = false
    @ObservedObject var engine: ChargeEngine
    let originalRule: ScheduleRule?
    let isNew: Bool
    let onSave: (ScheduleRule, Bool, Bool) -> Void
    let onCancel: () -> Void

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]
    private static let weekdayAccessibilityLabels =
        ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

    init(
        engine: ChargeEngine,
        rule: ScheduleRule,
        originalRule: ScheduleRule?,
        isNew: Bool,
        onSave: @escaping (ScheduleRule, Bool, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: rule)
        self.engine = engine
        self.originalRule = originalRule
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新建定时任务" : "编辑定时任务")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                Section("任务") {
                    DatePicker(
                        "执行时间",
                        selection: timeSelection,
                        displayedComponents: .hourAndMinute)
                    Toggle("启用", isOn: enabledSelection)
                }

                Section("重复") {
                    Picker("重复", selection: repeatKind) {
                        ForEach(ScheduleRepeatKind.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    repeatExtras
                    if case .weekdays = draft.repeatMode {
                        Text("\(engine.workdayCalendarRegion.title)：\(engine.workdayCalendarRegion.detail)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("动作") {
                    Picker("动作", selection: actionKind) {
                        ForEach(ScheduleActionKind.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    actionExtras
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button("取消", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("保存") {
                    onSave(draft, isNew, enabledWasEdited)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 560)
    }

    private var enabledSelection: Binding<Bool> {
        Binding(
            get: {
                if !enabledWasEdited,
                   let originalRule,
                   case .never = originalRule.repeatMode,
                   originalRule.enabled,
                   engine.scheduleRules.first(where: { $0.id == originalRule.id })?.enabled == false {
                    return false
                }
                return draft.enabled
            },
            set: {
                draft.enabled = $0
                enabledWasEdited = true
            })
    }

    private var timeSelection: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: draft.hour,
                    minute: draft.minute,
                    second: 0,
                    of: Date()) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = components.hour ?? draft.hour
                draft.minute = components.minute ?? draft.minute
            })
    }

    private var repeatKind: Binding<ScheduleRepeatKind> {
        Binding(
            get: { ScheduleRepeatKind.of(draft.repeatMode) },
            set: { draft.repeatMode = $0.makeMode(from: draft.repeatMode, now: Date()) })
    }

    private var actionKind: Binding<ScheduleActionKind> {
        Binding(
            get: { ScheduleActionKind.of(draft.action) },
            set: { draft.action = $0.makeAction(from: draft.action) })
    }

    @ViewBuilder
    private var repeatExtras: some View {
        switch draft.repeatMode {
        case .weekly(let days):
            HStack {
                Text("重复星期")
                Spacer()
                weekdayPicker(days: days) { draft.repeatMode = .weekly($0) }
            }
        case .biweekly(let days, let anchor):
            HStack {
                Text("重复星期")
                Spacer()
                weekdayPicker(days: days) {
                    draft.repeatMode = .biweekly(weekdays: $0, anchor: anchor)
                }
            }
            Text("按创建周为锚点隔周重复。")
                .font(.caption)
                .foregroundColor(.secondary)
        case .monthly(let day):
            Stepper("每月 \(day) 日", value: Binding(
                get: { day },
                set: { draft.repeatMode = .monthly(day: $0) }),
                    in: 1...31)
        case .yearly(let month, let day):
            HStack(spacing: 12) {
                Stepper("\(month) 月", value: Binding(
                    get: { month },
                    set: {
                        draft.repeatMode = .yearly(
                            month: $0,
                            day: min(day, Self.days(inMonth: $0)))
                    }),
                        in: 1...12)
                Stepper("\(day) 日", value: Binding(
                    get: { day },
                    set: {
                        draft.repeatMode = .yearly(
                            month: month,
                            day: min($0, Self.days(inMonth: month)))
                    }),
                        in: 1...31)
            }
        case .never, .daily, .weekdays:
            EmptyView()
        }
    }

    private func weekdayPicker(
        days: Set<Int>,
        set: @escaping (Set<Int>) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { weekday in
                let selected = days.contains(weekday)
                Button {
                    var updatedDays = days
                    if updatedDays.contains(weekday) {
                        updatedDays.remove(weekday)
                    } else {
                        updatedDays.insert(weekday)
                    }
                    if !updatedDays.isEmpty { set(updatedDays) }
                } label: {
                    Text(Self.weekdayLabels[weekday - 1])
                        .font(.caption2)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(selected ? Color.accentColor : .clear))
                        .foregroundColor(selected ? .white : .secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(Self.weekdayAccessibilityLabels[weekday - 1]))
                .accessibilityValue(Text(selected ? "已选择" : "未选择"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Text("点按切换此星期"))
            }
        }
    }

    @ViewBuilder
    private var actionExtras: some View {
        switch draft.action {
        case .setLimit(let value):
            Stepper("上限 \(value)%", value: Binding(
                get: { value },
                set: { draft.action = .setLimit($0) }),
                    in: 50...100,
                    step: 5)
        case .dischargeTo(let value):
            Stepper("放到 \(value)%", value: Binding(
                get: { value },
                set: { draft.action = .dischargeTo($0) }),
                    in: 50...100,
                    step: 5)
        default:
            EmptyView()
        }
    }

    private static func days(inMonth month: Int) -> Int {
        let date = Calendar.current.date(from: DateComponents(year: 2024, month: month)) ?? Date()
        return Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 31
    }
}
