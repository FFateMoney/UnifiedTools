import Darwin
import Foundation
import IOKit
import IOKit.ps

// IOHID's temperature sensors have no public header. These symbols are exported by IOKit and are what
// system-monitor apps use to read the Apple Silicon die temperature without root.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: UnsafeRawPointer, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: UnsafeRawPointer, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: UnsafeMutableRawPointer, _ field: Int32) -> Double

struct MemoryInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed and purgeable pages: kept only as a cache, so macOS can drop them instantly.
    var cached: UInt64 = 0
    /// How big the compressed pages would be if they were not compressed.
    var compressedOriginal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical.
    var pressure = 1

    var used: UInt64 { app + wired + compressed }
    /// Memory nothing is using at all.
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    /// What a new program can get without anything being pushed to disk.
    var available: UInt64 { free + cached }
    var compressionSaved: UInt64 { compressedOriginal > compressed ? compressedOriginal - compressed : 0 }
}

struct BatteryInfo {
    var percent = 0
    var isCharging = false
    var onAC = false
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// Current full capacity as a share of the design capacity.
    var healthPercent: Int?
    var temperature: Double?
    var adapterWatts: Int?
}

struct TemperatureSensor: Identifiable {
    let name: String
    let celsius: Double
    var id: String { name }
}

enum SystemStats {
    // MARK: - CPU

    nonisolated static func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return (UInt64(ticks.0), UInt64(ticks.1), UInt64(ticks.2), UInt64(ticks.3))
    }

    // MARK: - Memory

    nonisolated static func memory() -> MemoryInfo {
        var memory = MemoryInfo()
        memory.total = ProcessInfo.processInfo.physicalMemory

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            memory.app = UInt64(statistics.internal_page_count &- statistics.purgeable_count) * page
            memory.wired = UInt64(statistics.wire_count) * page
            memory.compressed = UInt64(statistics.compressor_page_count) * page
            memory.cached = UInt64(statistics.external_page_count &+ statistics.purgeable_count) * page
            memory.compressedOriginal = UInt64(statistics.total_uncompressed_pages_in_compressor) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            memory.swapUsed = swap.xsu_used
            memory.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            memory.pressure = Int(level)
        }
        return memory
    }

    // MARK: - Storage

    nonisolated static func storage() -> (total: Int64, available: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (Int64(total), available)
    }

    // MARK: - Network

    /// Raw 32-bit interface counters summed over Wi-Fi and Ethernet; callers take differences.
    nonisolated static func networkCounters() -> (received: UInt32, sent: UInt32) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }

        var received: UInt32 = 0
        var sent: UInt32 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    let counters = data.assumingMemoryBound(to: if_data.self).pointee
                    received = received &+ counters.ifi_ibytes
                    sent = sent &+ counters.ifi_obytes
                }
            }
            cursor = interface.ifa_next
        }
        return (received, sent)
    }

    // MARK: - GPU

    nonisolated static func gpuUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
                  let utilization = statistics["Device Utilization %"] as? Int
            else { continue }
            best = max(best ?? 0, utilization)
        }
        return best
    }

    // MARK: - Battery

    nonisolated static func battery() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int
        else { return nil }

        var battery = BatteryInfo()
        battery.percent = capacity
        battery.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        battery.onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
            battery.minutesRemaining = minutes
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                battery.cycleCount = dictionary["CycleCount"] as? Int
                // Recent macOS keeps the capacities inside "BatteryData".
                let data = dictionary["BatteryData"] as? [String: Any] ?? [:]
                let design = (dictionary["DesignCapacity"] ?? data["DesignCapacity"]) as? Int
                let full = (dictionary["NominalChargeCapacity"] ?? data["NominalChargeCapacity"] ?? dictionary["AppleRawMaxCapacity"]) as? Int
                if let design, design > 0, let full {
                    battery.healthPercent = Int((Double(full) / Double(design) * 100).rounded())
                }
                if let centi = dictionary["Temperature"] as? Int {
                    battery.temperature = Double(centi) / 100
                }
                if let adapter = dictionary["AdapterDetails"] as? [String: Any] {
                    battery.adapterWatts = adapter["Watts"] as? Int
                }
            }
        }
        return battery
    }

    // MARK: - Temperature

    private nonisolated(unsafe) static var hidClient: UnsafeMutableRawPointer?
    private nonisolated(unsafe) static var hidServices: CFArray?
    private nonisolated(unsafe) static var chosenSensors: [(name: String, service: UnsafeRawPointer)] = []

    /// A few die and board temperature sensors (Apple Silicon). Empty when the Mac exposes none.
    ///
    /// Reading one sensor costs about a millisecond and there are over forty, so the set is narrowed once to
    /// ten spread-out die sensors plus the SSD and battery, and the services are kept for later calls.
    nonisolated static func temperatures() -> [TemperatureSensor] {
        if hidClient == nil {
            chooseSensors()
        }
        var sensors: [TemperatureSensor] = []
        for (name, service) in chosenSensors {
            guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else { continue }
            let celsius = IOHIDEventGetFloatValue(event, 15 << 16)
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            if celsius > 0 && celsius < 150 {
                sensors.append(TemperatureSensor(name: name, celsius: celsius))
            }
        }
        return sensors
    }

    private nonisolated static func chooseSensors() {
        hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        guard let client = hidClient else { return }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() else { return }
        hidServices = services   // keeps every service pointer below valid

        var named: [(name: String, service: UnsafeRawPointer)] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            else { continue }
            named.append((name, service))
        }

        let dies = named.filter { $0.name.contains("tdie") }.sorted { $0.name < $1.name }
        let stride = max(dies.count / 10, 1)
        var chosen = dies.enumerated().filter { $0.offset % stride == 0 }.prefix(10).map(\.element)
        if let nand = named.first(where: { $0.name.contains("NAND") }) { chosen.append(nand) }
        chosen.append(contentsOf: named.filter { $0.name.contains("gas gauge") }.prefix(2))
        chosenSensors = chosen
    }

    // MARK: - Machine

    nonisolated static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
