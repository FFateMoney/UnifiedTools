import SwiftUI

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private func fileBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private func color(forPercent percent: Double) -> Color {
    percent < 60 ? .green : (percent < 85 ? .orange : .red)
}

/// The overview page: how hot, full and busy this Mac is right now.
struct SystemStatusView: View {
    private enum Route {
        case home, cpu, memory, network
    }

    @State private var monitor = SystemMonitor.shared
    @State private var route = Route.home

    var body: some View {
        Group {
            switch route {
            case .home:
                home
            case .cpu:
                ProcessDetailView(title: "处理器", ranking: .cpu, processes: .shared) { route = .home }
            case .memory:
                MemoryDetailView(system: monitor, processes: .shared) { route = .home }
            case .network:
                ProcessDetailView(title: "网络", ranking: .network, processes: .shared) { route = .home }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// A card that opens its detail page when clicked.
    private func opening<Card: View>(_ destination: Route, _ card: Card) -> some View {
        Button { route = destination } label: {
            card.overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(14)
            }
        }
        .buttonStyle(.plain)
        .help("点击查看详情")
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                    opening(.cpu, cpuCard)
                    opening(.memory, memoryCard)
                    storageCard
                    temperatureCard
                    opening(.network, networkCard)
                    if monitor.gpuPercent != nil { gpuCard }
                    if monitor.battery != nil { batteryCard }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.chip.isEmpty ? "这台 Mac" : monitor.chip).font(.title2.bold())
            Text("\(monitor.model) · \(monitor.coreCount) 核 · \(bytes(monitor.memory.total)) 内存 · macOS \(monitor.systemVersion.replacingOccurrences(of: "Version ", with: "")) · 已开机 \(uptimeText)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var uptimeText: String {
        let hours = Int(monitor.uptime) / 3600
        return hours >= 24 ? "\(hours / 24) 天 \(hours % 24) 小时" : "\(hours) 小时 \(Int(monitor.uptime) / 60 % 60) 分钟"
    }

    // MARK: - Cards

    private var cpuCard: some View {
        StatusCard(title: "处理器", symbol: "cpu") {
            Text(String(format: "%.0f%%", monitor.cpuPercent))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(color(forPercent: monitor.cpuPercent))
            Sparkline(values: monitor.cpuHistory, ceiling: 100, tint: color(forPercent: monitor.cpuPercent))
            Text(String(format: "用户 %.0f%% · 系统 %.0f%%", monitor.cpuUserPercent, monitor.cpuSystemPercent))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        let memory = monitor.memory
        let total = Double(max(memory.total, 1))
        let percent = Double(memory.used) / total * 100
        return StatusCard(title: "内存", symbol: "memorychip") {
            Text("\(bytes(memory.used)) / \(bytes(memory.total))")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            UsageBar(segments: [
                (Double(memory.app) / total, .blue),
                (Double(memory.wired) / total, .orange),
                (Double(memory.compressed) / total, .purple),
            ])
            Sparkline(values: monitor.memoryHistory, ceiling: 100, tint: color(forPercent: percent))
            HStack(spacing: 10) {
                legend("应用 \(bytes(memory.app))", .blue)
                legend("联动 \(bytes(memory.wired))", .orange)
                legend("压缩 \(bytes(memory.compressed))", .purple)
            }
            Text("内存压力:\(pressureText(memory.pressure))" + (memory.swapUsed > 0 ? " · 交换 \(bytes(memory.swapUsed))" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pressureText(_ level: Int) -> String {
        switch level {
        case 4: "严重"
        case 2: "警告"
        default: "正常"
        }
    }

    private var storageCard: some View {
        let total = Double(max(monitor.storageTotal, 1))
        let used = Double(monitor.storageTotal - monitor.storageAvailable)
        return StatusCard(title: "存储", symbol: "internaldrive") {
            Text("已用 \(fileBytes(Int64(used)))")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            UsageBar(segments: [(used / total, color(forPercent: used / total * 100))])
            Text("可用 \(fileBytes(monitor.storageAvailable)) / 共 \(fileBytes(monitor.storageTotal))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var temperatureCard: some View {
        StatusCard(title: "温度", symbol: "thermometer.medium") {
            if let cpu = monitor.dieTemperatures.max() {
                let average = monitor.dieTemperatures.reduce(0, +) / Double(monitor.dieTemperatures.count)
                Text(String(format: "%.0f°C", cpu))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(temperatureColor(cpu))
                Text(String(format: "处理器核心 · 最高 %.0f° / 平均 %.0f°", cpu, average))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let battery = monitor.batteryTemperature {
                row("电池", String(format: "%.1f°C", battery))
            }
            if let storage = monitor.storageTemperature {
                row("固态硬盘", String(format: "%.0f°C", storage))
            }
            row("散热状态", thermalText)
        }
    }

    private func temperatureColor(_ celsius: Double) -> Color {
        celsius < 60 ? .green : (celsius < 85 ? .orange : .red)
    }

    private var thermalText: String {
        switch monitor.thermalState {
        case .nominal: "正常"
        case .fair: "略高"
        case .serious: "较高,可能降频"
        case .critical: "过热,正在降频"
        @unknown default: "未知"
        }
    }

    private var networkCard: some View {
        StatusCard(title: "网络", symbol: "arrow.up.arrow.down") {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                speed("arrow.down", monitor.downloadSpeed, .green)
                speed("arrow.up", monitor.uploadSpeed, .blue)
            }
            Sparkline(values: monitor.downloadHistory, ceiling: nil, tint: .green)
            Sparkline(values: monitor.uploadHistory, ceiling: nil, tint: .blue)
            Text("Wi-Fi 和有线网络合计").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func speed(_ symbol: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var gpuCard: some View {
        let value = Double(monitor.gpuPercent ?? 0)
        return StatusCard(title: "图形处理器", symbol: "display") {
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(color(forPercent: value))
            Sparkline(values: monitor.gpuHistory, ceiling: 100, tint: color(forPercent: value))
        }
    }

    private var batteryCard: some View {
        let battery = monitor.battery ?? BatteryInfo()
        return StatusCard(title: "电池", symbol: battery.isCharging ? "battery.100.bolt" : "battery.75") {
            Text("\(battery.percent)%")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(battery.percent < 20 && !battery.onAC ? .red : .primary)
            UsageBar(segments: [(Double(battery.percent) / 100, battery.percent < 20 ? .red : .green)])
            row("状态", battery.isCharging ? "充电中" : (battery.onAC ? "已接通电源" : "使用电池"))
            if let minutes = battery.minutesRemaining, !battery.onAC {
                row("剩余", "约 \(minutes / 60) 小时 \(minutes % 60) 分钟")
            }
            if let health = battery.healthPercent { row("最大容量", "\(health)%") }
            if let cycles = battery.cycleCount { row("循环次数", "\(cycles)") }
            if let watts = battery.adapterWatts, battery.onAC { row("电源适配器", "\(watts) W") }
        }
    }

    // MARK: - Pieces

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func legend(_ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StatusCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

/// A horizontal bar made of stacked fractions of the whole.
private struct UsageBar: View {
    let segments: [(fraction: Double, tint: Color)]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1))
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { index in
                        Rectangle()
                            .fill(segments[index].tint)
                            .frame(width: geometry.size.width * min(max(segments[index].fraction, 0), 1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: 8)
    }
}

/// A small line chart of the last minute or so. `ceiling` fixes the top of the scale; nil scales to the data.
private struct Sparkline: View {
    let values: [Double]
    let ceiling: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let top = max(ceiling ?? (values.max() ?? 1), 1)
            let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: geometry.size.height * (1 - CGFloat(min(value / top, 1)))
                )
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: 34)
    }
}
