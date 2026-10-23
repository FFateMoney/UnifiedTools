import AppKit
import SwiftUI

private func memoryText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

/// Opened from the memory card: what the numbers mean, whether anything is wrong, and what to do about it.
struct MemoryDetailView: View {
    let system: SystemMonitor
    let processes: ProcessMonitor
    let onBack: () -> Void

    @State private var showGlossary = false
    @State private var confirmingForceQuit: AppUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) {
                    Label("概览", systemImage: "chevron.left")
                }
                .buttonStyle(.link)

                Text("内存").font(.largeTitle.bold())

                verdictCard
                compositionCard
                leakSection
                topAppsSection
                glossarySection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { processes.beginLive() }
        .onDisappear { processes.endLive() }
    }

    // MARK: - Verdict

    private var memory: MemoryInfo { system.memory }

    private var verdict: (title: String, detail: String, color: Color, symbol: String) {
        let swap = memoryText(memory.swapUsed)
        switch memory.pressure {
        case 4:
            return ("内存非常紧张", "系统正在不停地压缩内存、把数据写到硬盘上,电脑会明显变卡。建议马上退出下面占用最多的应用。", .red, "exclamationmark.octagon.fill")
        case 2:
            return ("内存有点紧张", "系统开始压缩内存了,再开更多程序会变慢。可以退出几个不用的、占内存多的应用。", .orange, "exclamationmark.triangle.fill")
        default:
            if memory.swapUsed > 2 * 1_073_741_824 {
                return ("现在正常,但曾经吃紧", "内存压力是绿色,不过已经用了 \(swap) 的交换空间,说明刚才内存不够用过。留意下面占用最多的应用。", .yellow, "checkmark.circle")
            }
            return ("内存状态健康", "“用了很多内存”本身不是问题:macOS 会故意把空闲内存拿来缓存文件,需要时立刻让出来。看这个绿色就够了,不需要处理。", .green, "checkmark.circle.fill")
        }
    }

    private var verdictCard: some View {
        let verdict = verdict
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: verdict.symbol).font(.title).foregroundStyle(verdict.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.title).font(.title3.bold())
                Text(verdict.detail).foregroundStyle(.secondary)
                Text("内存压力:\(pressureName)   ·   已用 \(memoryText(memory.used)) / \(memoryText(memory.total))   ·   可立刻使用 \(memoryText(memory.available))")
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(verdict.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pressureName: String {
        switch memory.pressure {
        case 4: "红(紧张)"
        case 2: "黄(有点紧)"
        default: "绿(够用)"
        }
    }

    // MARK: - Composition

    private var compositionCard: some View {
        let total = Double(max(memory.total, 1))
        let parts: [(name: String, bytes: UInt64, color: Color, note: String)] = [
            ("应用内存", memory.app, .blue, "各个程序正在使用的内存"),
            ("联动内存", memory.wired, .orange, "系统内核占着,不能压缩也不能换出,基本固定"),
            ("压缩内存", memory.compressed, .purple, "不常用的数据压缩后留在内存里。\(compressionNote)"),
            ("缓存文件", memory.cached, .teal, "最近读写过的文件,放在内存里加速。需要时立刻让出,可当作可用"),
            ("空闲", memory.free, .gray, "完全没人用。macOS 不会刻意留很多,闲着是浪费"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("内存都花在哪").font(.headline)
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts.indices, id: \.self) { index in
                        Rectangle()
                            .fill(parts[index].color)
                            .frame(width: max(geometry.size.width * Double(parts[index].bytes) / total - 1, 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)

            ForEach(parts.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(parts[index].color).frame(width: 9, height: 9)
                    Text(parts[index].name).frame(width: 70, alignment: .leading)
                    Text(memoryText(parts[index].bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(parts[index].note).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            Divider()
            HStack(spacing: 24) {
                fact("交换空间", memory.swapTotal == 0 ? "未使用" : "\(memoryText(memory.swapUsed)) / \(memoryText(memory.swapTotal))")
                fact("压缩节省", memory.compressionSaved > 0 ? memoryText(memory.compressionSaved) : "—")
                fact("内存压力", pressureName)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    private var compressionNote: String {
        memory.compressedOriginal > 0
            ? "原本 \(memoryText(memory.compressedOriginal)),压成 \(memoryText(memory.compressed))。"
            : ""
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    // MARK: - Leaks

    private var leakSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("疑似内存泄漏").font(.headline)
            Text("泄漏指一个程序不断申请内存却不归还,所以用得越久占得越多。macOS 没法直接告诉你谁在泄漏,这里的办法是:持续记录每个应用的内存,找出长时间只涨不降的。结果是“疑似”,不是定论。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if processes.suspects.isEmpty {
                let minutes = processes.observedMinutes
                let ready = minutes >= Int(LeakDetector.minimumObservation / 60)
                Label(
                    ready
                        ? "已观察 \(minutes) 分钟,没有发现持续增长的应用。"
                        : "已观察 \(minutes) 分钟。判断至少需要 30 分钟的记录,请让 UnifiedTools 继续在后台运行。",
                    systemImage: ready ? "checkmark.circle.fill" : "clock"
                )
                .foregroundStyle(ready ? .green : .secondary)
            } else {
                ForEach(processes.suspects) { suspect in
                    suspectCard(suspect)
                }
            }
        }
    }

    private func suspectCard(_ suspect: LeakSuspect) -> some View {
        let app = processes.apps.first { $0.id == suspect.id }
        let isBrowserLike = suspect.processCount >= 8
        let tint: Color = suspect.level == .likely ? .red : .orange
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let path = app?.bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(suspect.name).font(.title3.bold())
                    Text(suspect.level == .likely ? "很可能在泄漏" : "持续增长,需要留意")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                }
                Spacer()
                Text(memoryText(suspect.currentBytes)).font(.title3.monospacedDigit())
            }
            Text("最近 \(suspect.observedMinutes) 分钟涨了 \(memoryText(UInt64(max(suspect.growthBytes, 0)))),平均每小时 +\(memoryText(UInt64(max(suspect.bytesPerHour, 0)))),中间没有明显回落。")
                .font(.callout)
            if suspect.processCountGrew {
                Label("它的进程数也在增加,可能只是开了更多标签页或窗口。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("可以这样处理").font(.subheadline.bold())
            ForEach(Array(LeakDetector.advice(for: suspect, isBrowserLike: isBrowserLike).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).font(.callout)
                }
            }

            HStack {
                if let app, !app.isProtected {
                    Button("退出这个应用") { _ = processes.quit(app, force: false) }
                    Button("强制退出…", role: .destructive) { confirmingForceQuit = app }
                }
                if let app, let pid = app.pids.first {
                    Button("复制检查命令") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString("leaks \(pid)", forType: .string)
                        Toast.show("已复制:leaks \(pid)")
                    }
                    .help("在终端里粘贴运行,列出这个进程里真正泄漏的对象")
                }
            }
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog(
            "强制退出「\(confirmingForceQuit?.name ?? "")」?",
            isPresented: Binding(get: { confirmingForceQuit != nil }, set: { if !$0 { confirmingForceQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button("强制退出", role: .destructive) {
                if let app = confirmingForceQuit { _ = processes.quit(app, force: true) }
                confirmingForceQuit = nil
            }
        } message: {
            Text("没保存的内容会丢失。")
        }
    }

    // MARK: - Top apps

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("占内存最多的应用").font(.headline)
            Text("退出占得多又暂时不用的应用,是最直接的腾内存办法。“内存”一列是 Activity Monitor 里同名的口径。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProcessListView(monitor: processes, ranking: .memory, height: 340)
        }
    }

    // MARK: - Glossary

    private var glossarySection: some View {
        DisclosureGroup("看不懂?macOS 的内存是怎么回事", isExpanded: $showGlossary) {
            VStack(alignment: .leading, spacing: 12) {
                entry("为什么内存几乎总是“满的”?", "macOS 不让内存闲着:空闲的部分会拿来缓存你读过的文件,下次打开更快。这些缓存在程序需要内存时会立刻被丢掉,所以“用了 90%”不等于“不够用”。判断够不够用,看“内存压力”的颜色。")
                entry("内存压力", "macOS 综合空闲量、压缩和换页的情况给出的结论:绿色够用,黄色有点紧,红色紧张。它比“用了多少”更能说明有没有缺内存。")
                entry("压缩内存", "内存紧一点时,macOS 先把暂时不用的数据压缩起来继续放在内存里,比写到硬盘快得多。压缩本身是正常的省内存手段。")
                entry("交换空间", "压缩还不够时,系统把数据写到硬盘上暂存。硬盘比内存慢很多,所以交换用得多、而且在持续增长时,电脑就会卡。偶尔用一点不用管。")
                entry("联动内存(Wired)", "内核和驱动占的内存,不能压缩也不能换出,通常几个 GB 且比较固定。")
                entry("什么是内存泄漏", "程序申请了内存用完却没有归还,时间一长占的越来越多。表现是同一个应用开着不关,内存一直涨。重启这个应用,泄漏的内存就会全部还给系统。")
                entry("泄漏和“正常增长”怎么区分", "打开更多标签页、窗口、大文件,内存涨是正常的,关掉就会降回来。泄漏是你什么都没多做,它也在悄悄涨,而且很久都不回落。")
                entry("为什么不能直接加内存", "Apple 芯片的 Mac 内存焊在芯片上,买了就不能升级。所以内存紧张时,办法只有少开应用、关标签页、定期重启吃内存的应用。")
            }
            .padding(.top, 8)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func entry(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold())
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Opened from the CPU or network card: the same ranked list, full page.
struct ProcessDetailView: View {
    let title: String
    let ranking: ProcessListView.Ranking
    let processes: ProcessMonitor
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                Label("概览", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            ProcessListView(monitor: processes, ranking: ranking)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            processes.beginLive()
            if ranking == .network { processes.beginNetwork() }
        }
        .onDisappear {
            processes.endLive()
            if ranking == .network { processes.endNetwork() }
        }
    }

    private var subtitle: String {
        switch ranking {
        case .cpu: "处理器占用按单个核心算:100% 表示占满一个核心,多核机器上可以超过 100%。点表头可以换排序。"
        case .memory: ""
        case .network: "每个应用现在的下载和上传速度。后台一直有流量的应用,可能是在同步或更新。"
        }
    }
}
