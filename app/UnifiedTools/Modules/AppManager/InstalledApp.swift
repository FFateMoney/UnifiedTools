import AppKit
import CoreServices
import Security

struct InstalledApp: Identifiable, Hashable {
    enum Source: String {
        case appStore = "App Store"
        case other = "其他"
    }

    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let source: Source
    let lastUsed: Date?
    /// Apps that must not be removed from here: this app itself and Apple's own non-App-Store apps.
    let isProtected: Bool
    /// Bundle ids of login-item helpers, extensions and XPC services shipped inside the app.
    let helperIDs: [String]
    /// Launchd labels of privileged helpers the app installs system-wide.
    let helperLabels: [String]
    let appGroups: [String]
    let iCloudContainers: [String]

    var id: URL { url }
}

enum AppScanner {
    /// Every .app under /Applications and ~/Applications, down to one level of subfolder.
    nonisolated static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        var found: [InstalledApp] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    if let app = makeApp(at: url) { found.append(app) }
                } else if enumerator.level >= 2 {
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    private nonisolated static func makeApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let fileManager = FileManager.default
        let info = bundle.infoDictionary ?? [:]

        var name = fileManager.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }

        let hasReceipt = fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
        let entitlements = entitlements(of: url)
        let privileged = (info["SMPrivilegedExecutables"] as? [String: Any])?.keys.map { $0 } ?? []
        let launchServices = (try? fileManager.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Library/LaunchServices").path)) ?? []

        return InstalledApp(
            url: url,
            name: name,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            source: hasReceipt ? .appStore : .other,
            lastUsed: lastUsedDate(of: url),
            isProtected: bundleID == Bundle.main.bundleIdentifier || (bundleID.hasPrefix("com.apple.") && !hasReceipt),
            helperIDs: nestedBundleIDs(in: url),
            helperLabels: Array(Set(privileged + launchServices.filter { !$0.hasPrefix(".") })),
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [],
            iCloudContainers: entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        )
    }

    private nonisolated static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private nonisolated static func nestedBundleIDs(in app: URL) -> [String] {
        let fileManager = FileManager.default
        let folders = ["Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices"]
        var ids: [String] = []
        for folder in folders {
            let directory = app.appendingPathComponent(folder)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                if let id = Bundle(url: directory.appendingPathComponent(name))?.bundleIdentifier {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private nonisolated static func entitlements(of url: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [:] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return [:] }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }
}

enum DiskUsage {
    /// Allocated size of a file or folder, via `du`, which handles huge trees quickly.
    nonisolated static func bytes(of url: URL) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.split(whereSeparator: \.isWhitespace).first, let kilobytes = Int64(first) else { return 0 }
        return kilobytes * 1024
    }
}
