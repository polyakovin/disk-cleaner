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
            Label("Один доступ к папкам", systemImage: "lock.open")
                .font(.title2.weight(.semibold))
            Text("Включите для DiskLens «Полный доступ к диску», чтобы macOS не спрашивала отдельно о «Загрузках», «Документах» и «Рабочем столе».")
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Откройте системные настройки доступа кнопкой ниже.")
                Text("2. Включите DiskLens. Если его нет в списке, нажмите «+» и выберите эту копию приложения или перетащите её из Finder.")
                Text("3. Если macOS предложит перезапустить DiskLens, сделайте это. Затем повторите сканирование.")
            }.font(.callout)
            if let appURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Эта копия DiskLens").font(.caption).foregroundStyle(.secondary)
                    Text(appURL.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Показать приложение в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                }
            } else {
                Text("Для настройки доступа запустите собранное приложение DiskLens.app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Доступ включает защищённые данные других приложений. Выбор хранит macOS; его можно отозвать в тех же настройках. После замены сборки система может запросить разрешение снова.")
                .font(.caption).foregroundStyle(.secondary)
            if openingFailed {
                Text("Откройте «Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску» вручную.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть настройки доступа") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    openingFailed = !NSWorkspace.shared.open(url)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 560).fixedSize(horizontal: false, vertical: true)
    }
}
