import AppKit
import SwiftUI

/// Freezes every screen under a dimmed overlay, lets the user drag out a region and mark it up.
@MainActor
final class SelectionOverlay {
    enum Action {
        case copy, save, pin, ocr
    }

    struct Selection {
        let image: CGImage
        /// Backing pixels per point of the screen it was taken on.
        let scale: CGFloat
        /// Where the region sits on the desktop, in global screen coordinates.
        let screenRect: NSRect
    }

    private var windows: [OverlayWindow] = []
    private let onAction: (Action, Selection) -> Void
    private let onClose: () -> Void

    init(shots: [ScreenShot], onAction: @escaping (Action, Selection) -> Void, onClose: @escaping () -> Void) {
        self.onAction = onAction
        self.onClose = onClose

        NSApp.activate(ignoringOtherApps: true)
        windows = shots.map { shot in
            let window = OverlayWindow(
                contentRect: shot.screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: shot.screen
            )
            window.hidesOnDeactivate = false
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = OverlayView(shot: shot, overlay: self)
            window.setFrame(shot.screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }

        let mouse = NSEvent.mouseLocation
        let active = windows.first { $0.frame.contains(mouse) } ?? windows.first
        active?.makeKey()
        active?.makeFirstResponder(active?.contentView)
    }

    func cancel() {
        finish()
    }

    fileprivate func selectionBegan(in view: OverlayView) {
        for window in windows {
            if let other = window.contentView as? OverlayView, other !== view {
                other.clearSelection()
            }
        }
    }

    fileprivate func perform(_ action: Action, from view: OverlayView) {
        guard let selection = view.currentSelection() else { return }
        finish()
        onAction(action, selection)
    }

    private func finish() {
        guard !windows.isEmpty else { return }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        onClose()
    }
}

/// A non-activating panel receives the very first click even while the app is still becoming active;
/// a plain window can swallow it, which made the first drag do nothing.
private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let top = Edges(rawValue: 4)
    static let bottom = Edges(rawValue: 8)
}

private enum DragMode {
    case newSelection
    case move
    case resize(Edges)
    case annotate
}

private final class OverlayView: NSView, NSTextFieldDelegate {
    private static let minimumSide: CGFloat = 4
    private static let handleReach: CGFloat = 6
    private static let toolbarSize = NSSize(width: 330, height: 118)

    private let shot: ScreenShot
    private weak var overlay: SelectionOverlay?
    private let state = CaptureEditorState()

    private var selection: NSRect?
    private var dragMode: DragMode?
    private var dragOrigin = NSPoint.zero
    private var selectionAtDragStart = NSRect.zero

    private var annotations: [Annotation] = []
    private var draft: Annotation.Shape?
    private var textField: NSTextField?
    private var toolbar: NSHostingView<CaptureToolbar>?

    init(shot: ScreenShot, overlay: SelectionOverlay) {
        self.shot = shot
        self.overlay = overlay
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: shot.image, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        guard let selection, selection.width > 0, selection.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, base: shot.image, viewSize: bounds.size)
        }
        if let draft {
            AnnotationRenderer.draw(
                Annotation(shape: draft, color: state.color, level: state.levelIndex),
                base: shot.image,
                viewSize: bounds.size
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        if annotations.isEmpty {
            drawHandles(for: selection)
        }
        drawSizeLabel(for: selection)
    }

    private func drawHandles(for selection: NSRect) {
        let xs = [selection.minX, selection.midX, selection.maxX]
        let ys = [selection.minY, selection.midY, selection.maxY]
        for (column, x) in xs.enumerated() {
            for (row, y) in ys.enumerated() where !(column == 1 && row == 1) {
                let handle = NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
                NSColor.white.setFill()
                NSBezierPath(rect: handle).fill()
                NSColor.systemBlue.setStroke()
                NSBezierPath(rect: handle).stroke()
            }
        }
    }

    private func drawSizeLabel(for selection: NSRect) {
        let scale = CGFloat(shot.image.width) / bounds.width
        let text = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let box = NSRect(
            x: selection.minX,
            y: max(selection.minY - textSize.height - 10, 4),
            width: textSize.width + 12,
            height: textSize.height + 4
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }

    // MARK: - Mouse and keys

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // A click while typing text finishes the text and does nothing else.
        if textField != nil {
            commitText()
            return
        }

        if let selection, selection.width > 0 {
            if state.tool != .none, selection.contains(point) {
                beginAnnotation(at: point)
                return
            }
            if annotations.isEmpty {
                if let mode = dragMode(at: point, in: selection) {
                    dragMode = mode
                    dragOrigin = point
                    selectionAtDragStart = selection
                    hideToolbar()
                    return
                }
            } else {
                // Marked-up selections are locked; undo the marks to change the region again.
                return
            }
        }

        dragMode = .newSelection
        dragOrigin = point
        clearSelection()
        overlay?.selectionBegan(in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // If the press itself never arrived, start from where the drag began: the first drag event
        // is only a pixel or two away from the press.
        if dragMode == nil, selection == nil, textField == nil {
            dragMode = .newSelection
            dragOrigin = NSPoint(x: point.x - event.deltaX, y: point.y - event.deltaY)
            overlay?.selectionBegan(in: self)
        }

        switch dragMode {
        case .newSelection:
            selection = rect(from: dragOrigin, to: clamped(point, to: bounds))
        case .move:
            selection = movedSelection(by: NSPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y))
        case .resize(let edges):
            selection = resizedSelection(edges, to: clamped(point, to: bounds))
        case .annotate:
            updateDraft(at: point)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = nil }
        switch dragMode {
        case .newSelection, .move, .resize:
            guard let selection, selection.width >= Self.minimumSide, selection.height >= Self.minimumSide else {
                clearSelection()
                return
            }
            showToolbar(for: selection)
        case .annotate:
            finishAnnotation()
        case nil:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        let isUndo = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z"
        if isUndo {
            undo()
            return
        }
        switch event.keyCode {
        case 53: overlay?.cancel()
        case 36, 76: overlay?.perform(.copy, from: self)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Selection geometry

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamped(_ point: NSPoint, to area: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, area.minX), area.maxX), y: min(max(point.y, area.minY), area.maxY))
    }

    private func dragMode(at point: NSPoint, in selection: NSRect) -> DragMode? {
        let reach = Self.handleReach
        let withinX = point.x >= selection.minX - reach && point.x <= selection.maxX + reach
        let withinY = point.y >= selection.minY - reach && point.y <= selection.maxY + reach
        guard withinX, withinY else { return nil }

        var edges: Edges = []
        if abs(point.x - selection.minX) <= reach { edges.insert(.left) }
        if abs(point.x - selection.maxX) <= reach { edges.insert(.right) }
        if abs(point.y - selection.minY) <= reach { edges.insert(.top) }
        if abs(point.y - selection.maxY) <= reach { edges.insert(.bottom) }
        if !edges.isEmpty { return .resize(edges) }
        return selection.contains(point) ? .move : nil
    }

    private func movedSelection(by delta: NSPoint) -> NSRect {
        var moved = selectionAtDragStart.offsetBy(dx: delta.x, dy: delta.y)
        moved.origin.x = min(max(moved.origin.x, 0), bounds.width - moved.width)
        moved.origin.y = min(max(moved.origin.y, 0), bounds.height - moved.height)
        return moved
    }

    private func resizedSelection(_ edges: Edges, to point: NSPoint) -> NSRect {
        var left = selectionAtDragStart.minX
        var right = selectionAtDragStart.maxX
        var top = selectionAtDragStart.minY
        var bottom = selectionAtDragStart.maxY
        if edges.contains(.left) { left = point.x }
        if edges.contains(.right) { right = point.x }
        if edges.contains(.top) { top = point.y }
        if edges.contains(.bottom) { bottom = point.y }
        return NSRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
    }

    func clearSelection() {
        selection = nil
        annotations.removeAll()
        draft = nil
        state.canUndo = false
        removeTextField()
        hideToolbar()
        needsDisplay = true
    }

    // MARK: - Annotating

    private func beginAnnotation(at point: NSPoint) {
        switch state.tool {
        case .none:
            return
        case .text:
            beginText(at: point)
        case .rectangle:
            startDraft(.rectangle(NSRect(origin: point, size: .zero)), at: point)
        case .mosaic:
            startDraft(.mosaic(NSRect(origin: point, size: .zero)), at: point)
        case .arrow:
            startDraft(.arrow(from: point, to: point), at: point)
        case .pen:
            startDraft(.pen([point]), at: point)
        }
    }

    private func startDraft(_ shape: Annotation.Shape, at point: NSPoint) {
        dragMode = .annotate
        dragOrigin = point
        draft = shape
        needsDisplay = true
    }

    private func updateDraft(at point: NSPoint) {
        guard let selection else { return }
        let current = clamped(point, to: selection)
        switch draft {
        case .rectangle: draft = .rectangle(rect(from: dragOrigin, to: current))
        case .mosaic: draft = .mosaic(rect(from: dragOrigin, to: current))
        case .arrow: draft = .arrow(from: dragOrigin, to: current)
        case .pen(let points): draft = .pen(points + [current])
        case .text, nil: break
        }
    }

    private func finishAnnotation() {
        defer {
            draft = nil
            needsDisplay = true
        }
        guard let draft else { return }

        let isUsable: Bool
        switch draft {
        case .rectangle(let rect), .mosaic(let rect): isUsable = rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to): isUsable = hypot(to.x - from.x, to.y - from.y) >= 4
        case .pen(let points): isUsable = points.count >= 2
        case .text: isUsable = false
        }
        guard isUsable else { return }

        annotations.append(Annotation(shape: draft, color: state.color, level: state.levelIndex))
        state.canUndo = true
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        state.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    // MARK: - Text annotations

    private func beginText(at point: NSPoint) {
        let size = AnnotationStyle.fontSizes[state.levelIndex]
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y, width: 280, height: size * 1.6))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size, weight: .semibold)
        field.textColor = state.color
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            removeTextField()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        let string = field.stringValue
        let font = field.font ?? .systemFont(ofSize: 16)
        let textHeight = (string as NSString).size(withAttributes: [.font: font]).height
        let origin = NSPoint(x: field.frame.minX + 2, y: field.frame.minY + (field.frame.height - textHeight) / 2)
        removeTextField()

        guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        annotations.append(Annotation(
            shape: .text(origin: origin, string: string),
            color: state.color,
            level: state.levelIndex
        ))
        state.canUndo = true
        needsDisplay = true
    }

    private func removeTextField() {
        guard let field = textField else { return }
        field.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Output

    func currentSelection() -> SelectionOverlay.Selection? {
        commitText()
        guard let selection else { return nil }

        let scale = CGFloat(shot.image.width) / bounds.width
        let pixels = NSRect(
            x: selection.minX * scale,
            y: selection.minY * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral
        guard let cropped = shot.image.cropping(to: pixels) else { return nil }

        let image = AnnotationRenderer.compose(
            cropped: cropped,
            full: shot.image,
            annotations: annotations,
            cropOrigin: pixels.origin,
            viewSize: bounds.size
        )

        let frame = shot.screen.frame
        let screenRect = NSRect(
            x: frame.minX + selection.minX,
            y: frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        return SelectionOverlay.Selection(image: image, scale: scale, screenRect: screenRect)
    }

    // MARK: - Toolbar

    private func hideToolbar() {
        toolbar?.removeFromSuperview()
        toolbar = nil
    }

    private func showToolbar(for selection: NSRect) {
        hideToolbar()

        let hosting = NSHostingView(rootView: CaptureToolbar(
            size: Self.toolbarSize,
            state: state,
            onUndo: { [weak self] in self?.undo() },
            onAction: { [weak self] action in
                guard let self else { return }
                self.overlay?.perform(action, from: self)
            },
            onCancel: { [weak self] in self?.overlay?.cancel() }
        ))
        hosting.sizingOptions = []

        let size = Self.toolbarSize
        var y = selection.maxY + 8
        if y + size.height > bounds.height - 4 {
            y = selection.minY - size.height - 8
        }
        if y < 4 {
            y = selection.maxY - size.height - 8
        }
        let x = min(max(selection.maxX - size.width, 8), bounds.width - size.width - 8)
        hosting.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        addSubview(hosting)
        toolbar = hosting
        needsDisplay = true
    }
}

private struct CaptureToolbar: View {
    let size: NSSize
    let state: CaptureEditorState
    let onUndo: () -> Void
    let onAction: (SelectionOverlay.Action) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            toolRow
            styleRow
            actionRow
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolRow: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.drawingTools) { tool in
                let selected = state.tool == tool
                Button {
                    state.tool = selected ? .none : tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 38, height: 30)
                        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 38, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canUndo)
            .help("撤销 ⌘Z")
        }
        .frame(height: 34)
    }

    private var styleRow: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationStyle.colors.indices, id: \.self) { index in
                Button {
                    state.colorIndex = index
                } label: {
                    Circle()
                        .fill(Color(nsColor: AnnotationStyle.colors[index]))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.primary, lineWidth: state.colorIndex == index ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 16)
            ForEach(AnnotationStyle.lineWidths.indices, id: \.self) { index in
                Button {
                    state.levelIndex = index
                } label: {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 22, height: AnnotationStyle.lineWidths[index])
                        .padding(4)
                        .background(
                            state.levelIndex == index ? Color.accentColor.opacity(0.35) : .clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .opacity(state.tool == .none ? 0.4 : 1)
        .disabled(state.tool == .none)
    }

    private var actionRow: some View {
        HStack(spacing: 2) {
            action("复制", "doc.on.doc") { onAction(.copy) }
            action("保存", "square.and.arrow.down") { onAction(.save) }
            action("贴图", "pin") { onAction(.pin) }
            action("识别", "text.viewfinder") { onAction(.ocr) }
            action("取消", "xmark", perform: onCancel)
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 1) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 10))
            }
            .frame(width: 62, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
