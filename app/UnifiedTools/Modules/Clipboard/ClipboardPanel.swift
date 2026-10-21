import AppKit
import SwiftUI

@MainActor
@Observable
final class ClipboardPanelModel {
    var query = ""
    var selection = 0
    private(set) var items: [ClipItem] = []

    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored var onPick: (ClipItem) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
        reload()
    }

    func reload() {
        items = store.items(matching: query)
        selection = 0
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    func pickSelected() {
        if items.indices.contains(selection) {
            onPick(items[selection])
        }
    }
}

/// Spotlight-style panel. It never activates the app, so the app you were typing in stays frontmost
/// and receives the paste.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    fileprivate static let size = NSSize(width: 520, height: 420)

    private var panel: ClipPanel?
    private let store: ClipboardStore
    private let onPick: (ClipItem) -> Void

    init(store: ClipboardStore, onPick: @escaping (ClipItem) -> Void) {
        self.store = store
        self.onPick = onPick
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        close()

        // A fresh model each time resets the search box and selection.
        let model = ClipboardPanelModel(store: store)
        model.onPick = { [weak self] item in
            self?.close()
            self?.onPick(item)
        }
        model.onClose = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model))
        hosting.sizingOptions = []

        let panel = ClipPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.delegate = self
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The text field would swallow arrows and return, so the panel sees keys first.
        panel.keyHandler = { [weak panel] event in
            // Let the input method finish composing (Chinese, Japanese) before keys act as commands.
            if (panel?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
            switch event.keyCode {
            case 125: model.move(1)
            case 126: model.move(-1)
            case 36, 76: model.pickSelected()
            case 53: model.onClose()
            default: return false
            }
            return true
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.size.width / 2,
                y: frame.midY - Self.size.height / 2 + frame.height * 0.1
            ))
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.keyHandler = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

private final class ClipPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

private struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索剪贴板历史", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($searchFocused)

            Divider()

            if model.items.isEmpty {
                Text(model.query.isEmpty ? "还没有记录" : "没有匹配的记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, selected: index == model.selection)
                                    .id(item.id)
                                    .onTapGesture { model.onPick(item) }
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, newValue in
                        if model.items.indices.contains(newValue) {
                            proxy.scrollTo(model.items[newValue].id)
                        }
                    }
                }
            }
        }
        .frame(width: ClipboardPanelController.size.width, height: ClipboardPanelController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { _, _ in model.reload() }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool

    @State private var thumbnail: CGImage?
    @State private var pixelSize: CGSize?

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .task(id: item.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch item.kind {
        case .image:
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        case .file:
            Image(systemName: "doc").frame(width: 36).foregroundStyle(.secondary)
        case .text:
            Image(systemName: "text.alignleft").frame(width: 36).foregroundStyle(.secondary)
        }
    }

    private func loadThumbnail() async {
        guard item.kind == .image else { return }
        let url = ClipboardStore.imagesDirectory.appendingPathComponent(item.content)
        let loaded = await Task.detached(priority: .utility) { ThumbnailLoader.load(url) }.value
        thumbnail = loaded?.image
        pixelSize = loaded?.size
    }

    private var preview: String {
        switch item.kind {
        case .image:
            if let pixelSize {
                return "图片 \(Int(pixelSize.width)) × \(Int(pixelSize.height))"
            }
            return "图片"
        case .file:
            return item.content
                .split(separator: "\n")
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
        case .text:
            let line = item.content
                .split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    private var detail: String {
        let time = item.lastUsed.formatted(.relative(presentation: .named))
        return item.sourceApp.isEmpty ? time : "\(item.sourceApp) · \(time)"
    }
}


private enum ThumbnailLoader {
    struct Result: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
    }

    /// A small preview plus the full pixel size, without decoding the whole image.
    nonisolated static func load(_ url: URL, maxPixel: Int = 96) -> Result? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Result(image: image, size: CGSize(width: width, height: height))
    }
}
