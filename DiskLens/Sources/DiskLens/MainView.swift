import SwiftUI
import AppKit
import DiskLensCore

private let accent = Color(red: 0.06, green: 0.52, blue: 0.48)

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var candidatesHovered = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.scanning { progress }
                resultContent
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .tint(accent)
        .task(id: model.treeQuery) { model.reloadTree() }
        .onChange(of: model.search) { _, _ in model.treeOffset = 0 }
        .onChange(of: model.treeOrder) { _, _ in model.treeOffset = 0 }
        .onChange(of: model.treeKind) { _, _ in model.treeOffset = 0 }
        .sheet(isPresented: $model.showingSettings) { AgentSettingsView(model: model) }
        .sheet(isPresented: $model.showingDiskAccess) { DiskAccessView() }
        .sheet(item: $model.pendingRemoval) { request in
            FileRemovalConfirmationView(request: request, cancel: model.cancelRemoval, confirm: model.confirmRemoval)
        }
        .sheet(item: $model.pendingCandidateRemoval) { request in
            CandidateRemovalConfirmationView(request: request, cancel: model.cancelCandidateRemoval, confirm: model.confirmCandidateRemoval)
        }
        .alert("Disk Manage", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Manage").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Storage, understood").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 14)
            VStack(spacing: 5) {
                ForEach(Pane.allCases) { pane in
                    Button {
                        if pane == .assistant, model.analysisReport == nil { model.prepareAnalysis(for: nil) }
                        else { model.pane = pane; model.selection = nil; model.search = "" }
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: pane.icon).font(.system(size: 16)).frame(width: 20)
                            Text(pane.rawValue).font(.system(size: 13, weight: model.pane == pane ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(model.pane == pane ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(model.pane == pane ? accent : .primary)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.interactionLocked && pane == .assistant)
                }
            }
            Spacer()
            if let capacity = model.capacity {
                VStack(alignment: .leading, spacing: 11) {
                    HStack { Image(systemName: "internaldrive"); Text(capacity.name).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(SizeFormat.string(capacity.freeBytes)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    }
                    Text("free on volume").font(.caption).foregroundStyle(.secondary)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(accent.opacity(0.15))
                            Capsule().fill(accent).frame(width: g.size.width * max(0, min(1, capacity.usedFraction)))
                        }
                    }.frame(height: 5)
                }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 14) {
                Button { model.showingDiskAccess = true } label: {
                    Label("Disk Access…", systemImage: "lock.open").font(.caption)
                }.disabled(model.interactionLocked)
                Button { model.showingSettings = true } label: {
                    Label("AI Connection", systemImage: "slider.horizontal.3").font(.caption)
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 12)
        }.padding(.horizontal, 16).background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.pane.rawValue).font(.system(size: 25, weight: .semibold, design: .rounded))
                Menu {
                    Button("Home Folder") { model.openLocation(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Entire Mac") { model.openLocation(URL(fileURLWithPath: "/System/Volumes/Data")) }
                    Button("Filesystem Root") { model.openLocation(URL(fileURLWithPath: "/")) }
                    Button("Choose Folder…") { model.chooseFolder() }
                } label: { Label(model.targetName, systemImage: "folder").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.interactionLocked)
            }
            Spacer()
            if model.report != nil {
                Menu {
                    Button("Export JSON…") { model.export(json: true) }
                    Button("Export Text…") { model.export(json: false) }
                    Button("Copy Report") { if let report = model.report { model.copy(report.text()) } }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                .help("Export Report")
                .accessibilityLabel("Export Report")
                .disabled(model.workLocked)
            }
            if model.scanning {
                Button("Stop", role: .cancel) { model.cancelScan() }.buttonStyle(.bordered)
            } else {
                Button { if let current = model.current { model.scanFolder(current) } else { model.scan() } } label: { Label("Refresh Sizes", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.workLocked)
                    .contextMenu {
                        Button("Rescan Everything") { model.scan(forceFull: true) }.disabled(model.workLocked)
                    }
            }
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                Text("Scanning · items: \(model.scanProgress?.items ?? 0) · \(SizeFormat.string(model.scanProgress?.allocatedBytes ?? 0))").font(.callout)
                    Text(model.scanProgress?.currentPath ?? model.target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            Text((model.scanProgress?.reusedFolders ?? 0) > 0
                 ? "Folders reused from the last scan: \(model.scanProgress?.reusedFolders ?? 0). Updating changed branches."
                 : model.scanProgress?.usesPreviousScan == true
                 ? "Checking for changes. Previous sizes remain visible."
                 : "Previous sizes are retained. New folders are measured as the scan progresses.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(accent.opacity(0.07))
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(accent.opacity(0.07)).frame(width: 130, height: 130)
                Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 53, weight: .light)).foregroundStyle(accent)
            }
            VStack(spacing: 9) {
                Text("What's using your storage?").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Scan your disk, find large folders\nand get cleanup recommendations.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(model.target.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Choose Folder…") { model.chooseFolder() }.buttonStyle(.bordered).controlSize(.large)
                Button("Start Scan") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.disabled(model.scanning)
            Button("Set Up Folder Access…") { model.showingDiskAccess = true }
                .buttonStyle(.link)
            Spacer()
            HStack(spacing: 28) {
                Label("Metadata only", systemImage: "doc.text.viewfinder")
                Label("Move to Trash", systemImage: "trash")
                Label("Runs locally", systemImage: "laptopcomputer")
            }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 30)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var resultContent: some View {
        if model.pane == .assistant { assistant }
        else {
            VStack(spacing: 18) {
                metrics
                if let report = model.displayedReport, report.isPartial, !model.scanning {
                    HStack(spacing: 9) {
                        Image(systemName: "info.circle").foregroundStyle(.orange)
                        Text(report.cancelled ? "Scan stopped. Results found so far are shown; the total size is incomplete." : "Items that could not be checked: \(report.issueCount). Sizes may be underestimated.")
                        Spacer()
                        Button("Disk Access") {
                            model.showingDiskAccess = true
                        }.buttonStyle(.link)
                    }.font(.caption).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                tableHeader
                if model.pane == .overview, let error = model.treeError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Disk Access") { model.showingDiskAccess = true }.buttonStyle(.link)
                    }
                }
                if entries.isEmpty { emptyList }
                else { entryTable }
                if model.pane == .overview, let page = model.treePage, page.total > model.treeLimit {
                    HStack {
                        Text("Items \(model.treeOffset + 1)–\(min(page.total, model.treeOffset + page.entries.count)) of \(page.total)").font(.caption)
                        Spacer()
                        Button("Previous") { model.treeOffset = max(0, model.treeOffset - model.treeLimit) }.disabled(model.treeOffset == 0)
                        Button("Next") { model.treeOffset += model.treeLimit }.disabled(model.treeOffset + model.treeLimit >= page.total)
                    }
                }
                safetyAction
                footer
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric("Measured Storage", value: SizeFormat.string(model.displayedReport?.root.allocatedBytes ?? 0), icon: "chart.pie", color: accent)
            metric("Files", value: (model.displayedReport?.root.fileCount ?? 0).formatted(.number.locale(Locale(identifier: "en_US"))), icon: "doc.on.doc", color: .blue)
            Button {
                model.pane = .candidates; model.selection = nil; model.search = ""
            } label: {
                metric("Cleanup Candidates", value: SizeFormat.string(model.displayedReport?.candidateBytes ?? 0), icon: "archivebox", color: .orange)
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.orange.opacity(candidatesHovered ? 0.5 : 0)))
                    .contentShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .onHover { candidatesHovered = $0 }
            .help("Show cleanup candidates")
            .accessibilityLabel("Cleanup Candidates")
            .accessibilityValue(SizeFormat.string(model.displayedReport?.candidateBytes ?? 0))
        }
    }
    private func metric(_ label: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(label).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(color) }
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary.opacity(0.65)))
    }

    private var tableHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.pane == .overview {
                    Button {
                        model.goToParent()
                    } label: { Image(systemName: "chevron.up") }.disabled(model.openedPath == "/" || model.interactionLocked)
                    .help("Go to parent folder")
                    .accessibilityLabel("Go to parent folder")
                    Text(model.openedPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else { Text(model.pane == .files ? "100 largest files in the scan" : "Candidates from the scan").font(.headline) }
                Spacer()
                TextField("Search report", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            if model.pane == .candidates {
                Text("Check the contents before cleanup. Caches may need to be downloaded or rebuilt; the measured size does not guarantee the same amount of freed space.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { model.prepareCandidateReview() } label: {
                        Label("Review with AI", systemImage: "sparkles")
                    }.disabled(model.workLocked || model.analyzing)
                    Text("Review the list and find more candidates in the full scan")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Move All to Trash…", role: .destructive) { model.requestCandidateRemoval() }
                        Button("Delete All Permanently…", role: .destructive) { model.requestCandidateRemoval(mode: .permanent) }
                    } label: {
                        Label("Remove All… (\(model.displayedReport?.candidates.count ?? 0))", systemImage: "trash")
                    }.fixedSize().disabled(model.interactionLocked || model.displayedReport?.candidates.isEmpty != false)
                    .help("Remove all cleanup candidates, regardless of the search filter. Review every path in the confirmation first.")
                }
                aiRecommendedRemovalAction
            } else if model.pane == .overview {
                HStack {
                    Picker("Type", selection: $model.treeKind) {
                        Text("All").tag(EntryKind?.none)
                        Text("Folders").tag(EntryKind?.some(.folder))
                        Text("Files").tag(EntryKind?.some(.file))
                    }
                        .pickerStyle(.segmented).frame(width: 235)
                    Spacer()
                    Picker("Sort", selection: $model.treeOrder) {
                        ForEach(FileTreeOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 175)
                    Text("Allocated blocks").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entries: [DiskEntry] {
        var list: [DiskEntry]
        switch model.pane {
        case .files: list = model.displayedReport?.largestFiles ?? []
        case .candidates: list = model.displayedReport?.candidates.map(\.entry) ?? []
        default:
            list = model.current?.children ?? []
            if model.treeStore == nil, let kind = model.treeKind { list = list.filter { $0.kind == kind } }
        }
        if !model.search.isEmpty { list = list.filter { $0.path.localizedCaseInsensitiveContains(model.search) } }
        return list
    }

    private var entryTable: some View {
        Table(entries, selection: $model.selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isFolder ? "folder.fill" : (entry.kind == .symlink ? "link" : "doc.fill"))
                        .foregroundStyle(entry.isFolder ? accent.opacity(0.8) : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if model.pane != .overview { Text(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        if model.pane == .candidates, let candidate = model.displayedReport?.candidates.first(where: { $0.id == entry.id }) {
                            Text(candidate.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                .help(candidate.reason + "\n" + candidate.caution)
                        }
                    }
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture(count: entry.isFolder ? 1 : 2) { model.navigate(entry); if entry.isFolder { model.pane = .overview } }
            }.width(min: 230, ideal: 350)
            TableColumn("Size") { entry in
                Text(entry.sizeIsKnown == false ? "Measuring" : SizeFormat.string(entry.allocatedBytes))
                    .monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(entry.sizeIsKnown == false ? .secondary : .primary)
            }.width(110)
            TableColumn("Share") { entry in
                let denominator = model.pane == .overview ? (model.current?.allocatedBytes ?? 0) : (model.displayedReport?.root.allocatedBytes ?? 0)
                let share = denominator > 0 ? Double(entry.allocatedBytes) / Double(denominator) : 0
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(accent.opacity(0.10))
                            Capsule().fill(accent.opacity(0.65)).frame(width: g.size.width * min(1, max(0, share)))
                        }
                    }.frame(height: 5)
                    Text(String(format: "%.0f%%", share * 100)).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }.width(min: 90, ideal: 130)
            TableColumn("") { entry in
                HStack(spacing: 9) {
                    if entry.issueCount > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Size is incomplete: some items are inaccessible") }
                    Button { model.reveal(entry) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Show in Finder")
                        .accessibilityLabel("Show in Finder: \(entry.name)")
                    Button { model.prepareAnalysis(for: entry) } label: { Image(systemName: "sparkles") }
                        .buttonStyle(.borderless).help("Ask AI About Cleanup")
                        .accessibilityLabel("Ask AI About Cleanup: \(entry.name)")
                        .disabled(model.interactionLocked || model.analyzing)
                    Menu {
                        Button("Show in Finder") { model.reveal(entry) }
                        Button("Copy Path") { model.copy(entry.path) }
                        Button("Ask AI About Cleanup") { model.prepareAnalysis(for: entry) }
                            .disabled(model.interactionLocked || model.analyzing)
                        if entry.isFolder {
                            Button("Open Folder") { model.navigate(entry); model.pane = .overview }.disabled(model.interactionLocked)
                            Button("Scan This Folder") { model.scanFolder(entry) }.disabled(model.interactionLocked)
                        }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { model.requestRemoval(entry) }
                            .disabled(model.interactionLocked)
                        Button("Delete Permanently…", role: .destructive) { model.requestRemoval(entry, mode: .permanent) }
                            .disabled(model.interactionLocked)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Item actions")
                    .accessibilityLabel("Item actions: \(entry.name)")
                }
            }.width(100)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyList: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.loadingTree ? "Opening folder…" : model.search.isEmpty ? "No accessible items in this folder" : "No matches").font(.headline)
            if let error = model.treeError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var safetyAction: some View {
        let entry = model.selected ?? (model.pane == .overview ? model.current : nil)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.name ?? "Select a file or folder").font(.callout.weight(.medium)).lineLimit(1)
                Text(entry?.path ?? "The question will focus on the selected item")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let entry { model.prepareAnalysis(for: entry) }
            } label: {
                Label("Ask AI About Cleanup", systemImage: "sparkles")
            }.disabled(entry == nil || model.interactionLocked || model.analyzing)
        }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if model.scanning {
                    Text("Refreshing sizes · previous results remain available").font(.caption2)
                } else if let report = model.report {
                    Text("Last scan: \(report.measuredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))) · \(Int(report.durationSeconds)) s").font(.caption2)
                    if let reuse = report.scanReuse, reuse.reusedFolders > 0 {
                        Text("Folders reused: \(reuse.reusedFolders) · items checked again: \(reuse.inspectedItems)").font(.caption2)
                    }
                }
                if model.removing { Text(model.removalMode?.progressTitle ?? "Removing…").font(.caption).foregroundStyle(accent) }
                else if let status = model.removalStatus { Text(status).font(.caption).textSelection(.enabled) }
                if model.pane == .overview, let page = model.treePage {
                    Text("Items: \(page.total) · " + (model.automaticRefreshPaused ? "refresh paused" : model.automaticRefreshAvailable
                         ? "checking for changes automatically" : "journal unavailable; refresh sizes manually")).font(.caption2)
                } else { Text("APFS clones and snapshots may affect the space actually freed").font(.caption2) }
            }.foregroundStyle(.secondary)
            Spacer()
            if let selected = model.selected {
                Button("Show in Finder") { model.reveal(selected) }.controlSize(.small)
                Menu {
                    Button("Move to Trash…", role: .destructive) { model.requestRemoval(selected) }
                    Button("Delete Permanently…", role: .destructive) { model.requestRemoval(selected, mode: .permanent) }
                } label: { Label("Remove…", systemImage: "trash") }
                    .controlSize(.small).disabled(model.interactionLocked)
            }
            Button("AI Analysis") { model.prepareAnalysis(for: nil) }.controlSize(.small).disabled(model.interactionLocked || model.analyzing)
        }
    }

    private var assistant: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(accent).padding(18).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.reviewingCandidates ? "AI Candidate Review" : (model.analysisEntry == nil ? "Storage Cleanup Plan" : "Is It Safe to Remove?")).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(model.reviewingCandidates
                             ? "The agent will review current candidates and suggest others from the full scan.\nReview the suggestions and apply selected changes."
                             : model.analysisEntry == nil
                             ? "The agent will review the report and suggest a plan.\nRecommendations are text only; no commands are executed."
                             : "The agent will suggest what to clean up, what to keep\nand what to check before deciding.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if model.reviewingCandidates, let report = model.analysisReport {
                    let review = CandidateReview(report: report)
                    Text("Items to review: \(review.entries.count); current candidates: \(report.candidates.count). Largest items from the saved tree and file list; file contents are unknown.\(review.omittedCount > 0 ? " Items omitted from the request: \(review.omittedCount)." : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Back to Candidates") { model.pane = .candidates }.buttonStyle(.link)
                }
                if let entry = model.analysisEntry {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc").font(.headline)
                            Spacer()
                            Button("Full Report") { model.prepareAnalysis(for: nil) }.disabled(model.analyzing)
                        }
                        Text(entry.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Measured size: \(SizeFormat.string(entry.allocatedBytes)). Analysis uses the folder contents, large files and cleanup candidates found inside.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(model.agentName, systemImage: model.settings.mode == .api ? "network" : "terminal").font(.headline)
                        Spacer()
                        Button("Configure") { model.showingSettings = true }.disabled(model.analyzing)
                    }
                    Text(model.settings.mode == .api ? "Requesting analysis sends the report to \(model.settings.endpoint)." : "Requesting analysis sends the report to the selected agent through stdin.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("The request includes paths, sizes and scan limitations. File contents are not sent.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if model.preparingAnalysis {
                            ProgressView().controlSize(.small)
                            Text("Checking the selected folder's contents…").font(.callout)
                            Spacer()
                            Button("Stop") { model.cancelAnalysis() }
                        } else if model.analyzing {
                            ProgressView().controlSize(.small)
                            Text(model.reviewingCandidates ? "The agent is reviewing candidates…" : (model.analysisEntry == nil ? "The agent is analyzing the report…" : "The agent is assessing cleanup safety…")).font(.callout)
                            Spacer()
                            Button("Stop") { model.cancelAnalysis() }
                        } else {
                            Button(model.reviewingCandidates ? "Review and Find More Candidates" : (model.analysisEntry == nil ? "Get Recommendations" : "Ask AI About Cleanup")) { model.analyze() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Copy Request") {
                                model.copy(model.analysisPrompt)
                            }.controlSize(.large)
                        }
                    }
                }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                DisclosureGroup("Request Preview") {
                    if model.analysisReport != nil {
                        ScrollView([.vertical, .horizontal]) {
                            Text(model.analysisPrompt)
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10)
                        }.frame(height: 220).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.font(.callout)
                if !model.recommendations.isEmpty {
                    HStack {
                        Text("Recommendations").font(.headline)
                        Spacer()
                        Button("Copy") { model.copy(model.recommendations) }
                    }
                    Text(model.recommendations).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                }
                if let result = model.candidateReviewResult, let snapshot = model.analysisReport {
                    candidateReviewChanges(result, review: CandidateReview(report: snapshot))
                }
                if let report = model.analysisReport, report.isPartial {
                    Label("This scan is preliminary or incomplete. The request will tell the agent about this limitation.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }

    private func candidateReviewChanges(_ result: CandidateReviewResult, review: CandidateReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggested Changes").font(.headline)
            if result.decisions.isEmpty { Text("AI suggested no changes. The current list is retained.").font(.callout) }
            ForEach(result.decisions) { decision in
                if let entry = review.entry(for: decision.id) {
                    VStack(alignment: .leading, spacing: 7) {
                        let title = (decision.action == .add ? "Add: " : decision.action == .remove ? "Remove from list: " : "Keep as candidate: ") + entry.name
                        if decision.action == .keep { Text(title).font(.callout.weight(.medium)) }
                        else {
                            Toggle(title, isOn: Binding(get: { model.selectedReviewIDs.contains(decision.id) }, set: { selected in
                                if selected { model.selectedReviewIDs.insert(decision.id) }
                                else { model.selectedReviewIDs.remove(decision.id) }
                            })).font(.callout.weight(.medium))
                        }
                        Text("\(entry.path) · \(SizeFormat.string(entry.allocatedBytes))").font(.caption.monospaced()).textSelection(.enabled)
                        Text(decision.reason).font(.callout)
                        Text(decision.caution).font(.caption).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text("Removing an item from the list only excludes it as a candidate; the files stay in place. Adding a candidate does not delete it either.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The separate removal button includes items marked “Keep as candidate” and selected “Add” suggestions. Review the paths before confirming Move to Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply Changes (\(model.selectedReviewIDs.count))") { model.applyCandidateReview() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedReviewIDs.isEmpty || model.workLocked || model.analyzing)
            aiRecommendedRemovalAction
        }
    }

    private var aiRecommendedRemovalAction: some View {
        let candidates = model.aiRecommendedCandidates
        return HStack(spacing: 12) {
            Button { model.requestAIRecommendedRemoval() } label: {
                Label("Remove AI-Recommended Items… (\(candidates.count))", systemImage: "trash")
            }
            .disabled(candidates.isEmpty || model.workLocked || model.analyzing)
            .help("Review Move to Trash for items explicitly recommended by AI. The search filter does not limit this list.")
            Text(candidates.isEmpty ? "Available after an AI review" : "\(SizeFormat.string(candidates.reduce(0) { $0 + $1.entry.allocatedBytes })) · confirm paths first")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
