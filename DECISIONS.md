# Decisions — ai-disk-cleaner

Append new records. Do not delete or rewrite an earlier decision; supersede it
with a dated record and explanation.

## Decision template

### YYYY-MM-DD — [gate] — `go | pivot | kill`

- Context:
- Evidence refs:
- Decision:
- Rationale:
- Maximum next-step budget:
- Maximum next-step founder hours:
- Review/kill date:
- What would reverse this decision:

### 2026-10-09 — existing-asset migration — `go`

- Context: пользователь запросил перенос уже созданного DiskLens и контекста из чата `01a1202c-cf8d-70f3-896d-a4474a34025f` в этот репозиторий.
- Evidence refs: исходный чат; `docs/CONTEXT.md`; существующие исходники, тесты и универсальная сборка.
- Decision: сохранить приложение, связанный скилл и сводку контекста; проверить перенос и существующие тесты. Это разрешение на перенос активов, а не решение `go` по коммерческим воротам.
- Rationale: приложение уже создано до появления текущего коммерческого проекта. Перенос обеспечивает единое место хранения; новые функции и коммерческие доказательства не добавляются.
- Maximum next-step budget: 0 дополнительных денежных затрат.
- Maximum next-step founder hours: до 1 часа на перенос и проверку; разрешение не распространяется на дальнейшую разработку.
- Review/kill date: 2026-10-09, завершение переноса. После этого действуют обычные коммерческие ворота проекта.
- What would reverse this decision: отсутствующие исходники, несовпадение файлов или невосстановимая сборка. В этом случае сохранить исходные активы и зафиксировать ограничение.
- Commercial state: `idea`, `problem`, `money`, `delivery`, `scale` остаются `pending`; новых интервью, клиентов, оплат и выручки нет.
