import SwiftUI
import DiskLensCore

struct FileRemovalConfirmationView: View {
    let request: FileRemovalRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(request.mode.confirmationTitle, systemImage: request.mode == .permanent ? "trash.slash" : "trash")
                .font(.title2.bold())
            Text(request.entry.name).font(.headline).lineLimit(3)
            Text(request.entry.path).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Measured size: \(SizeFormat.string(request.entry.allocatedBytes)).").foregroundStyle(.secondary)
            if request.entry.isFolder {
                Text(request.mode == .permanent
                     ? "The entire folder and its contents will be deleted, including items not shown in the table."
                     : "The entire folder and its contents will be moved, including items not shown in the table.")
            }
            if request.entry.kind == .symlink {
                Text(request.mode == .permanent
                     ? "Only the symbolic link will be deleted, not the item it points to."
                     : "Only the symbolic link will be moved, not the item it points to.")
            }
            if request.mode == .permanent {
                Text("The item will be deleted immediately, bypassing Trash. You cannot undo this or restore the item from Trash.")
                    .font(.callout.weight(.semibold)).foregroundStyle(.red)
            } else {
                Text("You can restore the item from Trash in Finder. Space is usually freed after emptying Trash.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("For cloud folders, deletion may sync to other devices.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(request.mode.actionTitle, role: .destructive, action: confirm)
            }
        }.padding(24).frame(width: 500)
    }
}
