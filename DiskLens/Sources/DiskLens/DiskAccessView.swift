import SwiftUI
import AppKit

struct DiskAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openingFailed = false

    private var appURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Folder Access in One Place", systemImage: "lock.open")
                .font(.title2.weight(.semibold))
            Text("Enable Full Disk Access for Disk Manage so macOS does not ask separately about Downloads, Documents and Desktop.")
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Open the system access settings using the button below.")
                Text("2. Enable Disk Manage. If it is missing, click “+” and select this copy of the app, or drag it from Finder.")
                Text("3. If macOS asks you to restart Disk Manage, do so. Then scan again.")
            }.font(.callout)
            if let appURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This Copy of Disk Manage").font(.caption).foregroundStyle(.secondary)
                    Text(appURL.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Show App in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                }
            } else {
                Text("Launch the packaged Disk Manage.app to configure access.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("This access includes protected data from other apps. macOS stores your choice; you can revoke it in the same settings. Replacing the build may trigger another permission request.")
                .font(.caption).foregroundStyle(.secondary)
            if openingFailed {
                Text("Open System Settings → Privacy & Security → Full Disk Access manually.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Access Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    openingFailed = !NSWorkspace.shared.open(url)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 560).fixedSize(horizontal: false, vertical: true)
    }
}
