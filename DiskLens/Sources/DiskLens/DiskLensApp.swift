import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--history-directory"), args.count > index + 1 {
            return AppModel(scanHistory: .init(directory: URL(fileURLWithPath: args[index + 1])))
        }
        return AppModel()
    }()
    var body: some Scene {
        Window("Disk Manage", id: "main") {
            MainView(model: model)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(minWidth: 980, minHeight: 640)
                .onDisappear { model.cancelWork() }
                .onAppear {
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--scan"), args.count > index + 1, !model.scanning {
                        model.setTarget(URL(fileURLWithPath: args[index + 1])); model.scan()
                    }
                    model.startFileBrowser()
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.workLocked)
                Button("Scan") { model.scan() }.keyboardShortcut("r").disabled(model.workLocked)
                Button("Rescan Everything") { model.scan(forceFull: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.workLocked)
            }
            CommandGroup(after: .pasteboard) {
                Button("Move to Trash…") {
                    if let selected = model.selected { model.requestRemoval(selected) }
                }.keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selected == nil || model.interactionLocked)
                Button("Delete Permanently…") {
                    if let selected = model.selected { model.requestRemoval(selected, mode: .permanent) }
                }.keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(model.selected == nil || model.interactionLocked)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Disk Access…") { model.showingDiskAccess = true }.disabled(model.interactionLocked)
                Button("AI Connection…") { model.showingSettings = true }.keyboardShortcut(",")
            }
        }
    }
}
