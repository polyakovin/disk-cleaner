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
            Button("Понятно", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Manage").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Место под контролем").font(.caption).foregroundStyle(.secondary)
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
                    Text("свободно на томе").font(.caption).foregroundStyle(.secondary)
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
                    Label("Доступ к диску…", systemImage: "lock.open").font(.caption)
                }.disabled(model.interactionLocked)
                Button { model.showingSettings = true } label: {
                    Label("Подключение ИИ", systemImage: "slider.horizontal.3").font(.caption)
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 12)
        }.padding(.horizontal, 16).background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.pane.rawValue).font(.system(size: 25, weight: .semibold, design: .rounded))
                Menu {
                    Button("Домашняя папка") { model.openLocation(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Весь Mac") { model.openLocation(URL(fileURLWithPath: "/System/Volumes/Data")) }
                    Button("Корень файловой системы") { model.openLocation(URL(fileURLWithPath: "/")) }
                    Button("Выбрать папку…") { model.chooseFolder() }
                } label: { Label(model.targetName, systemImage: "folder").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.interactionLocked)
            }
            Spacer()
            if model.report != nil {
                Menu {
                    Button("Экспортировать JSON…") { model.export(json: true) }
                    Button("Экспортировать текст…") { model.export(json: false) }
                    Button("Скопировать отчёт") { if let report = model.report { model.copy(report.text()) } }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                .help("Экспортировать отчёт")
                .accessibilityLabel("Экспортировать отчёт")
                .disabled(model.workLocked)
            }
            if model.scanning {
                Button("Остановить", role: .cancel) { model.cancelScan() }.buttonStyle(.bordered)
            } else {
                Button { if let current = model.current { model.scanFolder(current) } else { model.scan() } } label: { Label("Обновить размеры", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.workLocked)
                    .contextMenu {
                        Button("Пересканировать полностью") { model.scan(forceFull: true) }.disabled(model.workLocked)
                    }
            }
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сканирование · \(model.scanProgress?.items ?? 0) объектов · \(SizeFormat.string(model.scanProgress?.allocatedBytes ?? 0))").font(.callout)
                    Text(model.scanProgress?.currentPath ?? model.target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            Text((model.scanProgress?.reusedFolders ?? 0) > 0
                 ? "Из прошлого замера: \(model.scanProgress?.reusedFolders ?? 0) папок. Обновляем изменённые ветви."
                 : model.scanProgress?.usesPreviousScan == true
                 ? "Проверяем изменения. Известные размеры остаются видны."
                 : "Известные размеры сохранены. Размеры новых папок уточняются по мере обхода.")
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
                Text("Куда уходит место?").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Проверьте диск, найдите крупные папки\nи получите рекомендации по очистке.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(model.target.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Выбрать папку…") { model.chooseFolder() }.buttonStyle(.bordered).controlSize(.large)
                Button("Начать сканирование") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.disabled(model.scanning)
            Button("Настроить общий доступ к папкам…") { model.showingDiskAccess = true }
                .buttonStyle(.link)
            Spacer()
            HStack(spacing: 28) {
                Label("Только метаданные", systemImage: "doc.text.viewfinder")
                Label("Удаление в Корзину", systemImage: "trash")
                Label("Работает локально", systemImage: "laptopcomputer")
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
                        Text(report.cancelled ? "Замер остановлен. Показаны найденные данные; итоговый размер неполный." : "Не удалось проверить объектов: \(report.issueCount). Размеры могут быть занижены.")
                        Spacer()
                        Button("Доступ к диску") {
                            model.showingDiskAccess = true
                        }.buttonStyle(.link)
                    }.font(.caption).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                tableHeader
                if model.pane == .overview, let error = model.treeError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Доступ к диску") { model.showingDiskAccess = true }.buttonStyle(.link)
                    }
                }
                if entries.isEmpty { emptyList }
                else { entryTable }
                if model.pane == .overview, let page = model.treePage, page.total > model.treeLimit {
                    HStack {
                        Text("\(model.treeOffset + 1)–\(min(page.total, model.treeOffset + page.entries.count)) из \(page.total) объектов").font(.caption)
                        Spacer()
                        Button("Предыдущие") { model.treeOffset = max(0, model.treeOffset - model.treeLimit) }.disabled(model.treeOffset == 0)
                        Button("Следующие") { model.treeOffset += model.treeLimit }.disabled(model.treeOffset + model.treeLimit >= page.total)
                    }
                }
                safetyAction
                footer
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric("Найдено в замере", value: SizeFormat.string(model.displayedReport?.root.allocatedBytes ?? 0), icon: "chart.pie", color: accent)
            metric("Файлов", value: (model.displayedReport?.root.fileCount ?? 0).formatted(), icon: "doc.on.doc", color: .blue)
            Button {
                model.pane = .candidates; model.selection = nil; model.search = ""
            } label: {
                metric("Кандидаты на очистку", value: SizeFormat.string(model.displayedReport?.candidateBytes ?? 0), icon: "archivebox", color: .orange)
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.orange.opacity(candidatesHovered ? 0.5 : 0)))
                    .contentShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .onHover { candidatesHovered = $0 }
            .help("Показать кандидатов на очистку")
            .accessibilityLabel("Кандидаты на очистку")
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
                    .help("Вернуться к родительской папке")
                    .accessibilityLabel("Вернуться к родительской папке")
                    Text(model.openedPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else { Text(model.pane == .files ? "100 крупнейших файлов в замере" : "Кандидаты из замера").font(.headline) }
                Spacer()
                TextField("Поиск в отчёте", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            if model.pane == .candidates {
                Text("Проверьте содержимое перед очисткой. Кэш может потребоваться скачать или создать заново; указанный объём не гарантирует такое же освобождение места.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { model.prepareCandidateReview() } label: {
                        Label("Пересмотреть с ИИ", systemImage: "sparkles")
                    }.disabled(model.workLocked || model.analyzing)
                    Text("Проверить список и найти другие кандидаты в общем замере")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Всех в Корзину…", role: .destructive) { model.requestCandidateRemoval() }
                        Button("Всех безвозвратно…", role: .destructive) { model.requestCandidateRemoval(mode: .permanent) }
                    } label: {
                        Label("Удалить всех… (\(model.displayedReport?.candidates.count ?? 0))", systemImage: "trash")
                    }.fixedSize().disabled(model.interactionLocked || model.displayedReport?.candidates.isEmpty != false)
                    .help("Удалить весь список кандидатов, независимо от поиска. Сначала откроется подтверждение всех путей.")
                }
                aiRecommendedRemovalAction
            } else if model.pane == .overview {
                HStack {
                    Picker("Тип", selection: $model.treeKind) {
                        Text("Все").tag(EntryKind?.none)
                        Text("Папки").tag(EntryKind?.some(.folder))
                        Text("Файлы").tag(EntryKind?.some(.file))
                    }
                        .pickerStyle(.segmented).frame(width: 235)
                    Spacer()
                    Picker("Сортировка", selection: $model.treeOrder) {
                        ForEach(FileTreeOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 175)
                    Text("Выделенные блоки").font(.caption).foregroundStyle(.secondary)
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
            TableColumn("Имя") { entry in
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
            TableColumn("Размер") { entry in
                Text(entry.sizeIsKnown == false ? "Уточняется" : SizeFormat.string(entry.allocatedBytes))
                    .monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(entry.sizeIsKnown == false ? .secondary : .primary)
            }.width(110)
            TableColumn("Доля") { entry in
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
                    if entry.issueCount > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Размер неполный: часть объектов недоступна") }
                    Button { model.reveal(entry) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Показать в Finder")
                        .accessibilityLabel("Показать в Finder: \(entry.name)")
                    Button { model.prepareAnalysis(for: entry) } label: { Image(systemName: "sparkles") }
                        .buttonStyle(.borderless).help("Спросить нейронку, безопасно ли это удалять")
                        .accessibilityLabel("Спросить нейронку, безопасно ли это удалять: \(entry.name)")
                        .disabled(model.interactionLocked || model.analyzing)
                    Menu {
                        Button("Показать в Finder") { model.reveal(entry) }
                        Button("Скопировать путь") { model.copy(entry.path) }
                        Button("Спросить нейронку, безопасно ли это удалять") { model.prepareAnalysis(for: entry) }
                            .disabled(model.interactionLocked || model.analyzing)
                        if entry.isFolder {
                            Button("Открыть папку") { model.navigate(entry); model.pane = .overview }.disabled(model.interactionLocked)
                            Button("Сканировать эту папку") { model.scanFolder(entry) }.disabled(model.interactionLocked)
                        }
                        Divider()
                        Button("Переместить в Корзину…", role: .destructive) { model.requestRemoval(entry) }
                            .disabled(model.interactionLocked)
                        Button("Удалить безвозвратно…", role: .destructive) { model.requestRemoval(entry, mode: .permanent) }
                            .disabled(model.interactionLocked)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Действия с объектом")
                    .accessibilityLabel("Действия с объектом: \(entry.name)")
                }
            }.width(100)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyList: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.loadingTree ? "Открываем папку…" : model.search.isEmpty ? "В папке нет доступных объектов" : "Совпадений нет").font(.headline)
            if let error = model.treeError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var safetyAction: some View {
        let entry = model.selected ?? (model.pane == .overview ? model.current : nil)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.name ?? "Выберите файл или папку").font(.callout.weight(.medium)).lineLimit(1)
                Text(entry?.path ?? "Вопрос будет о выбранном объекте")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let entry { model.prepareAnalysis(for: entry) }
            } label: {
                Label("Спросить нейронку, безопасно ли это удалять", systemImage: "sparkles")
            }.disabled(entry == nil || model.interactionLocked || model.analyzing)
        }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if model.scanning {
                    Text("Обновляем размеры · известные данные остаются доступны").font(.caption2)
                } else if let report = model.report {
                    Text("Последний замер: \(report.measuredAt.formatted(date: .abbreviated, time: .shortened)) · \(Int(report.durationSeconds)) с").font(.caption2)
                    if let reuse = report.scanReuse, reuse.reusedFolders > 0 {
                        Text("Из прошлого замера: \(reuse.reusedFolders) папок · проверено заново: \(reuse.inspectedItems) объектов").font(.caption2)
                    }
                }
                if model.removing { Text(model.removalMode?.progressTitle ?? "Удаление…").font(.caption).foregroundStyle(accent) }
                else if let status = model.removalStatus { Text(status).font(.caption).textSelection(.enabled) }
                if model.pane == .overview, let page = model.treePage {
                    Text("\(page.total) объектов · " + (model.automaticRefreshPaused ? "обновление остановлено" : model.automaticRefreshAvailable
                         ? "изменения проверяются автоматически" : "журнал недоступен, размеры обновляются по кнопке")).font(.caption2)
                } else { Text("APFS-клоны и снимки могут влиять на фактически освобождаемое место").font(.caption2) }
            }.foregroundStyle(.secondary)
            Spacer()
            if let selected = model.selected {
                Button("В Finder") { model.reveal(selected) }.controlSize(.small)
                Menu {
                    Button("Переместить в Корзину…", role: .destructive) { model.requestRemoval(selected) }
                    Button("Удалить безвозвратно…", role: .destructive) { model.requestRemoval(selected, mode: .permanent) }
                } label: { Label("Удалить…", systemImage: "trash") }
                    .controlSize(.small).disabled(model.interactionLocked)
            }
            Button("Анализ ИИ") { model.prepareAnalysis(for: nil) }.controlSize(.small).disabled(model.interactionLocked || model.analyzing)
        }
    }

    private var assistant: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(accent).padding(18).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.reviewingCandidates ? "Пересмотр кандидатов с ИИ" : (model.analysisEntry == nil ? "План освобождения места" : "Безопасно ли это удалять?")).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(model.reviewingCandidates
                             ? "Агент проверит текущих кандидатов и предложит других из общего замера.\nПросмотрите предложения и примените выбранные изменения."
                             : model.analysisEntry == nil
                             ? "Агент оценит отчёт и предложит порядок действий.\nРекомендации останутся текстом, без выполнения команд."
                             : "Агент предложит, что очистить, что сохранить\nи что проверить для принятия решения.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if model.reviewingCandidates, let report = model.analysisReport {
                    let review = CandidateReview(report: report)
                    Text("Объектов для проверки: \(review.entries.count), текущих кандидатов: \(report.candidates.count). Крупнейшие объекты сохранённого дерева и списка файлов; содержимое файлов неизвестно.\(review.omittedCount > 0 ? " За пределами запроса: \(review.omittedCount) объектов." : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Вернуться к кандидатам") { model.pane = .candidates }.buttonStyle(.link)
                }
                if let entry = model.analysisEntry {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc").font(.headline)
                            Spacer()
                            Button("Весь отчёт") { model.prepareAnalysis(for: nil) }.disabled(model.analyzing)
                        }
                        Text(entry.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Размер в замере: \(SizeFormat.string(entry.allocatedBytes)). Для разбора используются состав папки, крупные файлы и найденные внутри кандидаты на очистку.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
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
                        if model.preparingAnalysis {
                            ProgressView().controlSize(.small)
                            Text("Уточняем состав выбранной папки…").font(.callout)
                            Spacer()
                            Button("Остановить") { model.cancelAnalysis() }
                        } else if model.analyzing {
                            ProgressView().controlSize(.small)
                            Text(model.reviewingCandidates ? "Агент пересматривает кандидатов…" : (model.analysisEntry == nil ? "Агент анализирует отчёт…" : "Агент оценивает безопасность удаления…")).font(.callout)
                            Spacer()
                            Button("Остановить") { model.cancelAnalysis() }
                        } else {
                            Button(model.reviewingCandidates ? "Проверить кандидатов и найти ещё" : (model.analysisEntry == nil ? "Получить рекомендации" : "Спросить нейронку, безопасно ли это удалять")) { model.analyze() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Скопировать запрос") {
                                model.copy(model.analysisPrompt)
                            }.controlSize(.large)
                        }
                    }
                }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                DisclosureGroup("Передаваемый запрос") {
                    if model.analysisReport != nil {
                        ScrollView([.vertical, .horizontal]) {
                            Text(model.analysisPrompt)
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
                if let result = model.candidateReviewResult, let snapshot = model.analysisReport {
                    candidateReviewChanges(result, review: CandidateReview(report: snapshot))
                }
                if let report = model.analysisReport, report.isPartial {
                    Label("Это предварительный или неполный замер. В запросе агенту будет указано это ограничение.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }

    private func candidateReviewChanges(_ result: CandidateReviewResult, review: CandidateReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Предложения к списку").font(.headline)
            if result.decisions.isEmpty { Text("ИИ не предложил изменений. Текущий список сохранён.").font(.callout) }
            ForEach(result.decisions) { decision in
                if let entry = review.entry(for: decision.id) {
                    VStack(alignment: .leading, spacing: 7) {
                        let title = (decision.action == .add ? "Добавить: " : decision.action == .remove ? "Убрать из списка: " : "Оставить в кандидатах: ") + entry.name
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
            Text("Убрать из списка означает исключить кандидата, файлы останутся на месте. Добавление кандидата тоже не удаляет его.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Отдельная кнопка удаления включает «Оставить в кандидатах» и отмеченные «Добавить». Сначала откроется список путей для подтверждения переноса в Корзину.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Применить изменения (\(model.selectedReviewIDs.count))") { model.applyCandidateReview() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedReviewIDs.isEmpty || model.workLocked || model.analyzing)
            aiRecommendedRemovalAction
        }
    }

    private var aiRecommendedRemovalAction: some View {
        let candidates = model.aiRecommendedCandidates
        return HStack(spacing: 12) {
            Button { model.requestAIRecommendedRemoval() } label: {
                Label("Удалить рекомендованное ИИ… (\(candidates.count))", systemImage: "trash")
            }
            .disabled(candidates.isEmpty || model.workLocked || model.analyzing)
            .help("Открыть подтверждение переноса в Корзину только явно рекомендованных ИИ объектов. Поиск не ограничивает список.")
            Text(candidates.isEmpty ? "Появятся после ИИ-пересмотра" : "\(SizeFormat.string(candidates.reduce(0) { $0 + $1.entry.allocatedBytes })) · с подтверждением путей")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
