# ai-disk-cleaner

Commercial-first project created at `2026-10-09T10:36:36+00:00`.

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

## Validation

```bash
python3 scripts/commercial-project.py check .
python3 scripts/commercial-project.py check . --json
```

`pending` gates are allowed for a new project. A claimed `go` without the
required evidence fails validation.
