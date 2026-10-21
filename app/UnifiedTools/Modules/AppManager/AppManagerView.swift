import AppKit
import SwiftUI

private func formatted(bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Installed apps on the left; the selected app's details, leftovers and the remove button on the right.
struct AppManagerView: View {
    @Bindable var model: AppManagerModel
    @State private var confirmingRemoval = false
    @State private var showingResult = false

    var body: some View {
        HSplitView {
            list.frame(minWidth: 380, idealWidth: 460)
            detail.frame(minWidth: 340, idealWidth: 400)
        }
        .task { if model.apps.isEmpty { await model.reload() } }
        .onChange(of: model.selection) { _, _ in model.loadLeftovers() }
        .onChange(of: model.resultMessage) { _, message in showingResult = message != nil }
        .alert("清理结果", isPresented: $showingResult) {
            Button("好") { model.resultMessage = nil }
        } message: {
            Text(model.resultMessage ?? "")
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索应用名或标识", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新扫描")
                .disabled(model.isScanning)
            }
            .padding([.horizontal, .top], 10)

            HStack {
                Picker("筛选", selection: $model.filter) {
                    ForEach(AppManagerModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("排序", selection: $model.sort) {
                    ForEach(AppManagerModel.SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .labelsHidden()
            .padding(10)

            Divider()

            List(selection: $model.selection) {
                ForEach(model.visibleApps) { app in
                    AppRow(app: app, size: model.sizes[app.url])
                        .tag(app.url)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.isScanning && model.apps.isEmpty {
                    ProgressView("正在扫描…")
                }
            }

            Divider()

            HStack {
                Text("\(model.visibleApps.count) 个应用,合计 \(formatted(bytes: model.totalVisibleSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 12) {
                header(for: app)
                Divider()
                leftoverSection(for: app)
                Spacer(minLength: 0)
                removeBar(for: app)
            }
            .padding(16)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                Text("选择左边的应用查看详情").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title2.bold())
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(
                    [app.version.isEmpty ? nil : "版本 \(app.version)", app.source.rawValue, model.sizes[app.url].map { formatted(bytes: $0) }]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                Text(lastUsedText(for: app)).font(.caption).foregroundStyle(.secondary)
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    private func lastUsedText(for app: InstalledApp) -> String {
        guard let date = app.lastUsed else { return "最后使用:没有记录" }
        return "最后使用:" + date.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private func leftoverSection(for app: InstalledApp) -> some View {
        HStack {
            Text("残留文件").font(.headline)
            if model.isLoadingLeftovers { ProgressView().controlSize(.small) }
            Spacer()
            if !model.leftovers.isEmpty {
                Button("全选") { model.checked = Set(model.leftovers.map(\.url)) }
                Button("全不选") { model.checked = [] }
            }
        }
        .buttonStyle(.link)

        if model.leftovers.isEmpty && !model.isLoadingLeftovers {
            Text("没有找到残留文件").foregroundStyle(.secondary)
        } else {
            List {
                ForEach(model.leftovers) { item in
                    LeftoverRow(
                        item: item,
                        size: model.leftoverSizes[item.url],
                        isOn: Binding(
                            get: { model.checked.contains(item.url) },
                            set: { isOn in
                                if isOn { model.checked.insert(item.url) } else { model.checked.remove(item.url) }
                            }
                        )
                    )
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
        }
    }

    private func removeBar(for app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.isProtected {
                Label("这是系统自带或本应用自己,不能在这里移除", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("同时清除它的隐私授权记录(屏幕录制、辅助功能等)", isOn: $model.resetPrivacy)
                    .font(.caption)
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Label(model.isRemoving ? "正在处理…" : "移到废纸篓…", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.isRemoving || model.isLoadingLeftovers)
                .confirmationDialog(
                    "把「\(app.name)」和选中的 \(model.checked.count) 项残留移到废纸篓?",
                    isPresented: $confirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("移到废纸篓", role: .destructive) {
                        Task { await model.removeSelected() }
                    }
                } message: {
                    let total = (model.sizes[app.url] ?? 0) + model.checkedLeftoverSize
                    Text("共约 \(formatted(bytes: total))。只是移进废纸篓,清倒之前都能恢复。\(model.leftovers.contains { model.checked.contains($0.url) && $0.needsAdmin } ? "其中有系统级文件,会弹出系统的管理员密码框。" : "")")
                }
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(app.lastUsed.map { "最后使用 " + $0.formatted(.relative(presentation: .named)) } ?? "没有使用记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(size.map { formatted(bytes: $0) } ?? "…").monospacedDigit()
                if app.source == .appStore {
                    Text("App Store").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LeftoverRow: View {
    let item: Leftover
    let size: Int64?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isOn).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(.caption.bold())
                    if item.matchedByName { badge("按名称匹配") }
                    if item.needsAdmin { badge("需要管理员") }
                }
                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Text(size.map { formatted(bytes: $0) } ?? "…").font(.caption).monospacedDigit()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
}
