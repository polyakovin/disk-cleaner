# Commercial-first working agreement

## Goal

Optimize for verified customer value and 30-day contribution margin per founder
hour. Code, features, followers, interviews and verbal enthusiasm are inputs,
not commercial outcomes.

## Source of truth

- `commercial-project.json` is the machine-readable source of truth.
- `COMMERCIAL.md` explains the current hypothesis.
- `EXPERIMENTS.md` records tests before and after execution.
- `DECISIONS.md` is an append-only `go`, `pivot` and `kill` log.

Run:

```bash
python3 scripts/commercial-project.py check .
```

## Gates

1. Do not start full product implementation before `idea`, `problem` and
   `money` are `go`.
2. Research notes, interview preparation, an offer, a landing page and a manual
   concierge delivery are allowed before product implementation when they are
   the smallest way to test the next gate.
3. A technical prototype before `money: go` requires an explicit decision in
   `DECISIONS.md`, a time budget and a reason a cheaper test cannot answer the
   question.
4. Missing evidence stays `pending`. Never convert assumptions or compliments
   into interviews, prepayments, customers or revenue.
5. Each experiment has a deadline, budget, metric and precommitted success,
   pivot and kill criteria.

## Data safety

- Do not commit customer names, phone numbers, email addresses, private
  messages, contracts, payment details, credentials or tokens.
- Store only anonymized aggregates and evidence references.
- External outreach, publication, invoicing and payment actions require
  explicit human authorization.
- Scarcity, deadlines, testimonials and economic claims must be truthful and
  verifiable.

## Engineering handoff

After `money: go`, define the smallest product change that removes a repeated
bottleneck from a paid manual delivery. Preserve the commercial evidence and
gate decisions in the implementation brief.

## Imported DiskLens application

- `DiskLens/` is the existing native macOS 14+ app, imported from an earlier chat; `DiskLens/AGENTS.md` defines its architecture and safety constraints.
- Swift 5.9+ and Xcode Command Line Tools or Xcode are required. No external Swift packages.
- Canonical checks: `python3 scripts/commercial-project.py check .`, `swift test --package-path DiskLens`, then `swift build --package-path DiskLens -c release`.
- Package with `bash DiskLens/scripts/build-app.sh "$PWD/build"` using an empty output directory. Verify the packaged app on macOS; ad-hoc signing does not establish Developer ID/notarization or Intel runtime validation.
- `skills/disk-space-report/` is the related portable diagnostic skill. Keep build artifacts and private scan reports out of Git.
- `docs/CONTEXT.md` preserves the imported chat context and validation limits. Importing existing assets does not advance commercial gates or authorize full product implementation.
