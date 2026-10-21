import Foundation
import Observation

/// Samples the machine every two seconds while the overview page is on screen.
@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    private static let historyLength = 60
    private static let interval: TimeInterval = 2

    private struct Snapshot: Sendable {
        let date = Date()
        let ticks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
        let network: (received: UInt32, sent: UInt32)
        let memory: MemoryInfo
        let storage: (total: Int64, available: Int64)?
        let gpu: Int?
        let battery: BatteryInfo?
        let sensors: [TemperatureSensor]
    }

    // Machine
    let chip = SystemStats.sysctlString("machdep.cpu.brand_string")
    let model = SystemStats.sysctlString("hw.model")
    let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    // Live values
    private(set) var cpuPercent = 0.0
    private(set) var cpuUserPercent = 0.0
    private(set) var cpuSystemPercent = 0.0
    private(set) var cpuHistory: [Double] = []

    private(set) var memory = MemoryInfo()
    private(set) var memoryHistory: [Double] = []

    private(set) var storageTotal: Int64 = 0
    private(set) var storageAvailable: Int64 = 0

    private(set) var downloadSpeed = 0.0
    private(set) var uploadSpeed = 0.0
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    private(set) var gpuPercent: Int?
    private(set) var gpuHistory: [Double] = []

    private(set) var battery: BatteryInfo?
    private(set) var sensors: [TemperatureSensor] = []
    private(set) var thermalState = ProcessInfo.ThermalState.nominal
    private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previous: Snapshot?
    @ObservationIgnored private var sampling = false

    // MARK: - Derived temperatures

    /// The CPU/SoC die sensors; "tcal" is a calibration reading, not a temperature of anything.
    var dieTemperatures: [Double] {
        sensors.filter { $0.name.contains("tdie") }.map(\.celsius)
    }

    var batteryTemperature: Double? {
        if let reading = battery?.temperature { return reading }
        let readings = sensors.filter { $0.name.contains("gas gauge") }.map(\.celsius)
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    var storageTemperature: Double? {
        sensors.first { $0.name.contains("NAND") }?.celsius
    }

    // MARK: - Control

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Snapshot(
                    ticks: SystemStats.cpuTicks(),
                    network: SystemStats.networkCounters(),
                    memory: SystemStats.memory(),
                    storage: SystemStats.storage(),
                    gpu: SystemStats.gpuUtilization(),
                    battery: SystemStats.battery(),
                    sensors: SystemStats.temperatures()
                )
            }.value
            apply(snapshot)
            sampling = false
        }
    }

    private func apply(_ snapshot: Snapshot) {
        if let previous {
            if let now = snapshot.ticks, let before = previous.ticks {
                let user = Double(now.user &- before.user + (now.nice &- before.nice))
                let system = Double(now.system &- before.system)
                let idle = Double(now.idle &- before.idle)
                let total = user + system + idle
                if total > 0 {
                    cpuUserPercent = user / total * 100
                    cpuSystemPercent = system / total * 100
                    cpuPercent = cpuUserPercent + cpuSystemPercent
                }
            }
            let seconds = max(snapshot.date.timeIntervalSince(previous.date), 0.5)
            // The counters are 32-bit and wrap, so subtract with wrapping arithmetic.
            downloadSpeed = Double(snapshot.network.received &- previous.network.received) / seconds
            uploadSpeed = Double(snapshot.network.sent &- previous.network.sent) / seconds
        }
        previous = snapshot

        memory = snapshot.memory
        if let storage = snapshot.storage {
            storageTotal = storage.total
            storageAvailable = storage.available
        }
        gpuPercent = snapshot.gpu
        battery = snapshot.battery
        sensors = snapshot.sensors
        thermalState = ProcessInfo.processInfo.thermalState
        uptime = ProcessInfo.processInfo.systemUptime

        append(&cpuHistory, cpuPercent)
        append(&memoryHistory, memory.total > 0 ? Double(memory.used) / Double(memory.total) * 100 : 0)
        append(&downloadHistory, downloadSpeed)
        append(&uploadHistory, uploadSpeed)
        if let gpu = snapshot.gpu {
            append(&gpuHistory, Double(gpu))
        }
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}
