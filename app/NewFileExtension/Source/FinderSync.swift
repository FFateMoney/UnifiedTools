import Cocoa
import FinderSync

/// Adds to Finder's right-click menu: "复制路径", and "新建文件" for text, Markdown, Excel and Word documents.
/// Runs inside Finder's sandbox, with an entitlement that lets it write into any folder you can.
final class FinderSync: FIFinderSync {
    private struct Template {
        let title: String
        let baseName: String
        let fileExtension: String
        /// A blank document bundled with the extension; nil creates an empty file.
        let resource: String?
    }

    private let templates = [
        Template(title: "文本文档 (.txt)", baseName: "新建文本文档", fileExtension: "txt", resource: nil),
        Template(title: "Markdown (.md)", baseName: "新建 Markdown", fileExtension: "md", resource: nil),
        Template(title: "Excel 表格 (.xlsx)", baseName: "新建 Excel 表格", fileExtension: "xlsx", resource: "blank"),
        Template(title: "Word 文档 (.docx)", baseName: "新建 Word 文档", fileExtension: "docx", resource: "blank"),
    ]

    override init() {
        super.init()
        // Watching "/" is what makes the menu appear in every folder.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems else { return nil }

        let submenu = NSMenu(title: "新建文件")
        for (index, template) in templates.enumerated() {
            let item = NSMenuItem(title: template.title, action: #selector(createFile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            submenu.addItem(item)
        }

        let copyPath = NSMenuItem(title: "复制路径", action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPath.target = self

        let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        parent.submenu = submenu

        let menu = NSMenu(title: "")
        menu.addItem(copyPath)
        menu.addItem(parent)
        return menu
    }

    /// Full POSIX paths of the right-clicked items, one per line; the current folder when nothing is selected.
    @objc private func copyPath(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        if urls.isEmpty, let target = controller.targetedURL() {
            urls = [target]
        }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        NSSound(named: "Pop")?.play()
    }

    @objc private func createFile(_ sender: NSMenuItem) {
        guard templates.indices.contains(sender.tag), let directory = targetDirectory() else {
            NSSound.beep()
            return
        }
        let template = templates[sender.tag]
        let destination = uniqueURL(in: directory, template: template)

        do {
            if let resource = template.resource {
                guard let source = Bundle.main.url(forResource: resource, withExtension: template.fileExtension) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try Data().write(to: destination, options: .withoutOverwriting)
            }
            // Select it so Return starts renaming right away.
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法新建文件"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// The folder that was right-clicked, or the folder holding the right-clicked file.
    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), selected.count == 1, isDirectory(selected[0]) {
            return selected[0]
        }
        guard let target = controller.targetedURL() else { return nil }
        return isDirectory(target) ? target : target.deletingLastPathComponent()
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func uniqueURL(in directory: URL, template: Template) -> URL {
        var candidate = directory.appendingPathComponent("\(template.baseName).\(template.fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(template.baseName) \(number).\(template.fileExtension)")
            number += 1
        }
        return candidate
    }
}
