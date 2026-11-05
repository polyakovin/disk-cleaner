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
        Window("DiskLens", id: "main") {
            MainView(model: model)
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
                Button("Выбрать папку…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.workLocked)
                Button("Сканировать") { model.scan() }.keyboardShortcut("r").disabled(model.workLocked)
                Button("Пересканировать полностью") { model.scan(forceFull: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.workLocked)
            }
            CommandGroup(after: .pasteboard) {
                Button("Переместить в Корзину…") {
                    if let selected = model.selected { model.requestRemoval(selected) }
                }.keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selected == nil || model.interactionLocked)
                Button("Удалить безвозвратно…") {
                    if let selected = model.selected { model.requestRemoval(selected, mode: .permanent) }
                }.keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(model.selected == nil || model.interactionLocked)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Доступ к диску…") { model.showingDiskAccess = true }.disabled(model.interactionLocked)
                Button("Подключение ИИ…") { model.showingSettings = true }.keyboardShortcut(",")
            }
        }
    }
}
