#!/usr/bin/env python3
"""Create and validate commercial-first project starters using stdlib only."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MIN_PYTHON = (3, 10)
if sys.version_info < MIN_PYTHON:
    sys.stderr.write(
        f"Python >= {MIN_PYTHON[0]}.{MIN_PYTHON[1]} required, got "
        f"{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}\n"
    )
    raise SystemExit(1)


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_ROOT = ROOT / "templates" / "commercial-project"
CONFIG_NAME = "commercial-project.json"
STAGES = (
    "idea",
    "validation",
    "presale",
    "delivery",
    "productize",
    "scale",
    "archived",
)
GATE_NAMES = ("idea", "problem", "money", "delivery", "scale")
DECISIONS = ("pending", "go", "pivot", "kill")
SCORE_WEIGHTS = {
    "pain_urgency": 5,
    "buyer_access": 4,
    "budget_evidence": 4,
    "seven_day_delivery": 3,
    "gross_margin_potential": 2,
    "repeatability": 2,
    "risk_penalty": -4,
}
STAGE_PREREQUISITES = {
    "idea": (),
    "validation": ("idea",),
    "presale": ("idea", "problem"),
    "delivery": ("idea", "problem", "money"),
    "productize": ("idea", "problem", "money", "delivery"),
    "scale": ("idea", "problem", "money", "delivery", "scale"),
    "archived": (),
}
REQUIRED_METRICS = (
    "contacts",
    "interviews",
    "problem_confirmations",
    "offers",
    "prepayments",
    "cash_collected",
    "paid_customers",
    "accepted_deliveries",
    "repeat_or_referral_customers",
    "revenue_30d",
    "direct_costs_30d",
    "founder_hours_30d",
)
TEXT_TEMPLATES = (
    "AGENTS.md",
    "README.md",
    "COMMERCIAL.md",
    "EXPERIMENTS.md",
    "DECISIONS.md",
)


class CommercialProjectError(Exception):
    """Raised for deterministic starter or validation failures."""


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value)


def _metric(metrics: dict[str, Any], field: str) -> int | float:
    value = metrics.get(field)
    return value if _is_number(value) else 0


def _mapping(value: Any, name: str, errors: list[str]) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    errors.append(f"{name} must be an object")
    return {}


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def calculate_score(scorecard: dict[str, Any], errors: list[str]) -> int:
    score = 0
    for field, weight in SCORE_WEIGHTS.items():
        value = scorecard.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 5:
            errors.append(f"scorecard.{field} must be an integer from 0 to 5")
            continue
        score += value * weight
    return max(0, min(100, score))


def _gate_issues(
    gate_name: str,
    score: int,
    hypothesis: dict[str, Any],
    metrics: dict[str, Any],
) -> list[str]:
    issues: list[str] = []
    if gate_name == "idea":
        if not _nonempty(hypothesis.get("customer")):
            issues.append("customer is required")
        if not _nonempty(hypothesis.get("problem")):
            issues.append("problem is required")
        if not _nonempty(hypothesis.get("first_cash_deadline")):
            issues.append("first_cash_deadline is required")
        if score < 60:
            issues.append(f"commercial score must be at least 60, got {score}")
    elif gate_name == "problem":
        if _metric(metrics, "interviews") < 5:
            issues.append("interviews must be at least 5")
        if _metric(metrics, "problem_confirmations") < 3:
            issues.append("problem_confirmations must be at least 3")
    elif gate_name == "money":
        if not _nonempty(hypothesis.get("offer")):
            issues.append("offer is required")
        price = hypothesis.get("price")
        if not _is_number(price) or price <= 0:
            issues.append("price must be greater than 0")
        if not _nonempty(hypothesis.get("currency")):
            issues.append("currency is required")
        if _metric(metrics, "offers") < 1:
            issues.append("offers must be at least 1")
        if _metric(metrics, "prepayments") < 1:
            issues.append("prepayments must be at least 1")
        if _metric(metrics, "cash_collected") <= 0:
            issues.append("cash_collected must be greater than 0")
    elif gate_name == "delivery":
        if _metric(metrics, "accepted_deliveries") < 1:
            issues.append("accepted_deliveries must be at least 1")
        if _metric(metrics, "revenue_30d") <= _metric(metrics, "direct_costs_30d"):
            issues.append("revenue_30d must be greater than direct_costs_30d")
        if _metric(metrics, "founder_hours_30d") <= 0:
            issues.append("founder_hours_30d must be greater than 0")
    elif gate_name == "scale":
        if _metric(metrics, "paid_customers") < 3:
            issues.append("paid_customers must be at least 3")
        if _metric(metrics, "repeat_or_referral_customers") < 1:
            issues.append("repeat_or_referral_customers must be at least 1")
        if _metric(metrics, "revenue_30d") <= _metric(metrics, "direct_costs_30d"):
            issues.append("revenue_30d must be greater than direct_costs_30d")
        if not _nonempty(hypothesis.get("channel")):
            issues.append("channel is required")
    return issues


def validate_payload(payload: Any) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    if not isinstance(payload, dict):
        return {
            "valid": False,
            "score": 0,
            "stage": "",
            "gates": {},
            "errors": ["commercial-project.json must contain an object"],
            "warnings": [],
        }

    if payload.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    project = _mapping(payload.get("project"), "project", errors)
    if not _nonempty(project.get("name")):
        errors.append("project.name is required")
    if not _nonempty(project.get("created_at")):
        errors.append("project.created_at is required")

    stage = payload.get("stage")
    if stage not in STAGES:
        errors.append(f"stage must be one of: {', '.join(STAGES)}")
        stage = ""

    hypothesis = _mapping(payload.get("hypothesis"), "hypothesis", errors)
    scorecard = _mapping(payload.get("scorecard"), "scorecard", errors)
    metrics = _mapping(payload.get("metrics"), "metrics", errors)
    gates = _mapping(payload.get("gates"), "gates", errors)

    score = calculate_score(scorecard, errors)

    for field in REQUIRED_METRICS:
        value = metrics.get(field)
        if not _is_number(value) or value < 0:
            errors.append(f"metrics.{field} must be a non-negative number")

    gate_report: dict[str, dict[str, Any]] = {}
    for gate_name in GATE_NAMES:
        gate = gates.get(gate_name)
        if not isinstance(gate, dict):
            errors.append(f"gates.{gate_name} must be an object")
            gate = {}
        decision = gate.get("decision")
        if decision not in DECISIONS:
            errors.append(
                f"gates.{gate_name}.decision must be one of: {', '.join(DECISIONS)}"
            )
            decision = "pending"
        evidence = gate.get("evidence")
        if not isinstance(evidence, list) or any(
            not _nonempty(item) for item in evidence
        ):
            errors.append(f"gates.{gate_name}.evidence must be a list of non-empty refs")
            evidence = []
        decided_at = gate.get("decided_at")
        if decision != "pending":
            if not _nonempty(decided_at):
                errors.append(
                    f"{gate_name} gate decision {decision!r} requires decided_at"
                )
            if not evidence:
                errors.append(
                    f"{gate_name} gate decision {decision!r} requires evidence"
                )

        issues = _gate_issues(gate_name, score, hypothesis, metrics)
        if decision == "go" and issues:
            errors.extend(f"{gate_name} gate: {issue}" for issue in issues)
        elif decision == "pending":
            warnings.append(f"{gate_name} gate is pending")
        gate_report[gate_name] = {
            "decision": decision,
            "satisfied": decision == "go" and not issues,
            "issues": issues,
        }

    if stage:
        for required_gate in STAGE_PREREQUISITES[stage]:
            if gate_report.get(required_gate, {}).get("decision") != "go":
                errors.append(
                    f"stage {stage!r} requires {required_gate} gate decision 'go'"
                )

    if score < 60 and gate_report.get("idea", {}).get("decision") == "pending":
        warnings.append(f"commercial score is below the idea threshold: {score}/100")

    contribution_margin_30d = (
        _metric(metrics, "revenue_30d") - _metric(metrics, "direct_costs_30d")
    )
    founder_hours_30d = _metric(metrics, "founder_hours_30d")
    contribution_margin_per_founder_hour = (
        contribution_margin_30d / founder_hours_30d
        if founder_hours_30d > 0
        else None
    )

    return {
        "valid": not errors,
        "score": score,
        "stage": stage,
        "contribution_margin_30d": contribution_margin_30d,
        "contribution_margin_per_founder_hour": contribution_margin_per_founder_hour,
        "gates": gate_report,
        "errors": errors,
        "warnings": warnings,
    }


def invalid_report(message: str) -> dict[str, Any]:
    return {
        "valid": False,
        "score": 0,
        "stage": "",
        "contribution_margin_30d": 0,
        "contribution_margin_per_founder_hour": None,
        "gates": {},
        "errors": [message],
        "warnings": [],
    }


def load_payload(target: Path) -> dict[str, Any]:
    config_path = target / CONFIG_NAME
    try:
        raw = config_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CommercialProjectError(f"cannot read {config_path}: {exc}") from exc
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CommercialProjectError(
            f"invalid JSON in {config_path}: {exc.msg} at line {exc.lineno}"
        ) from exc
    if not isinstance(value, dict):
        raise CommercialProjectError(f"{config_path} must contain a JSON object")
    return value


def _copy_template_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def init_project(target: Path, name: str) -> None:
    clean_name = name.strip()
    if not clean_name:
        raise CommercialProjectError("--name must not be empty")
    if not TEMPLATE_ROOT.is_dir():
        raise CommercialProjectError(f"starter template is missing: {TEMPLATE_ROOT}")

    target = target.expanduser().resolve()
    if target == TEMPLATE_ROOT.resolve() or TEMPLATE_ROOT.resolve() in target.parents:
        raise CommercialProjectError("target must not be inside the starter template")
    if target.exists():
        if not target.is_dir():
            raise CommercialProjectError(f"target is not a directory: {target}")
        try:
            if any(target.iterdir()):
                raise CommercialProjectError(f"target is non-empty: {target}")
        except OSError as exc:
            raise CommercialProjectError(f"cannot inspect target {target}: {exc}") from exc
    else:
        try:
            target.mkdir(parents=True)
        except OSError as exc:
            raise CommercialProjectError(f"cannot create target {target}: {exc}") from exc

    for source in sorted(TEMPLATE_ROOT.rglob("*")):
        if source.is_file():
            _copy_template_file(source, target / source.relative_to(TEMPLATE_ROOT))

    created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    replacements = {
        "{{PROJECT_NAME}}": clean_name,
        "{{CREATED_AT}}": created_at,
    }
    for relative in TEXT_TEMPLATES:
        path = target / relative
        text = path.read_text(encoding="utf-8")
        for marker, value in replacements.items():
            text = text.replace(marker, value)
        path.write_text(text, encoding="utf-8")

    config_path = target / CONFIG_NAME
    payload = json.loads(config_path.read_text(encoding="utf-8"))
    payload["project"]["name"] = clean_name
    payload["project"]["created_at"] = created_at
    config_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    local_script = target / "scripts" / "commercial-project.py"
    _copy_template_file(Path(__file__).resolve(), local_script)
    local_script.chmod(local_script.stat().st_mode | 0o111)


def print_report(report: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return
    state = "VALID" if report["valid"] else "INVALID"
    print(
        f"{state}: stage={report['stage'] or '-'} "
        f"commercial_score={report['score']}/100 "
        f"contribution_margin_30d={report['contribution_margin_30d']}"
    )
    for gate_name, gate in report["gates"].items():
        print(
            f"- {gate_name}: {gate['decision']} "
            f"({'satisfied' if gate['satisfied'] else 'not satisfied'})"
        )
    for warning in report["warnings"]:
        print(f"WARNING: {warning}")
    for error in report["errors"]:
        print(f"ERROR: {error}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Create and validate commercial-first project starters"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="create a new starter")
    init_parser.add_argument("target", type=Path)
    init_parser.add_argument("--name", required=True)

    check_parser = subparsers.add_parser("check", help="validate a starter")
    check_parser.add_argument("target", type=Path)
    check_parser.add_argument("--json", action="store_true", dest="as_json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "init":
            init_project(args.target, args.name)
            print(f"Created commercial project starter: {args.target.expanduser().resolve()}")
            return 0
        payload = load_payload(args.target.expanduser().resolve())
        report = validate_payload(payload)
        print_report(report, args.as_json)
        return 0 if report["valid"] else 1
    except CommercialProjectError as exc:
        if args.command == "check" and args.as_json:
            print_report(invalid_report(str(exc)), True)
            return 2
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        if args.command == "check" and args.as_json:
            print_report(invalid_report(f"filesystem failure: {exc}"), True)
            return 2
        print(f"ERROR: filesystem failure: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
