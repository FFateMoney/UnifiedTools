import Foundation

/// Plain-language names and explanations for background processes that have no app of their own,
/// so a row like `com.apple.CoreSimulator.CoreSimulatorService` tells you what it is.
enum ProcessDescriptions {
    private struct Entry {
        let match: String
        let name: String
        let detail: String
    }

    // Longer, more specific matches first.
    private static let known: [Entry] = [
        Entry(match: "CoreSimulatorService", name: "iOS 模拟器服务", detail: "Xcode 的 iOS 模拟器后台服务。Xcode、xcodebuild 或模拟器用到时自动启动,退出没有影响,下次用到会重新启动。"),
        Entry(match: "CoreSimulator", name: "iOS 模拟器组件", detail: "Xcode 模拟器的辅助进程,模拟器运行时才会出现。"),
        Entry(match: "MTLCompilerService", name: "Metal 着色器编译", detail: "给图形程序编译 GPU 着色器。有软件用到图形时自动出现,空闲后会自己退出,出现很多个是正常的。"),
        Entry(match: "com.apple.WebKit.WebContent", name: "网页内容(WebKit)", detail: "用 Safari 内核显示网页的进程。Safari 和很多自带网页界面的应用都会开。"),
        Entry(match: "com.apple.WebKit.Networking", name: "网页联网(WebKit)", detail: "WebKit 网页的联网进程。"),
        Entry(match: "com.apple.WebKit.GPU", name: "网页图形(WebKit)", detail: "WebKit 网页的图形渲染进程。"),
        Entry(match: "SetStoreUpdateService", name: "App 商店更新服务", detail: "App Store 检查和下载应用更新的后台服务,会同时开多个。"),
        Entry(match: "mdworker", name: "聚焦索引(Spotlight)", detail: "给文件建搜索索引。新装软件或大量改动文件后会短时间占用较多处理器,之后自己安静下来。"),
        Entry(match: "mds", name: "聚焦索引(Spotlight)", detail: "Spotlight 搜索的索引服务。"),
        Entry(match: "XProtect", name: "系统恶意软件防护", detail: "macOS 内置的恶意软件检测,会在你打开新程序时检查。"),
        Entry(match: "AMPDeviceDiscoveryAgent", name: "设备发现(iPhone/iPad)", detail: "发现接入的 iPhone、iPad,用于访达或音乐里的同步。"),
        Entry(match: "shazameventsd", name: "Shazam 事件服务", detail: "音乐识别功能的后台服务。"),
        Entry(match: "CredentialProviderExtension", name: "密码自动填充扩展", detail: "为网页和应用提供密码自动填充。"),
        Entry(match: "VTEncoderXPCService", name: "视频编码服务", detail: "系统的视频编码(录屏、剪辑、通话)用到的后台服务。"),
        Entry(match: "assistant_service", name: "Siri 与听写后台服务", detail: "Siri、听写、快捷指令等的后台服务。"),
        Entry(match: "nsurlsessiond", name: "后台下载服务", detail: "系统替应用在后台下载文件。"),
        Entry(match: "node", name: "Node.js 程序", detail: "用 Node.js 运行的程序,常见于开发工具、脚本和某些应用的后台。"),
        Entry(match: "python", name: "Python 程序", detail: "用 Python 运行的脚本或工具。"),
        Entry(match: "claude", name: "Claude Code", detail: "Claude Code 命令行程序。"),
    ]

    /// A friendlier title than the raw process name, or the raw name when nothing is known.
    static func displayName(for processName: String) -> String {
        entry(for: processName)?.name ?? processName
    }

    /// One line shown under the name. Falls back to a guess from where the program lives.
    static func detail(forProcess name: String, path: String) -> String? {
        if let entry = entry(for: name) { return entry.detail }
        if path.hasPrefix("/Library/Developer/") || path.contains("/Xcode.app/") {
            return "开发工具(Xcode)的后台服务。"
        }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return "用 Homebrew 或手动安装的程序。"
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") {
            return "macOS 自带的系统服务。"
        }
        if path.hasPrefix(NSHomeDirectory()) {
            return "你的用户目录里的程序:\(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        }
        return nil
    }

    private static func entry(for name: String) -> Entry? {
        known.first { name.localizedCaseInsensitiveContains($0.match) }
    }
}
