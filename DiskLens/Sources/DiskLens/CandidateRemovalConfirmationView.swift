import SwiftUI
import DiskLensCore

struct CandidateRemovalConfirmationView: View {
    let request: CandidateRemovalRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.scope == .aiRecommended
                 ? request.mode == .permanent ? "Удалить рекомендованное ИИ безвозвратно?" : "Переместить рекомендованное ИИ в Корзину?"
                 : request.mode == .permanent ? "Удалить всех кандидатов безвозвратно?" : "Переместить всех кандидатов в Корзину?")
                .font(.title2.bold())
            Text("Доступно: \(request.requests.count) из \(request.requests.count + request.unavailable.count) · Размер: \(SizeFormat.string(request.totalBytes))")
                .font(.headline)
            Text(request.scope == .aiRecommended
                 ? "Только явно рекомендованные ИИ объекты из списка ниже. Остальные кандидаты останутся на месте. Папки обрабатываются целиком со всем содержимым."
                 : "Весь список кандидатов, независимо от поиска. Папки обрабатываются целиком со всем содержимым.")
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
                            Label("Пропустить: \(item.entry.name)", systemImage: "exclamationmark.shield").font(.callout.weight(.medium))
                            Text(item.entry.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }.padding(12)
            }.frame(height: 240).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            Text(request.mode == .permanent
                 ? "Все перечисленные объекты будут удалены сразу, минуя Корзину. Отменить удаление нельзя."
                 : "Восстановить объекты можно из Корзины в Finder. Место обычно освобождается после очистки Корзины.")
                .font(.callout.weight(.semibold)).foregroundStyle(request.mode == .permanent ? .red : .primary)
            Text("Для облачных папок удаление может распространиться на другие устройства. Размер не гарантирует такое же освобождение места. При первой ошибке обработка остановится; уже выполненные действия сохранятся.")
                .font(.caption).foregroundStyle(.secondary)
            if !request.unavailable.isEmpty {
                Text("Будет пропущено: \(request.unavailable.count). Причины указаны в конце списка. Удалятся только доступные объекты.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(request.mode == .permanent ? "Удалить доступные безвозвратно" : "Доступные в Корзину", role: .destructive, action: confirm)
                    .disabled(request.requests.isEmpty)
            }
        }.padding(24).frame(width: 600)
    }
}
