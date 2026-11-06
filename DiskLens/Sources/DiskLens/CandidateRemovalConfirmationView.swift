import SwiftUI
import DiskLensCore

struct CandidateRemovalConfirmationView: View {
    let request: CandidateRemovalRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.scope == .aiRecommended
                 ? request.mode == .permanent ? "Permanently Delete AI-Recommended Items?" : "Move AI-Recommended Items to Trash?"
                 : request.mode == .permanent ? "Permanently Delete All Candidates?" : "Move All Candidates to Trash?")
                .font(.title2.bold())
            Text("Available: \(request.requests.count) of \(request.requests.count + request.unavailable.count) · Size: \(SizeFormat.string(request.totalBytes))")
                .font(.headline)
            Text(request.scope == .aiRecommended
                 ? "Only items explicitly recommended by AI are listed below. Other candidates stay in place. Each folder is processed with all its contents."
                 : "The entire candidate list, regardless of the search filter. Each folder is processed with all its contents.")
                .font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(request.requests) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.entry.name) · \(SizeFormat.string(item.entry.allocatedBytes))").font(.callout.weight(.medium))
                            Text(item.entry.path).font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    ForEach(request.unavailable) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Skip: \(item.entry.name)", systemImage: "exclamationmark.shield").font(.callout.weight(.medium))
                            Text(item.entry.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }.padding(12)
            }.frame(height: 240).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            Text(request.mode == .permanent
                 ? "All listed items will be deleted immediately, bypassing Trash. This cannot be undone."
                 : "You can restore items from Trash in Finder. Space is usually freed after emptying Trash.")
                .font(.callout.weight(.semibold)).foregroundStyle(request.mode == .permanent ? .red : .primary)
            Text("For cloud folders, deletion may sync to other devices. The measured size does not guarantee the same amount of freed space. Processing stops at the first error; completed actions remain in effect.")
                .font(.caption).foregroundStyle(.secondary)
            if !request.unavailable.isEmpty {
                Text("Items to skip: \(request.unavailable.count). Reasons are listed at the end. Only available items will be removed.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(request.mode == .permanent ? "Delete Available Items Permanently" : "Move Available Items to Trash", role: .destructive, action: confirm)
                    .disabled(request.requests.isEmpty)
            }
        }.padding(24).frame(width: 600)
    }
}
