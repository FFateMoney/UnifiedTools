import AppKit
import SwiftUI

private func memoryText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private func rateText(_ bytesPerSecond: Double) -> String {
    bytesPerSecond < 1 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
}

/// Apps ranked by what they use, with a button to quit each one: Activity Monitor in miniature.
struct ProcessListView: View {
    enum Ranking {
        case cpu, memory, network

        var comparators: [KeyPathComparator<AppUsage>] {
            switch self {
            case .cpu: [KeyPathComparator(\.cpuPercent, order: .reverse)]
            case .memory: [KeyPathComparator(\.footprint, order: .reverse)]
            case .network: [KeyPathComparator(\.networkTotal, order: .reverse)]
            }
        }
    }

    let monitor: ProcessMonitor
    var height: CGFloat?

    @State private var sortOrder: [KeyPathComparator<AppUsage>]
    @State private var hideSystem = true
    @State private var query = ""
    @State private var pendingForceQuit: AppUsage?
    @State private var pendingKill: AppUsage?
    @State private var message: String?

    init(monitor: ProcessMonitor, ranking: Ranking, height: CGFloat? = nil) {
        self.monitor = monitor
        self.height = height
        _sortOrder = State(initialValue: ranking.comparators)
    }

    private var rows: [AppUsage] {
        monitor.apps
            // Strictly by kind, never by current load: a row that hovers around a threshold would flicker in and out.
            .filter { !hideSystem || !$0.isSystem }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    private var hiddenSummary: String? {
        guard hideSystem else { return nil }
        let hidden = monitor.apps.filter(\.isSystem)
        guard !hidden.isEmpty else { return nil }
        let cpu = hidden.reduce(0) { $0 + $1.cpuPercent }
        let memory = hidden.reduce(UInt64(0)) { $0 + $1.footprint }
        return "已隐藏 \(hidden.count) 项 macOS 系统进程,合计处理器 \(String(format: "%.1f", cpu))%、内存 \(memoryText(memory))"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("搜索应用", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle("隐藏 macOS 系统进程", isOn: $hideSystem)
                Spacer()
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text("\(rows.count) 项").font(.caption).foregroundStyle(.secondary)
            }

            table
                .frame(height: height)
                .frame(minHeight: height ?? 240)

            if let hiddenSummary {
                Text(hiddenSummary).font(.caption).foregroundStyle(.secondary)
            }
            if !monitor.hasNetworkData {
                Text("网络用量正在统计,约需 4 秒。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "强制退出「\(pendingForceQuit?.name ?? "")」?",
            isPresented: Binding(get: { pendingForceQuit != nil }, set: { if !$0 { pendingForceQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button("强制退出", role: .destructive) {
                if let app = pendingForceQuit { message = monitor.quit(app, force: true) }
                pendingForceQuit = nil
            }
        } message: {
            Text("强制退出不给应用保存的机会,没保存的内容会丢失。只有在它不响应时才用。")
        }
        .confirmationDialog(
            "结束进程「\(pendingKill?.name ?? "")」?",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button("结束", role: .destructive) {
                if let app = pendingKill { message = monitor.quit(app, force: false) }
                pendingKill = nil
            }
        } message: {
            Text("这不是一个普通应用,而是后台程序或命令行工具。结束它可能影响依赖它的程序。")
        }
    }

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { app in
                HStack(spacing: 8) {
                    icon(for: app)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).lineLimit(1).truncationMode(.middle)
                        if let note = app.explanation {
                            Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        } else if app.processCount > 1 {
                            Text(app.helperCount > 0
                                ? "\(app.processCount) 个进程(含 \(app.helperCount) 个系统辅助进程)"
                                : "\(app.processCount) 个进程")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help(tooltip(for: app))
            }
            .width(min: 220, ideal: 320)
            TableColumn("处理器", value: \.cpuPercent) { app in
                Text(String(format: "%.1f%%", app.cpuPercent)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("内存", value: \.footprint) { app in
                Text(memoryText(app.footprint)).monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("下载", value: \.downloadPerSecond) { app in
                Text(rateText(app.downloadPerSecond)).monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("上传", value: \.uploadPerSecond) { app in
                Text(rateText(app.uploadPerSecond)).monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("") { app in
                quitMenu(for: app)
            }
            .width(80)
        }
    }

    /// Everything that did not fit in the row: full name, what it is, where it lives.
    private func tooltip(for app: AppUsage) -> String {
        var lines = [app.name]
        if app.rawName != app.name { lines.append("进程名:\(app.rawName)") }
        if let note = app.explanation { lines.append(note) }
        if !app.executablePath.isEmpty { lines.append("位置:\(app.executablePath)") }
        if app.helperCount > 0 { lines.append("其中 \(app.helperCount) 个是 macOS 替它工作的辅助进程(网页内容、着色器编译等),已计入它的占用") }
        lines.append("进程数:\(app.processCount)(进程号 \(app.pids.prefix(6).map(String.init).joined(separator: ", "))\(app.pids.count > 6 ? "…" : ""))")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func icon(for app: AppUsage) -> some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "gearshape").frame(width: 20, height: 20).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func quitMenu(for app: AppUsage) -> some View {
        if app.isProtected {
            EmptyView()
        } else {
            Menu("退出") {
                Button(app.bundlePath == nil ? "结束进程…" : "退出") {
                    if app.bundlePath == nil { pendingKill = app } else { message = monitor.quit(app, force: false) }
                }
                if app.bundlePath != nil {
                    Button("强制退出…", role: .destructive) { pendingForceQuit = app }
                }
            } primaryAction: {
                if app.bundlePath == nil { pendingKill = app } else { message = monitor.quit(app, force: false) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

extension AppUsage {
    /// Download plus upload, for ranking by network use.
    var networkTotal: Double { downloadPerSecond + uploadPerSecond }
}
