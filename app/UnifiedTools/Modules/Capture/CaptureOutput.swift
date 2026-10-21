import AppKit

/// What can be done with a finished selection.
@MainActor
enum CaptureOutput {
    static var saveDirectory: URL {
        FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedTools", isDirectory: true)
    }

    static func nsImage(_ selection: SelectionOverlay.Selection) -> NSImage {
        NSImage(
            cgImage: selection.image,
            size: NSSize(
                width: CGFloat(selection.image.width) / selection.scale,
                height: CGFloat(selection.image.height) / selection.scale
            )
        )
    }

    static func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Toast.show("已复制到剪贴板")
    }

    @discardableResult
    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            Toast.show("保存失败")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let url = saveDirectory.appendingPathComponent("Capture_\(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            try png.write(to: url)
            Toast.show("已保存到 图片/UnifiedTools")
            return url
        } catch {
            Toast.show("保存失败:\(error.localizedDescription)")
            return nil
        }
    }
}
