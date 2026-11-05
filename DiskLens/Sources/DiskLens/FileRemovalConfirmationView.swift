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
            Text("Размер в замере: \(SizeFormat.string(request.entry.allocatedBytes)).").foregroundStyle(.secondary)
            if request.entry.isFolder {
                Text(request.mode == .permanent
                     ? "Папка будет удалена целиком со всем содержимым, включая объекты, которых нет в таблице."
                     : "Папка будет перемещена целиком со всем содержимым, включая объекты, которых нет в таблице.")
            }
            if request.entry.kind == .symlink {
                Text(request.mode == .permanent
                     ? "Будет удалена сама символическая ссылка, а не объект, на который она указывает."
                     : "Будет перемещена сама символическая ссылка, а не объект, на который она указывает.")
            }
            if request.mode == .permanent {
                Text("Объект будет удалён сразу, минуя Корзину. Отменить удаление или восстановить объект из Корзины нельзя.")
                    .font(.callout.weight(.semibold)).foregroundStyle(.red)
            } else {
                Text("Восстановить объект можно из Корзины в Finder. Место обычно освобождается после очистки Корзины.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Для облачных папок удаление может распространиться на другие устройства.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(request.mode.actionTitle, role: .destructive, action: confirm)
            }
        }.padding(24).frame(width: 500)
    }
}
