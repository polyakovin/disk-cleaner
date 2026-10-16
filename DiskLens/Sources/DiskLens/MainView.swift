import SwiftUI
import AppKit
import DiskLensCore

private let accent = Color(red: 0.06, green: 0.52, blue: 0.48)

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var kindFilter = "Все"
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.scanning { progress }
                if model.report != nil { resultContent }
                else { emptyState }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .tint(accent)
        .sheet(isPresented: $model.showingSettings) { AgentSettingsView(model: model) }
        .alert("DiskLens", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Понятно", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DiskLens").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Место под контролем").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 14)
            VStack(spacing: 5) {
                ForEach(Pane.allCases) { pane in
                    Button {
                        model.pane = pane; model.selection = nil; model.search = ""
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
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            if let capacity = model.capacity {
                VStack(alignment: .leading, spacing: 11) {
                    HStack { Image(systemName: "internaldrive"); Text(capacity.name).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(SizeFormat.string(capacity.freeBytes)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    }
                    Text("свободно на томе").font(.caption).foregroundStyle(.secondary)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(accent.opacity(0.15))
                            Capsule().fill(accent).frame(width: g.size.width * max(0, min(1, capacity.usedFraction)))
                        }
                    }.frame(height: 5)
                }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            Button { model.showingSettings = true } label: {
                Label("Подключение ИИ", systemImage: "slider.horizontal.3").font(.caption)
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 12)
        }.padding(.horizontal, 16).background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.pane.rawValue).font(.system(size: 25, weight: .semibold, design: .rounded))
                Menu {
                    Button("Домашняя папка") { model.setTarget(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Весь Mac") { model.setTarget(URL(fileURLWithPath: "/System/Volumes/Data")) }
                    Button("Выбрать папку…") { model.chooseFolder() }
                } label: { Label(model.targetName, systemImage: "folder").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.scanning)
            }
            Spacer()
            if model.report != nil {
                Menu {
                    Button("Экспортировать JSON…") { model.export(json: true) }
                    Button("Экспортировать текст…") { model.export(json: false) }
                    Button("Скопировать отчёт") { if let report = model.report { model.copy(report.text()) } }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                .help("Экспортировать отчёт")
            }
            if model.scanning {
                Button("Остановить", role: .cancel) { model.cancelScan() }.buttonStyle(.bordered)
            } else {
                Button { model.scan() } label: { Label("Сканировать", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var progress: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("Сканирование · \(model.scanProgress?.items ?? 0) объектов · \(SizeFormat.string(model.scanProgress?.allocatedBytes ?? 0))").font(.callout)
                Text(model.scanProgress?.currentPath ?? model.target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
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
                Text("Куда уходит место?").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Проверьте диск, найдите крупные папки\nи получите рекомендации по очистке.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(model.target.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Выбрать папку…") { model.chooseFolder() }.buttonStyle(.bordered).controlSize(.large)
                Button("Начать сканирование") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.disabled(model.scanning)
            Spacer()
            HStack(spacing: 28) {
                Label("Только метаданные", systemImage: "doc.text.viewfinder")
                Label("Без удаления файлов", systemImage: "checkmark.shield")
                Label("Работает локально", systemImage: "laptopcomputer")
            }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 30)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var resultContent: some View {
        if model.pane == .assistant { assistant }
        else {
            VStack(spacing: 18) {
                metrics
                if let report = model.report, report.isPartial {
                    HStack(spacing: 9) {
                        Image(systemName: "info.circle").foregroundStyle(.orange)
                        Text(report.cancelled ? "Замер остановлен. Показаны найденные данные; итоговый размер неполный." : "Не удалось проверить объектов: \(report.issueCount). Размеры могут быть занижены.")
                        Spacer()
                        Button("Доступ к диску") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.buttonStyle(.link)
                    }.font(.caption).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                tableHeader
                if entries.isEmpty { emptyList }
                else { entryTable }
                footer
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric("Найдено в замере", value: SizeFormat.string(model.report?.root.allocatedBytes ?? 0), icon: "chart.pie", color: accent)
            metric("Файлов", value: (model.report?.root.fileCount ?? 0).formatted(), icon: "doc.on.doc", color: .blue)
            metric("Кандидаты на очистку", value: SizeFormat.string(model.report?.candidateBytes ?? 0), icon: "archivebox", color: .orange)
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
                        if !model.navigation.isEmpty { model.navigation.removeLast(); model.selection = nil; model.search = "" }
                    } label: { Image(systemName: "chevron.left") }.disabled(model.navigation.isEmpty)
                    Text(model.current?.path ?? "").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else { Text(model.pane == .files ? "100 крупнейших файлов в замере" : "Известные каталоги кэшей").font(.headline) }
                Spacer()
                TextField("Поиск в отчёте", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            if model.pane == .candidates {
                Text("Проверьте содержимое перед очисткой. Кэш может потребоваться скачать или создать заново; указанный объём не гарантирует такое же освобождение места.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.pane == .overview {
                HStack {
                    Picker("Тип", selection: $kindFilter) { ForEach(["Все", "Папки", "Файлы"], id: \.self) { Text($0) } }
                        .pickerStyle(.segmented).frame(width: 235)
                    Spacer()
                    Text("По размеру · выделенные блоки").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entries: [DiskEntry] {
        var list: [DiskEntry]
        switch model.pane {
        case .files: list = model.report?.largestFiles ?? []
        case .candidates: list = model.report?.candidates.map(\.entry) ?? []
        default:
            list = model.current?.children ?? []
            if kindFilter == "Папки" { list = list.filter(\.isFolder) }
            if kindFilter == "Файлы" { list = list.filter { $0.kind == .file } }
        }
        if !model.search.isEmpty { list = list.filter { $0.path.localizedCaseInsensitiveContains(model.search) } }
        return list
    }

    private var entryTable: some View {
        Table(entries, selection: $model.selection) {
            TableColumn("Имя") { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isFolder ? "folder.fill" : (entry.kind == .symlink ? "link" : "doc.fill"))
                        .foregroundStyle(entry.isFolder ? accent.opacity(0.8) : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if model.pane != .overview { Text(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture(count: entry.isFolder ? 1 : 2) { model.navigate(entry); if entry.isFolder { model.pane = .overview } }
            }.width(min: 230, ideal: 350)
            TableColumn("Размер") { entry in Text(SizeFormat.string(entry.allocatedBytes)).monospacedDigit().fontWeight(.medium) }.width(100)
            TableColumn("Доля") { entry in
                let denominator = model.pane == .overview ? (model.current?.allocatedBytes ?? 0) : (model.report?.root.allocatedBytes ?? 0)
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
                    if entry.issueCount > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Размер неполный: часть объектов недоступна") }
                    Button { model.reveal(entry) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Показать в Finder")
                    Menu {
                        Button("Показать в Finder") { model.reveal(entry) }
                        Button("Скопировать путь") { model.copy(entry.path) }
                        if entry.isFolder {
                            Button("Открыть папку") { model.navigate(entry); model.pane = .overview }
                            Button("Сканировать эту папку") { model.setTarget(URL(fileURLWithPath: entry.path)); model.scan() }.disabled(model.scanning)
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
            }.width(70)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyList: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.search.isEmpty ? "В этом разделе пока нет объектов" : "Совпадений в сохранённом отчёте нет").font(.headline)
            if model.pane == .overview, let current = model.current, current.childCount > 0, current.children.isEmpty {
                Text("Для этой глубины сохранён общий размер. Просканируйте папку отдельно, чтобы увидеть содержимое.").font(.caption).foregroundStyle(.secondary)
                Button("Сканировать папку") { model.setTarget(URL(fileURLWithPath: current.path)); model.scan() }.disabled(model.scanning)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let report = model.report {
                    Text("Замер \(report.measuredAt.formatted(date: .omitted, time: .shortened)) · \(Int(report.durationSeconds)) с · ничего не удалено").font(.caption2)
                }
                if model.pane == .overview, let current = model.current, current.childCount > current.children.count {
                    Text("Сохранены \(current.children.count) крупнейших из \(current.childCount) объектов этой папки").font(.caption2)
                } else { Text("APFS-клоны и снимки могут влиять на фактически освобождаемое место").font(.caption2) }
            }.foregroundStyle(.secondary)
            Spacer()
            if let selected = model.selected { Button("В Finder") { model.reveal(selected) }.controlSize(.small) }
            Button("Анализ ИИ") { model.pane = .assistant }.controlSize(.small)
        }
    }

    private var assistant: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(accent).padding(18).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("План освобождения места").font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text("Агент оценит отчёт и предложит порядок действий.\nРекомендации останутся текстом, без выполнения команд.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(model.agentName, systemImage: model.settings.mode == .api ? "network" : "terminal").font(.headline)
                        Spacer()
                        Button("Настроить") { model.showingSettings = true }.disabled(model.analyzing)
                    }
                    Text(model.settings.mode == .api ? "По кнопке анализа отчёт будет отправлен на \(model.settings.endpoint)." : "По кнопке анализа отчёт будет передан выбранному агенту через stdin.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Передаются пути, размеры и ограничения замера. Содержимое файлов не передаётся.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if model.analyzing {
                            ProgressView().controlSize(.small)
                            Text("Агент анализирует отчёт…").font(.callout)
                            Spacer()
                            Button("Остановить") { model.cancelAnalysis() }
                        } else {
                            Button("Получить рекомендации") { model.analyze() }.buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Скопировать запрос") {
                                if let prompt = try? model.report?.agentPrompt(anonymizeHome: model.settings.anonymizeHome) { model.copy(prompt) }
                            }.controlSize(.large)
                        }
                    }
                }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                DisclosureGroup("Передаваемый отчёт") {
                    if let report = model.report {
                        ScrollView([.vertical, .horizontal]) {
                            Text((try? report.json(anonymizeHome: model.settings.anonymizeHome, compactForAgent: true)) ?? "")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10)
                        }.frame(height: 220).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.font(.callout)
                if !model.recommendations.isEmpty {
                    HStack {
                        Text("Рекомендации").font(.headline)
                        Spacer()
                        Button("Скопировать") { model.copy(model.recommendations) }
                    }
                    Text(model.recommendations).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                }
                if let report = model.report, report.isPartial {
                    Label("Агенту передано, что замер неполный. Для точных рекомендаций повторите его с нужным доступом.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
