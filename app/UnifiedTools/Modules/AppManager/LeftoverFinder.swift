import Foundation

struct Leftover: Identifiable {
    let url: URL
    /// What kind of file this is, in plain words.
    let label: String
    /// Found by the app's name rather than its identifier, so it might belong to something else.
    let matchedByName: Bool
    /// Lives outside the home folder, so removing it asks for the administrator password.
    let needsAdmin: Bool
    let note: String?

    var id: URL { url }

    /// Identifier matches are ticked for you; guesses and shared data are not.
    var defaultSelected: Bool { !matchedByName && note == nil }
}

enum LeftoverFinder {
    private static let userFolders: [(path: String, label: String)] = [
        ("Application Support", "应用数据"),
        ("Caches", "缓存"),
        ("Preferences", "偏好设置"),
        ("Preferences/ByHost", "偏好设置"),
        ("Containers", "沙盒数据"),
        ("Application Scripts", "沙盒脚本"),
        ("Saved Application State", "窗口状态"),
        ("Logs", "日志"),
        ("HTTPStorages", "网络数据"),
        ("WebKit", "网络数据"),
        ("Cookies", "网络数据"),
        ("LaunchAgents", "后台启动项"),
    ]

    private static let systemFolders: [(path: String, label: String)] = [
        ("/Library/Application Support", "应用数据(系统级)"),
        ("/Library/Caches", "缓存(系统级)"),
        ("/Library/Preferences", "偏好设置(系统级)"),
        ("/Library/LaunchAgents", "后台启动项(系统级)"),
        ("/Library/LaunchDaemons", "后台守护进程(系统级)"),
        ("/Library/PrivilegedHelperTools", "特权助手(系统级)"),
    ]

    /// Everything the app left behind that can be found from its identifiers and name.
    nonisolated static func find(for app: InstalledApp, among apps: [InstalledApp]) -> [Leftover] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")

        let ids = [app.bundleID] + app.helperIDs
        let systemIDs = ids + app.helperLabels
        let others = apps.filter { $0.url != app.url }
        let otherIDs = others.flatMap { [$0.bundleID] + $0.helperIDs }

        var results: [Leftover] = []
        var seen = Set<String>()

        func add(_ url: URL, label: String, byName: Bool = false, admin: Bool = false, note: String? = nil) {
            guard fileManager.fileExists(atPath: url.path), seen.insert(url.path).inserted else { return }
            results.append(Leftover(url: url, label: label, matchedByName: byName, needsAdmin: admin, note: note))
        }

        /// `com.foo.Bar` owns `com.foo.Bar.plist`, but not `com.foo.Bar.Pro.plist` when Bar Pro is installed too.
        func isOwned(_ name: String, by identifiers: [String]) -> Bool {
            identifiers.contains { id in
                guard name == id || name.hasPrefix(id + ".") else { return false }
                return !otherIDs.contains { other in
                    other.count > id.count && other.hasPrefix(id + ".") && (name == other || name.hasPrefix(other + "."))
                }
            }
        }

        for (path, label) in userFolders {
            let directory = library.appendingPathComponent(path)
            for name in names(in: directory) where isOwned(name, by: ids) {
                add(directory.appendingPathComponent(name), label: label)
            }
        }
        for (path, label) in systemFolders {
            let directory = URL(fileURLWithPath: path)
            for name in names(in: directory) where isOwned(name, by: systemIDs) {
                add(directory.appendingPathComponent(name), label: label, admin: true)
            }
        }

        for group in app.appGroups {
            let sharer = others.first { $0.appGroups.contains(group) }
            let note = sharer.map { "与「\($0.name)」共用" }
            add(library.appendingPathComponent("Group Containers/\(group)"), label: "共享数据", note: note)
            add(library.appendingPathComponent("Application Scripts/\(group)"), label: "沙盒脚本", note: note)
        }
        for container in app.iCloudContainers {
            let folder = container.replacingOccurrences(of: ".", with: "~")
            add(
                library.appendingPathComponent("Mobile Documents/\(folder)"),
                label: "iCloud 数据",
                note: "删除后会同步到你所有设备"
            )
        }

        let fileName = app.url.deletingPathExtension().lastPathComponent
        for name in Set([app.name, fileName]) where name.count >= 3 {
            add(library.appendingPathComponent("Application Support/\(name)"), label: "应用数据", byName: true)
            add(library.appendingPathComponent("Caches/\(name)"), label: "缓存", byName: true)
            add(library.appendingPathComponent("Logs/\(name)"), label: "日志", byName: true)
            add(URL(fileURLWithPath: "/Library/Application Support/\(name)"), label: "应用数据(系统级)", byName: true, admin: true)

            let slug = name.lowercased().replacingOccurrences(of: " ", with: "")
            let hiddenNote = "隐藏目录,可能含你自己的数据(模型、镜像等),确认后再勾选"
            add(home.appendingPathComponent(".\(slug)"), label: "隐藏目录", byName: true, note: hiddenNote)
            add(home.appendingPathComponent(".config/\(slug)"), label: "隐藏目录", byName: true, note: hiddenNote)
            add(home.appendingPathComponent(".cache/\(slug)"), label: "隐藏目录", byName: true, note: hiddenNote)
        }

        return results.sorted { ($0.label, $0.url.path) < ($1.label, $1.url.path) }
    }

    private nonisolated static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
