import AppKit
import Observation

enum AnnotationTool: String, CaseIterable, Identifiable {
    case none, rectangle, arrow, pen, mosaic, text

    var id: String { rawValue }

    static var drawingTools: [AnnotationTool] { allCases.filter { $0 != .none } }

    var title: String {
        switch self {
        case .none: ""
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .mosaic: "马赛克"
        case .text: "文字"
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .mosaic: "square.grid.3x3"
        case .text: "textformat"
        }
    }
}

struct Annotation {
    enum Shape {
        case rectangle(NSRect)
        case arrow(from: NSPoint, to: NSPoint)
        case pen([NSPoint])
        case mosaic(NSRect)
        case text(origin: NSPoint, string: String)
    }

    let shape: Shape
    let color: NSColor
    /// Index into the size tables of `AnnotationStyle`.
    let level: Int
}

enum AnnotationStyle {
    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    static let lineWidths: [CGFloat] = [2, 4, 7]
    static let fontSizes: [CGFloat] = [16, 22, 32]
    static let mosaicBlocks: [CGFloat] = [8, 14, 24]
}

/// What the toolbar edits and the overlay view reads.
@MainActor
@Observable
final class CaptureEditorState {
    var tool: AnnotationTool = .none
    var colorIndex = 0
    var levelIndex = 1
    var canUndo = false

    var color: NSColor { AnnotationStyle.colors[colorIndex] }
}

/// Draws annotations in the overlay view's space: points, origin at the top left.
/// The same code paints the live preview and the exported image.
enum AnnotationRenderer {
    @MainActor
    static func draw(_ annotation: Annotation, base: CGImage, viewSize: NSSize) {
        annotation.color.setStroke()
        annotation.color.setFill()
        let lineWidth = AnnotationStyle.lineWidths[annotation.level]

        switch annotation.shape {
        case .rectangle(let rect):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: lineWidth)

        case .pen(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.stroke()

        case .mosaic(let rect):
            drawMosaic(rect, block: AnnotationStyle.mosaicBlocks[annotation.level], base: base, viewSize: viewSize)

        case .text(let origin, let string):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: AnnotationStyle.fontSizes[annotation.level], weight: .semibold),
                .foregroundColor: annotation.color,
            ]
            (string as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    /// The cropped region with every annotation burned in, at the screenshot's native resolution.
    @MainActor
    static func compose(
        cropped: CGImage,
        full: CGImage,
        annotations: [Annotation],
        cropOrigin: CGPoint,
        viewSize: NSSize
    ) -> CGImage {
        guard !annotations.isEmpty else { return cropped }

        let width = cropped.width
        let height = cropped.height
        let scale = CGFloat(full.width) / viewSize.width
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Move into the overlay's space: flip to a top-left origin, then scale points to pixels.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -cropOrigin.x / scale, y: -cropOrigin.y / scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations {
            draw(annotation, base: full, viewSize: viewSize)
        }
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage() ?? cropped
    }

    private static func drawArrow(from: NSPoint, to: NSPoint, lineWidth: CGFloat) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        let headLength = min(length * 0.6, 8 + lineWidth * 3)
        let angle = atan2(dy, dx)
        let spread = CGFloat.pi / 7
        let left = NSPoint(x: to.x - headLength * cos(angle - spread), y: to.y - headLength * sin(angle - spread))
        let right = NSPoint(x: to.x - headLength * cos(angle + spread), y: to.y - headLength * sin(angle + spread))
        let base = NSPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)

        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: base)
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    @MainActor
    private static func drawMosaic(_ rect: NSRect, block: CGFloat, base: CGImage, viewSize: NSSize) {
        let scale = CGFloat(base.width) / viewSize.width
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(bounds)
        guard !pixelRect.isEmpty, let region = base.cropping(to: pixelRect) else { return }

        // Shrink the region to one pixel per block, then stretch it back without smoothing.
        let blockPixels = max(block * scale, 2)
        let smallWidth = max(Int(pixelRect.width / blockPixels), 1)
        let smallHeight = max(Int(pixelRect.height / blockPixels), 1)
        guard let small = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: region.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .medium
        small.draw(region, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let reduced = small.makeImage() else { return }

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.interpolationQuality = .none
        NSImage(cgImage: reduced, size: rect.size).draw(
            in: rect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none.rawValue]
        )
        context?.restoreGState()
    }
}
