import AppKit

struct RemovalResult {
    var movedCount = 0
    var failures: [(path: String, reason: String)] = []

    var summary: String {
        var text = "已移到废纸篓:\(movedCount) 项。"
        if !failures.isEmpty {
            text += "\n\n没能处理的 \(failures.count) 项:\n"
            text += failures.prefix(8).map { "• \($0.path)\n   \($0.reason)" }.joined(separator: "\n")
            if failures.count > 8 { text += "\n…另有 \(failures.count - 8) 项" }
        }
        return text
    }
}

/// Moves an app and the chosen leftovers to the Trash. Nothing is deleted outright.
@MainActor
enum AppRemover {
    static func remove(app: InstalledApp, leftovers: [Leftover], resetPrivacy: Bool) async -> RemovalResult {
        var result = RemovalResult()
        await quit(app)

        let items = [app.url] + leftovers.map(\.url)
        stopLaunchAgents(in: items)

        // Ordinary files go to the Trash directly; anything that needs more rights is batched below.
        var needsAdmin: [URL] = []
        for url in items {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                result.movedCount += 1
            } catch {
                if isPermissionError(error) {
                    needsAdmin.append(url)
                } else {
                    result.failures.append((url.path, error.localizedDescription))
                }
            }
        }

        if !needsAdmin.isEmpty {
            moveWithAdministratorPrivileges(needsAdmin, appName: app.name, into: &result)
        }

        if resetPrivacy {
            for id in [app.bundleID] + app.helperIDs {
                runQuietly("/usr/bin/tccutil", ["reset", "All", id])
            }
        }
        return result
    }

    // MARK: - Quitting

    private static func quit(_ app: InstalledApp) async {
        let ids = [app.bundleID] + app.helperIDs
        let running = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard !running.isEmpty else { return }

        running.forEach { $0.terminate() }
        for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Unload user launch agents first, otherwise launchd keeps restarting the helper.
    private static func stopLaunchAgents(in urls: [URL]) {
        let uid = getuid()
        for url in urls where url.path.contains("/LaunchAgents/") && url.pathExtension == "plist" {
            runQuietly("/bin/launchctl", ["bootout", "gui/\(uid)", url.path])
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return [Int(EPERM), Int(EACCES)].contains(underlying.code)
        }
        return false
    }

    // MARK: - Administrator step

    /// One password prompt for the whole batch. The system dialog asks the user; this app never sees the password.
    private static func moveWithAdministratorPrivileges(_ urls: [URL], appName: String, into result: inout RemovalResult) {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = NSHomeDirectory() + "/.Trash/UnifiedTools-removed-\(stamp)"
        let user = NSUserName()

        var commands = ["/bin/mkdir -p \(quote(destination))"]
        for (index, url) in urls.enumerated() {
            let folder = "\(destination)/\(index)"
            if url.path.hasPrefix("/Library/LaunchDaemons/") {
                commands.append("/bin/launchctl bootout system \(quote(url.path)) >/dev/null 2>&1")
            }
            commands.append("/bin/mkdir -p \(quote(folder))")
            commands.append("/bin/mv -- \(quote(url.path)) \(quote(folder + "/")) >/dev/null 2>&1 || echo \(quote("FAIL:" + url.path))")
        }
        // Hand the moved files to the user so emptying the Trash later needs no password.
        commands.append("/usr/sbin/chown -R \(quote(user)) \(quote(destination)) >/dev/null 2>&1")
        let shell = commands.joined(separator: "; ")

        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"UnifiedTools 需要管理员权限,把「\(appName)」的系统级文件移到废纸篓\""

        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "已取消或没有权限"
            for url in urls {
                result.failures.append((url.path, message))
            }
            return
        }

        let failed = (output?.stringValue ?? "")
            .split(separator: "\n")
            .filter { $0.hasPrefix("FAIL:") }
            .map { String($0.dropFirst(5)) }
        for url in urls {
            if failed.contains(url.path) {
                result.failures.append((url.path, "被 macOS 保护。请在 Finder 里手动删除,或给本应用“完全磁盘访问权限”"))
            } else {
                result.movedCount += 1
            }
        }
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runQuietly(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
