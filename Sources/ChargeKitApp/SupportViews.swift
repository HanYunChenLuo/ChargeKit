import AppKit
import SwiftUI

struct DiagnosticsReport {
    let capturedAt = Date()
    let appVersion: String
    let build: String
    var helperStatus: String
    let chargingMode: String
    let batteryLevel: String
    let powerSource: String
    let chargingState: String
    let lowPowerMode: String
    let adapterInput: String
    let hostLoad: String
    let batteryPower: String

    var systemRows: [(String, String)] {
        [
            ("ChargeKit", "\(appVersion) · 构建 \(build)"),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Helper", helperStatus),
            ("充电管理", chargingMode),
        ]
    }

    var powerRows: [(String, String)] {
        [
            ("电池电量", batteryLevel),
            ("供电来源", powerSource),
            ("充电状态", chargingState),
            ("低电量模式", lowPowerMode),
            ("适配器输入", adapterInput),
            ("主机负载", hostLoad),
            ("电池功率", batteryPower),
        ]
    }

    var text: String {
        (["ChargeKit 诊断信息", "采集时间  \(capturedAt.formatted(.iso8601))"]
            + ["", "系统与版本"] + systemRows.map { "\($0.0)  \($0.1)" }
            + ["", "电源与电池"] + powerRows.map { "\($0.0)  \($0.1)" })
            .joined(separator: "\n")
    }
}

struct AboutView: View {
    let appVersion: String
    let build: String
    let showDiagnostics: () -> Void
    let checkForUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChargeKit")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("MacBook 充电管理")
                        .foregroundStyle(.secondary)
                    Text("版本 \(appVersion) · 构建 \(build)")
                        .font(.callout.monospacedDigit())
                        .textSelection(.enabled)
                }
            }
            Divider()
            Link(destination: URL(string: "https://github.com/HanYunChenLuo/ChargeKit")!) {
                Label("GitHub 项目", systemImage: "arrow.up.right.square")
            }
            HStack {
                Button("检查更新…", action: checkForUpdates)
                Spacer()
                Button("诊断信息…", action: showDiagnostics)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct DiagnosticsView: View {
    let makeReport: () -> DiagnosticsReport
    let close: () -> Void
    private let presentationID = UUID()
    @State private var report: DiagnosticsReport
    @State private var copyFeedback: String?

    init(makeReport: @escaping () -> DiagnosticsReport, close: @escaping () -> Void) {
        self.makeReport = makeReport
        self.close = close
        _report = State(initialValue: makeReport())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("采集于 \(report.capturedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("系统与版本", rows: report.systemRows)
                    section("电源与电池", rows: report.powerRows)
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button("刷新") {
                    refresh()
                }
                if let copyFeedback {
                    Text(copyFeedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("复制诊断报告") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copyFeedback = pasteboard.setString(report.text, forType: .string)
                        ? "已复制" : "复制失败"
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 330)
        .onChange(of: presentationID) { _ in
            refresh()
        }
        .task(id: report.capturedAt) {
            guard HelperClient.shared.isConnected, !HelperInstaller.shared.needsInstall else { return }
            let capturedAt = report.capturedAt
            HelperClient.shared.version { version in
                DispatchQueue.main.async {
                    guard let version, report.capturedAt == capturedAt else { return }
                    report.helperStatus = "版本 \(version)"
                }
            }
        }
    }

    private func refresh() {
        report = makeReport()
        copyFeedback = nil
    }

    private func section(_ heading: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}