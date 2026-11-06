# Disk Manage

Disk Manage: нативное приложение для macOS 14+, которое показывает полное дерево файлов и папок с сортировкой по размеру, сохраняет измерения и обновляет изменённые ветви. Открывает объекты в Finder, позволяет перемещать выбранный объект в Корзину или удалять безвозвратно с подтверждением и передаёт отчёт подключённому ИИ для рекомендаций по очистке.

Прежнее название: DiskLens. Новые локальные сборки создаются как `Disk Manage.app`; исходники остаются в `DiskLens/`, технические идентификаторы сохраняют доступ к истории и настройкам. Опубликованный архив v0.1.0 пока содержит `DiskLens.app`.

Приложение и контекст перенесены из чата [«Найти, куда ушло место на диске»](codex://threads/01a1202c-cf8d-70f3-896d-a4474a34025f). Commercial-first project created at `2026-10-09T10:36:36+00:00`.

Язык приложения и сайта: английский. Интерфейс, сообщения, экспортируемые отчёты и новые рекомендации ИИ используют английский независимо от языка macOS. Опубликованный архив v0.1.0 пока содержит прежний русский интерфейс; английская версия собирается из текущих исходников.

## Приложение

- [Сайт и скачивание](https://diskmanage.pro/).
- [Инструкция, подключение ИИ и ограничения](DiskLens/README.md).
- [Контекст исходного чата и состояние проекта](docs/CONTEXT.md).
- Исходники: `DiskLens/`; связанный скилл: `skills/disk-space-report/`.
- Готовое приложение и архивы находятся локально в `build/`, вне Git. Запуск: `open "build/Disk Manage.app"`.

```bash
swift test --package-path DiskLens
swift build --package-path DiskLens -c release
bash DiskLens/scripts/build-app.sh "$PWD/build-new"
```

Скрипт требует пустого каталога вывода и собирает универсальное приложение для Apple Silicon и Intel с ad-hoc подписью. Для проверки CLI: `swift run --package-path DiskLens disklens-cli /path/to/folder --text`.

Сохранённое приложение не является подтверждением коммерческого спроса. Все ворота остаются `pending`; текущий перенос не запускает новую продуктовую разработку.

## Objective

Reach verified customer payment quickly, deliver the promised result manually
when possible, and automate only a repeated bottleneck.

The portfolio-level optimization target is:

```text
30-day contribution margin / founder hours
```

## Workflow

```text
idea → validation → presale → delivery → productize → scale
```

1. Fill `COMMERCIAL.md` and the hypothesis/scorecard in
   `commercial-project.json`.
2. Run `python3 scripts/commercial-project.py check .`.
3. Record interviews and experiments without personal data.
4. Request a real paid pilot or prepayment.
5. Mark a gate `go`, `pivot` or `kill` only with dated evidence.
6. Start full product implementation after `money: go`.

## Files

- `commercial-project.json` — stage, score, metrics and gates.
- `COMMERCIAL.md` — commercial thesis and offer.
- `EXPERIMENTS.md` — experiment ledger.
- `DECISIONS.md` — append-only decision log.
- `AGENTS.md` — operating and safety rules.
- `DiskLens/` — existing application, CLI and tests.
- `skills/disk-space-report/` — portable disk diagnosis skill.
- `docs/CONTEXT.md` — imported context and verification limits.

## Validation

```bash
python3 scripts/commercial-project.py check .
python3 scripts/commercial-project.py check . --json
```

`pending` gates are allowed for a new project. A claimed `go` without the
required evidence fails validation.
