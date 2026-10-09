#!/usr/bin/env python3
"""Read-only allocated-size summaries for macOS/Linux, using du or file metadata."""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time
from datetime import datetime, timezone


def error_summary(lines):
    denied, other = [], []
    for line in lines:
        target = denied if any(token in line.lower() for token in
                    ("permission denied", "operation not permitted", "access denied")) else other
        target.append(line)
    return {
        "permission_error_count": len(denied),
        "other_error_count": len(other),
        "error_samples": (denied[:3] + other[:3])[:5],
    }


def scan_directory(root, depth, top, timeout, system):
    result = {"root": str(root), "total_bytes": None}
    try:
        is_directory = root.is_dir()
    except OSError as exc:
        result.update(status="missing_or_inaccessible", entries=[],
                      **error_summary([str(exc)]))
        return result
    if not is_directory:
        result.update(status="missing_or_inaccessible", entries=[],
                      error="Path is missing, inaccessible, or not a directory")
        return result
    du = shutil.which("du")
    if not du:
        result.update(status="unavailable", error="du is not installed", entries=[])
        return result
    args = [du, "-x", "-k"]
    args += ["-d", str(depth)] if system == "Darwin" else [f"--max-depth={depth}"]
    args.append(str(root))
    env = dict(os.environ, LC_ALL="C")
    started = time.monotonic()
    try:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace", env=env)
    except OSError as exc:
        result.update(status="unavailable", error=str(exc), entries=[])
        return result
    timed_out = False
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        stdout, stderr = proc.communicate()
    except BaseException:
        proc.kill()
        proc.communicate()
        raise

    entries = []
    parse_errors = []
    for line in stdout.splitlines():
        size, separator, path = line.partition("\t")
        if not separator or not size.isdigit():
            parse_errors.append("Could not parse a du output line")
            continue
        entry = {"path": path, "allocated_bytes": int(size) * 1024}
        if path == str(root):
            result["total_bytes"] = entry["allocated_bytes"]
        else:
            entries.append(entry)
    errors = stderr.splitlines() + parse_errors
    result.update(
        status="timed_out" if timed_out else
               ("complete" if proc.returncode == 0 and not errors
                and result["total_bytes"] is not None else "partial"),
        exit_code=proc.returncode,
        timed_out=timed_out,
        elapsed_seconds=round(time.monotonic() - started, 2),
        depth=depth,
        entries=sorted(entries, key=lambda e: e["allocated_bytes"], reverse=True)[:top],
        **error_summary(errors),
    )
    return result


def scan_files(root, top):
    """Inspect only direct regular children; never open their contents."""
    result = {"root": str(root), "mode": "files", "recursive": False}
    entries = []
    errors = []
    total = 0
    unknown_allocations = 0
    try:
        with os.scandir(root) as children:
            for child in children:
                try:
                    if not child.is_file(follow_symlinks=False):
                        continue
                    stat = child.stat(follow_symlinks=False)
                    allocated = stat.st_blocks * 512 if hasattr(stat, "st_blocks") else None
                    if allocated is None:
                        unknown_allocations += 1
                    else:
                        total += allocated
                    entries.append({"path": child.path, "allocated_bytes": allocated,
                                    "logical_bytes": stat.st_size})
                except OSError as exc:
                    errors.append(str(exc))
    except OSError as exc:
        errors.append(str(exc))
    result.update(
        status="complete" if not errors and not unknown_allocations else "partial",
        direct_files_allocated_bytes=total if not errors and not unknown_allocations else None,
        observed_allocated_bytes=total,
        file_count=len(entries),
        entries=sorted(entries, key=lambda e: e["allocated_bytes"]
                       if e["allocated_bytes"] is not None else e["logical_bytes"],
                       reverse=True)[:top],
        **error_summary(errors),
    )
    return result


def bounded_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="Directories to measure")
    parser.add_argument("--depth", type=bounded_int, default=1,
                        help="Maximum du depth (default: 1)")
    parser.add_argument("--top", type=bounded_int, default=20,
                        help="Largest entries per root (default: 20)")
    parser.add_argument("--timeout", type=bounded_int, default=180,
                        help="du timeout per root in seconds (default: 180)")
    parser.add_argument("--files", action="store_true",
                        help="Inspect direct regular files instead of directory sizes")
    args = parser.parse_args()
    system = platform.system()
    if not args.files and system not in {"Darwin", "Linux"}:
        parser.error("Directory scanning supports macOS and Linux only")
    roots = list(dict.fromkeys(Path(p).expanduser().resolve() for p in args.paths))
    results = []
    for root in roots:
        result = scan_files(root, args.top) if args.files else scan_directory(
            root, args.depth, args.top, args.timeout, system)
        results.append(result)
        print(f"Measured {root}: {result['status']}", file=os.sys.stderr, flush=True)
    payload = {
        "measured_at_utc": datetime.now(timezone.utc).isoformat(),
        "platform": system,
        "units": "bytes",
        "size_basis": "allocated blocks; unique physical or reclaimable bytes may differ",
        "results": results,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if all(r["status"] == "complete" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
