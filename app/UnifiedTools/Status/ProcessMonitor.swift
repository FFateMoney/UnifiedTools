import AppKit
import Observation

/// An app and all of its helper processes, added together.
struct AppUsage: Identifiable {
    let id: String
    let name: String
    /// The process name as the system reports it, for the tooltip.
    let rawName: String
    /// The `.app` bundle, or nil for command-line tools and system services.
    let bundlePath: String?
    let pids: [pid_t]
    /// How many of those are macOS helper processes (web content, shader compiler...) working for this app.
    var helperCount = 0
    /// Path of one of its executables, used to tell macOS's own services from your programs.
    let executablePath: String
    var cpuPercent: Double
    let footprint: UInt64
    var downloadPerSecond = 0.0
    var uploadPerSecond = 0.0
    /// System services and this app itself: shown, but never offered for quitting.
    let isProtected: Bool

    var processCount: Int { pids.count }

    /// What this is, for background processes that are not apps.
    var explanation: String? {
        bundlePath == nil ? ProcessDescriptions.detail(forProcess: rawName, path: executablePath) : nil
    }

    var isSystem: Bool {
        ["/System/", "/usr/", "/sbin/", "/Library/Apple/"].contains { executablePath.hasPrefix($0) }
    }
}

/// Watches every process in the background, slowly, so memory growth over hours can be seen,
/// and quickly while a detail page is open.
@MainActor
@Observable
final class ProcessMonitor {
    static let shared = ProcessMonitor()

    private static let slowInterval: TimeInterval = 30
    private static let fastInterval: TimeInterval = 2
    private static let historyInterval: TimeInterval = 25
    private static let historyRetention: TimeInterval = 6 * 3600
    /// Below this an app is too small to matter for a leak.
    private static let minimumTrackedBytes: UInt64 = 80 * 1_048_576

    private(set) var apps: [AppUsage] = []
    private(set) var suspects: [LeakSuspect] = []
    private(set) var observingSince = Date()
    private(set) var hasNetworkData = false
    private(set) var lastMessage: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var liveCount = 0
    @ObservationIgnored private var networkCount = 0
    @ObservationIgnored private var sampling = false

    @ObservationIgnored private var previousCPU: [pid_t: (nanoseconds: UInt64, date: Date)] = [:]
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var history: [String: [MemoryPoint]] = [:]
    @ObservationIgnored private var lastHistoryDate = Date.distantPast
    @ObservationIgnored private var groups: [AppUsage] = []
    @ObservationIgnored private var networkByPid: [pid_t: (down: Double, up: Double)] = [:]
    @ObservationIgnored private var stream: NetworkTrafficStream?

    /// How long the history behind the leak check covers.
    var observedMinutes: Int { Int(Date().timeIntervalSince(observingSince) / 60) }

    // MARK: - Control

    /// Called once at launch: sample every 30 seconds for as long as the app runs.
    func start() {
        guard timer == nil else { return }
        observingSince = Date()
        sample()
        schedule(interval: Self.slowInterval)
    }

    /// A detail page is on screen: sample every 2 seconds until the matching `endLive`.
    func beginLive() {
        liveCount += 1
        if liveCount == 1 {
            schedule(interval: Self.fastInterval)
            sample()
        }
    }

    func endLive() {
        liveCount = max(liveCount - 1, 0)
        if liveCount == 0 { schedule(interval: Self.slowInterval) }
    }

    func beginNetwork() {
        networkCount += 1
        guard networkCount == 1 else { return }
        let stream = NetworkTrafficStream { [weak self] rates in
            Task { @MainActor in self?.apply(networkRates: rates) }
        }
        stream.start()
        self.stream = stream
    }

    func endNetwork() {
        networkCount = max(networkCount - 1, 0)
        guard networkCount == 0 else { return }
        stream?.stop()
        stream = nil
        networkByPid = [:]
        hasNetworkData = false
        rebuild()
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    // MARK: - Sampling

    func sample() {
        guard !sampling else { return }
        sampling = true
        Task {
            let samples = await Task.detached(priority: .utility) { ProcessSampler.sampleAll() }.value
            apply(samples, at: Date())
            sampling = false
        }
    }

    private func apply(_ samples: [ProcessSample], at date: Date) {
        var cpuByPid: [pid_t: Double] = [:]
        var current: [pid_t: (nanoseconds: UInt64, date: Date)] = [:]
        for sample in samples {
            current[sample.pid] = (sample.cpuNanoseconds, date)
            if let before = previousCPU[sample.pid], sample.cpuNanoseconds >= before.nanoseconds {
                let seconds = max(date.timeIntervalSince(before.date), 0.1)
                cpuByPid[sample.pid] = Double(sample.cpuNanoseconds - before.nanoseconds) / (seconds * 1e9) * 100
            }
        }
        previousCPU = current

        struct Accumulator {
            var name = ""
            var rawName = ""
            var bundlePath: String?
            var path = ""
            var pids: [pid_t] = []
            var helpers = 0
            var cpu = 0.0
            var footprint: UInt64 = 0
        }
        // First decide each process's own group, then fold system helpers into the app they work for.
        var ownKey: [pid_t: String] = [:]
        for sample in samples {
            ownKey[sample.pid] = ProcessSampler.appBundlePath(for: sample.path) ?? "proc:" + sample.name
        }

        var byKey: [String: Accumulator] = [:]
        for sample in samples {
            let bundle = ProcessSampler.appBundlePath(for: sample.path)
            var key = ownKey[sample.pid] ?? "proc:" + sample.name
            var isHelper = false
            if bundle == nil, sample.responsiblePID > 0,
               let ownerKey = ownKey[sample.responsiblePID], !ownerKey.hasPrefix("proc:"), ownerKey != key {
                key = ownerKey
                isHelper = true
            }

            var entry = byKey[key] ?? Accumulator()
            if entry.name.isEmpty {
                // The group is named after its app, which is the first process seen unless it was a helper.
                let groupBundle = key.hasPrefix("proc:") ? nil : key
                entry.name = displayName(key: key, bundlePath: groupBundle, fallback: sample.name)
                entry.bundlePath = groupBundle
                entry.rawName = isHelper ? (groupBundle as NSString?)?.lastPathComponent ?? sample.name : sample.name
                entry.path = isHelper ? key : sample.path
            }
            entry.pids.append(sample.pid)
            if isHelper { entry.helpers += 1 }
            entry.cpu += cpuByPid[sample.pid] ?? 0
            entry.footprint += sample.footprint
            byKey[key] = entry
        }

        let ownBundle = Bundle.main.bundlePath
        groups = byKey.map { key, entry in
            AppUsage(
                id: key,
                name: entry.name,
                rawName: entry.rawName,
                bundlePath: entry.bundlePath,
                pids: entry.pids,
                helperCount: entry.helpers,
                executablePath: entry.path,
                cpuPercent: entry.cpu,
                footprint: entry.footprint,
                isProtected: key == ownBundle || (entry.bundlePath ?? key).hasPrefix("/System/")
            )
        }
        recordHistory(at: date)
        rebuild()
    }

    private func displayName(key: String, bundlePath: String?, fallback: String) -> String {
        if let cached = names[key] { return cached }
        var name = ProcessDescriptions.displayName(for: fallback)
        if let bundlePath {
            name = FileManager.default.displayName(atPath: bundlePath)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        names[key] = name
        return name
    }

    // MARK: - Network

    private func apply(networkRates: [pid_t: (down: Double, up: Double)]) {
        networkByPid = networkRates
        hasNetworkData = true
        rebuild()
    }

    private func rebuild() {
        apps = groups.map { group in
            var app = group
            for pid in group.pids {
                if let rate = networkByPid[pid] {
                    app.downloadPerSecond += rate.down
                    app.uploadPerSecond += rate.up
                }
            }
            return app
        }
    }

    // MARK: - Leak history

    private func recordHistory(at date: Date) {
        let now = date.timeIntervalSince1970
        if date.timeIntervalSince(lastHistoryDate) >= Self.historyInterval {
            lastHistoryDate = date
            for group in groups where group.footprint >= Self.minimumTrackedBytes {
                history[group.id, default: []].append(
                    MemoryPoint(time: now, bytes: group.footprint, processCount: group.processCount)
                )
            }
            let cutoff = now - Self.historyRetention
            for key in Array(history.keys) {
                history[key]?.removeAll { $0.time < cutoff }
                // Drop apps that have not been seen for a while, e.g. quit and never reopened.
                if let last = history[key]?.last, now - last.time > 7200 { history[key] = nil }
                if history[key]?.isEmpty == true { history[key] = nil }
            }
            refreshSuspects()
        }
    }

    private func refreshSuspects() {
        let live = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var found: [LeakSuspect] = []
        for (key, points) in history {
            guard let app = live[key], let finding = LeakDetector.analyze(points) else { continue }
            let window = points.filter { $0.time >= (points.last?.time ?? 0) - LeakDetector.window }
            let startCount = window.first?.processCount ?? app.processCount
            found.append(LeakSuspect(
                id: key,
                name: app.name,
                level: finding.level,
                currentBytes: app.footprint,
                growthBytes: finding.growthBytes,
                bytesPerHour: finding.bytesPerHour,
                observedMinutes: finding.observedMinutes,
                processCount: app.processCount,
                processCountGrew: Double(app.processCount) > Double(startCount) * 1.3 + 1
            ))
        }
        suspects = found.sorted { ($0.level.rawValue, $0.bytesPerHour) > ($1.level.rawValue, $1.bytesPerHour) }
    }

    // MARK: - Quitting

    /// Asks the app to quit politely, or kills it. Returns a message when something could not be done.
    @discardableResult
    func quit(_ app: AppUsage, force: Bool) -> String? {
        guard !app.isProtected else { return "「\(app.name)」是系统自带或本应用自己,不能在这里结束" }

        var failures = 0
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let path = app.bundlePath else { return false }
            return $0.bundleURL?.path == path
        }
        if running.isEmpty {
            for pid in app.pids where kill(pid, force ? SIGKILL : SIGTERM) != 0 { failures += 1 }
        } else {
            for application in running {
                if force { _ = application.forceTerminate() } else { _ = application.terminate() }
            }
            if force {
                for pid in app.pids { _ = kill(pid, SIGKILL) }
            }
        }

        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            sample()
        }
        if failures > 0 { return "有 \(failures) 个进程没有权限结束" }
        return nil
    }

    /// Terminal command that checks one app for leaked objects.
    func leaksCommand(for app: AppUsage) -> String {
        guard let pid = app.pids.first else { return "" }
        return "leaks \(pid)"
    }
}

/// Reads per-process network traffic from `nettop`, which works without administrator rights.
///
/// `nettop` buffers its output when it is not writing to a terminal, so a long-running instance would not
/// report anything for ages. Instead it is run for two samples at a time and exits, which flushes it.
final class NetworkTrafficStream: @unchecked Sendable {
    private static let interval = 2.0

    private let lock = NSLock()
    private var running = false
    private var process: Process?
    private let onRates: @Sendable ([pid_t: (down: Double, up: Double)]) -> Void

    init(onRates: @escaping @Sendable ([pid_t: (down: Double, up: Double)]) -> Void) {
        self.onRates = onRates
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                if let rates = self.measure() { self.onRates(rates) }
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        process?.terminate()
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// One pass: two samples, of which the second holds the bytes moved during the interval.
    private func measure() -> [pid_t: (down: Double, up: Double)]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P one line per process, -d bytes since the previous sample, -x plain numbers, -L 2 two samples.
        task.arguments = ["-P", "-d", "-L", "2", "-s", "\(Int(Self.interval))", "-J", "bytes_in,bytes_out", "-x"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        lock.lock()
        guard running else { lock.unlock(); return nil }
        process = task
        lock.unlock()

        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Self.lastBlock(in: String(decoding: data, as: UTF8.self))
    }

    private static func lastBlock(in text: String) -> [pid_t: (down: Double, up: Double)]? {
        var blocks: [[pid_t: (down: Double, up: Double)]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix(",") {
                blocks.append([:])
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard blocks.isEmpty == false,
                  fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let received = Double(fields[1]),
                  let sent = Double(fields[2])
            else { continue }
            blocks[blocks.count - 1][pid] = (received / interval, sent / interval)
        }
        // The first block is totals since boot; only the second is a rate.
        return blocks.count >= 2 ? blocks[blocks.count - 1] : nil
    }
}
