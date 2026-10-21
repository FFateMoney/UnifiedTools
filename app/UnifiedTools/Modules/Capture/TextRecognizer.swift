import AppKit
import SwiftUI
import Vision

enum TextRecognizer {
    /// Recognised lines in reading order, joined with newlines. Empty when nothing was found.
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Automatic language detection took ~25 s the first time and read Chinese as English
            // garbage; naming the languages is instant and accurate.
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image)
            guard (try? handler.perform([request])) != nil else { return "" }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

/// Shows recognised text in an editable window so it can be corrected before copying.
@MainActor
final class OCRResultPanel {
    private static var open: [OCRResultPanel] = []
    private static let size = NSSize(width: 460, height: 320)

    private let panel: NSPanel

    static func show(text: String) {
        let result = OCRResultPanel(text: text)
        open.append(result)
        result.panel.makeKeyAndOrderFront(nil)
    }

    private init(text: String) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别结果"
        panel.level = .floating
        // The app is usually inactive here; without this the panel hides itself the moment it appears.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: OCRResultView(text: text))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Self.open.removeAll { $0 === self }
            }
        }
    }
}

private struct OCRResultView: View {
    @State var text: String

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(text.count) 个字符").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    Toast.show("已复制文字")
                }
            }
        }
        .padding(12)
        .frame(width: 460, height: 320)
    }
}
