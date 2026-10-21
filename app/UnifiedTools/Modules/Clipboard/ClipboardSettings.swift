import SwiftUI

struct ClipboardSettings: View {
    @AppStorage(Settings.clipboardRecordImagesKey) private var recordImages = true
    @AppStorage(Settings.clipboardMaxItemsKey) private var maxItems = Settings.clipboardMaxItemsDefault
    @State private var blacklist = Settings.clipboardBlacklist
    @State private var newBundleID = ""

    var body: some View {
        Toggle("记录图片(占用磁盘空间)", isOn: $recordImages)

        Stepper(value: $maxItems, in: 100...5000, step: 100) {
            Text("最多保留 \(maxItems) 条")
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("不记录这些应用的复制内容").font(.subheadline)
            ForEach(blacklist, id: \.self) { bundleID in
                HStack {
                    Text(bundleID).font(.caption.monospaced())
                    Spacer()
                    Button {
                        blacklist.removeAll { $0 == bundleID }
                        Settings.clipboardBlacklist = blacklist
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("应用的 Bundle ID", text: $newBundleID)
                Button("添加") {
                    let id = newBundleID.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty, !blacklist.contains(id) else { return }
                    blacklist.append(id)
                    Settings.clipboardBlacklist = blacklist
                    newBundleID = ""
                }
            }
        }
    }
}
