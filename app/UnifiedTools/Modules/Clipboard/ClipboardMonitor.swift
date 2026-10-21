import AppKit
import CryptoKit

/// Polls the general pasteboard and records what changed.
@MainActor
final class ClipboardMonitor {
    /// Password managers mark their copies with these types so history tools skip them.
    private static let skippedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]
    private static let maxTextLength = 200_000
    private static let maxImageBytes = 40_000_000

    private let pasteboard = NSPasteboard.general
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: Timer?

    var isPaused = false

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Puts an item back on the pasteboard without recording it a second time.
    func write(_ item: ClipItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.content, forType: .string)
        case .file:
            let urls = item.content.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pasteboard.writeObjects(urls)
        case .image:
            let url = ClipboardStore.imagesDirectory.appendingPathComponent(item.content)
            if let png = try? Data(contentsOf: url) {
                pasteboard.setData(png, forType: .png)
                // Some apps only look for TIFF.
                if let tiff = NSImage(data: png)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isPaused else { return }

        let types = pasteboard.types ?? []
        if types.contains(where: { Self.skippedTypes.contains($0.rawValue) }) { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontmost?.bundleIdentifier, Settings.clipboardBlacklist.contains(bundleID) { return }
        let sourceApp = frontmost?.localizedName ?? ""
        let limit = Settings.clipboardMaxItems

        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            store.add(kind: .file, content: fileURLs.map(\.path).joined(separator: "\n"), sourceApp: sourceApp, limit: limit)
            return
        }

        // Text wins when both are present: spreadsheets and web pages bring along a picture of themselves.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard text.count <= Self.maxTextLength else { return }
            store.add(kind: .text, content: text, sourceApp: sourceApp, limit: limit)
            return
        }

        guard Settings.clipboardRecordImages,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              data.count <= Self.maxImageBytes
        else { return }

        Task { @MainActor in
            let name = await Task.detached(priority: .utility) { Self.saveImage(data) }.value
            guard let name else { return }
            store.add(kind: .image, content: name, sourceApp: sourceApp, limit: limit)
        }
    }

    /// Writes the image as a PNG named after its own hash, so the same picture is stored once.
    private nonisolated static func saveImage(_ data: Data) -> String? {
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
        let png: Data
        if data.prefix(4) == pngSignature {
            png = data
        } else if let converted = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            return nil
        }

        let name = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = ClipboardStore.imagesDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? png.write(to: url)) != nil else { return nil }
        }
        return name
    }
}
