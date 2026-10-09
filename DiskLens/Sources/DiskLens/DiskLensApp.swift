import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("DiskLens", id: "main") {
            MainView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .onDisappear { model.cancelWork() }
                .onAppear {
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--scan"), args.count > index + 1, model.report == nil, !model.scanning {
                        model.setTarget(URL(fileURLWithPath: args[index + 1])); model.scan()
                    }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Выбрать папку…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Сканировать") { model.scan() }.keyboardShortcut("r").disabled(model.scanning)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Подключение ИИ…") { model.showingSettings = true }.keyboardShortcut(",")
            }
        }
    }
}
