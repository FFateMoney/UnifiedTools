import Foundation

struct MemoryPoint: Sendable {
    let time: TimeInterval
    let bytes: UInt64
    var processCount = 1
}

struct LeakSuspect: Identifiable, Sendable {
    enum Level: Int, Sendable {
        /// Growing steadily, worth keeping an eye on.
        case watch = 1
        /// Growing fast and without ever giving anything back.
        case likely = 2
    }

    let id: String
    let name: String
    let level: Level
    let currentBytes: UInt64
    let growthBytes: Int64
    let bytesPerHour: Double
    let observedMinutes: Int
    /// Browsers and Electron apps grow when you open more tabs or windows, which is not a leak.
    let processCount: Int
    let processCountGrew: Bool
}

/// macOS cannot tell you "this app leaks". What can be seen from outside is an app whose memory keeps
/// climbing for a long time and never comes back down, which is how a leak looks. This finds those.
enum LeakDetector {
    struct Finding: Sendable {
        let level: LeakSuspect.Level
        let bytesPerHour: Double
        let growthBytes: Int64
        let observedMinutes: Int
    }

    /// Don't judge anything seen for less than this: start-up growth looks exactly like a leak.
    nonisolated static let minimumObservation: TimeInterval = 30 * 60
    /// Only the most recent stretch counts, so an old leak that was fixed by a restart is forgotten.
    nonisolated static let window: TimeInterval = 3 * 3600

    nonisolated static func analyze(_ history: [MemoryPoint]) -> Finding? {
        guard let last = history.last else { return nil }
        let points = history.filter { $0.time >= last.time - window }
        guard points.count >= 12, let first = points.first else { return nil }
        let span = last.time - first.time
        guard span >= minimumObservation else { return nil }

        let megabytes = points.map { Double($0.bytes) / 1_048_576 }
        let hours = points.map { ($0.time - first.time) / 3600 }

        // Least-squares line through the samples.
        let count = Double(points.count)
        let meanX = hours.reduce(0, +) / count
        let meanY = megabytes.reduce(0, +) / count
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for index in points.indices {
            covariance += (hours[index] - meanX) * (megabytes[index] - meanY)
            varianceX += (hours[index] - meanX) * (hours[index] - meanX)
            varianceY += (megabytes[index] - meanY) * (megabytes[index] - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        let slope = covariance / varianceX
        let rSquared = covariance * covariance / (varianceX * varianceY)
        guard slope > 0 else { return nil }

        // Compare averages of the first and last few samples so one spike does not decide.
        let edge = max(points.count / 6, 2)
        let startAverage = megabytes.prefix(edge).reduce(0, +) / Double(edge)
        let endAverage = megabytes.suffix(edge).reduce(0, +) / Double(edge)
        let growth = endAverage - startAverage

        // A big drop means the app gave memory back, which a leak never does.
        var peak = megabytes[0]
        var deepestDrop = 0.0
        for value in megabytes {
            peak = max(peak, value)
            deepestDrop = max(deepestDrop, (peak - value) / max(peak, 1))
        }
        guard deepestDrop <= 0.12 else { return nil }

        var steps = 0, nonDecreasing = 0
        for index in 1..<megabytes.count {
            steps += 1
            if megabytes[index] >= megabytes[index - 1] * 0.99 { nonDecreasing += 1 }
        }
        let monotonic = Double(nonDecreasing) / Double(steps)

        let level: LeakSuspect.Level
        if slope >= 100, growth >= 250, monotonic >= 0.8, rSquared >= 0.6 {
            level = .likely
        } else if slope >= 40, growth >= 100, monotonic >= 0.7, rSquared >= 0.5 {
            level = .watch
        } else {
            return nil
        }
        return Finding(
            level: level,
            bytesPerHour: slope * 1_048_576,
            growthBytes: Int64(growth * 1_048_576),
            observedMinutes: Int(span / 60)
        )
    }

    /// What to try, most useful first. `isBrowserLike` is true for apps made of many processes.
    nonisolated static func advice(for suspect: LeakSuspect, isBrowserLike: Bool) -> [String] {
        var steps = [
            "先把它正常退出再重新打开。泄漏的内存只要进程结束就会被系统全部收回,这是最直接有效的办法。",
        ]
        if isBrowserLike || suspect.processCountGrew {
            steps.append("它由很多进程组成,内存涨可能只是开了更多标签页或窗口,不一定是泄漏。关掉不用的标签页和窗口,再看是否还在涨。")
            steps.append("在浏览器里禁用不常用的扩展,扩展是常见的内存增长来源。")
        }
        steps.append("把它更新到最新版本,很多泄漏问题在新版本里已经修复。")
        steps.append("如果重启之后过一两个小时又涨回来,说明是应用本身的问题:向开发者反馈,或者暂时换一个替代软件。")
        steps.append("想进一步确认,可以在终端用 leaks 命令检查它(见下方“复制命令”),它会列出真正泄漏的对象;系统自带的 Instruments 里的 Leaks 工具也能做。")
        return steps
    }
}
