import Foundation
import Observation

@MainActor
@Observable
final class AppManagerModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case appStore = "App Store"
        case other = "其他来源"
        case stale = "90 天没用过"

        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case size = "按大小"
        case lastUsed = "按最后使用"
        case name = "按名称"

        var id: String { rawValue }
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var sizes: [URL: Int64] = [:]
    private(set) var isScanning = false

    var query = ""
    var filter = Filter.all
    var sort = SortKey.size
    var selection: URL?

    private(set) var leftovers: [Leftover] = []
    private(set) var leftoverSizes: [URL: Int64] = [:]
    private(set) var isLoadingLeftovers = false
    var checked: Set<URL> = []
    var resetPrivacy = true

    private(set) var isRemoving = false
    var resultMessage: String?

    @ObservationIgnored private var leftoverTask: Task<Void, Never>?

    var selectedApp: InstalledApp? {
        apps.first { $0.url == selection }
    }

    var visibleApps: [InstalledApp] {
        let staleLimit = Date().addingTimeInterval(-90 * 24 * 3600)
        var list = apps.filter { app in
            let matchesQuery = query.isEmpty
                || app.name.localizedCaseInsensitiveContains(query)
                || app.bundleID.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            switch filter {
            case .all: return true
            case .appStore: return app.source == .appStore
            case .other: return app.source == .other
            case .stale: return app.lastUsed.map { $0 < staleLimit } ?? true
            }
        }
        switch sort {
        case .size:
            list.sort { (sizes[$0.url] ?? 0) > (sizes[$1.url] ?? 0) }
        case .lastUsed:
            list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var totalVisibleSize: Int64 {
        visibleApps.reduce(0) { $0 + (sizes[$1.url] ?? 0) }
    }

    var checkedLeftoverSize: Int64 {
        checked.reduce(0) { $0 + (leftoverSizes[$1] ?? 0) }
    }

    func reload() async {
        guard !isScanning else { return }
        isScanning = true
        let found = await Task.detached(priority: .userInitiated) { AppScanner.scan() }.value
        apps = found
        sizes = [:]
        isScanning = false
        await computeSizes()
    }

    private func computeSizes() async {
        let targets = apps.map(\.url)
        await withTaskGroup(of: (URL, Int64).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                if let url = iterator.next() {
                    group.addTask { (url, DiskUsage.bytes(of: url)) }
                }
            }
            for _ in 0..<4 { addNext() }
            for await (url, bytes) in group {
                sizes[url] = bytes
                addNext()
            }
        }
    }

    func loadLeftovers() {
        leftoverTask?.cancel()
        leftovers = []
        leftoverSizes = [:]
        checked = []

        guard let app = selectedApp else {
            isLoadingLeftovers = false
            return
        }
        isLoadingLeftovers = true
        let everything = apps
        let url = app.url

        leftoverTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverFinder.find(for: app, among: everything)
            }.value
            guard !Task.isCancelled, selection == url else { return }
            leftovers = found
            checked = Set(found.filter(\.defaultSelected).map(\.url))
            isLoadingLeftovers = false

            for item in found {
                let bytes = await Task.detached(priority: .utility) { DiskUsage.bytes(of: item.url) }.value
                guard !Task.isCancelled, selection == url else { return }
                leftoverSizes[item.url] = bytes
            }
        }
    }

    func removeSelected() async {
        guard let app = selectedApp, !app.isProtected, !isRemoving else { return }
        isRemoving = true
        let items = leftovers.filter { checked.contains($0.url) }
        let result = await AppRemover.remove(app: app, leftovers: items, resetPrivacy: resetPrivacy)
        isRemoving = false
        resultMessage = result.summary
        selection = nil
        leftovers = []
        await reload()
    }
}
