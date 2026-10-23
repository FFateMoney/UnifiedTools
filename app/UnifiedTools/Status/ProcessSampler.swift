import Darwin
import Foundation

/// One process at one moment.
struct ProcessSample: Sendable {
    let pid: pid_t
    let path: String
    let name: String
    /// What Activity Monitor calls "Memory": private plus compressed pages this process is responsible for.
    let footprint: UInt64
    /// Total user + system CPU time the process has used so far, in nanoseconds.
    let cpuNanoseconds: UInt64
}

enum ProcessSampler {
    private nonisolated static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Every process whose resource usage this user is allowed to read, which is all of the user's own
    /// processes. System daemons owned by root are not readable without root and are left out.
    nonisolated static func sampleAll() -> [ProcessSample] {
        let bufferBytes = proc_listallpids(nil, 0)
        guard bufferBytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferBytes) / MemoryLayout<pid_t>.size + 64)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }

        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN) * 4)
        defer { pathBuffer.deallocate() }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(Int(written))
        for pid in pids.prefix(Int(written)) where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }

            let pathLength = proc_pidpath(pid, pathBuffer, UInt32(Int(MAXPATHLEN) * 4))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            let name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent

            let ticks = usage.ri_user_time &+ usage.ri_system_time
            samples.append(ProcessSample(
                pid: pid,
                path: path,
                name: name,
                footprint: usage.ri_phys_footprint,
                cpuNanoseconds: ticks &* timebase.numer / timebase.denom
            ))
        }
        return samples
    }

    /// The outermost `.app` bundle a path lives in, so Chrome's helper processes count toward Chrome.
    nonisolated static func appBundlePath(for path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }
}
