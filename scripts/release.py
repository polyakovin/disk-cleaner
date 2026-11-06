#!/usr/bin/env python3
"""Build verified macOS previews from the global Stop hook's committed snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote, urlencode

from github_release import ApiError, GitHub, resolve_repo, resolve_token

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(r"v?(\d+)\.(\d+)\.(\d+)")


def run_in_project_build(source: Path) -> int | None:
    # /tmp and macOS's per-user temp folder can be excluded from persistent FSEvents.
    # Copy the hook's committed archive, never the working tree, onto the project volume.
    build_root = source / "build"
    if ROOT.is_relative_to(build_root):
        return None
    build_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-source-", dir=build_root) as temporary:
        snapshot = Path(temporary) / "source"
        shutil.copytree(ROOT, snapshot)
        return subprocess.run([sys.executable, str(snapshot / "scripts/release.py")],
                              cwd=snapshot, timeout=1050).returncode


def run(*args: str, cwd: Path = ROOT) -> str:
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=900)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(f"{args[0]} exited {result.returncode}")
    return result.stdout.strip()


def pages(api: GitHub, path: str) -> list[dict]:
    items = []
    for page in range(1, 100):
        batch = api.request("GET", f"{path}?per_page=100&page={page}")
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise RuntimeError("Too many GitHub pages; refusing an incomplete release history")


def version_tuple(value: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(value)
    if not match:
        raise ValueError(f"Invalid semantic version: {value}")
    return tuple(map(int, match.groups()))


def next_version(minimum: str, tags: list[str]) -> str:
    versions = [version_tuple(tag) for tag in tags if VERSION_PATTERN.fullmatch(tag)]
    base = version_tuple(minimum)
    if versions and max(versions) >= base:
        major, minor, patch = max(versions)
        base = (major, minor, patch + 1)
    return ".".join(map(str, base))


def marker(commit: str) -> str:
    return f"<!-- disk-manage-source:{commit} -->"


def release_for_commit(releases: list[dict], commit: str) -> dict | None:
    matches = [item for item in releases if marker(commit) in (item.get("body") or "")]
    if len(matches) > 1:
        raise RuntimeError("Multiple releases claim the same source commit")
    return matches[0] if matches else None


def assert_source(repo: Path, commit: str) -> None:
    run("git", "fetch", "--quiet", "origin", cwd=repo)
    config = json.loads((ROOT / ".codex/release.json").read_text())
    if (run("git", "branch", "--show-current", cwd=repo) != config["branch"]
            or run("git", "rev-parse", "HEAD", cwd=repo) != commit
            or run("git", "rev-parse", "@{upstream}", cwd=repo) != commit):
        raise RuntimeError("Release commit must still be HEAD on the synchronized release branch")


def smoke(app: Path, directory: Path) -> None:
    fixture = directory / "fixture"
    fixture.mkdir()
    (fixture / "sample.txt").write_text("Disk Manage release fixture\n" * 512)
    history = directory / "history"
    with (directory / "app.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/DiskLens"),
                                    "--history-directory", str(history), "--scan", str(fixture)],
                                   stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Packaged app exited before completing the fixture scan")
                saved = history / "last-scan.json"
                if saved.exists():
                    report = json.loads(saved.read_text())["report"]
                    if (Path(report["root"]["path"]).resolve() == fixture.resolve()
                            and report["root"]["fileCount"] == 1
                            and report["scannedItems"] >= 1 and report["issueCount"] == 0
                            and not report["cancelled"] and not report.get("inProgress")):
                        return
                time.sleep(0.25)
            raise RuntimeError("Packaged app did not save a complete fixture scan within 45 seconds")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(version: str, commit: str, output: Path) -> list[Path]:
    version_tuple(version)
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("Select an empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    print(run("make", "verify"), flush=True)
    # Only the isolated snapshot changes; the working repository keeps its version floor.
    info = ROOT / "DiskLens/assets/Info.plist"
    original = info.read_bytes()
    plist = plistlib.loads(original)
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = version
    try:
        info.write_bytes(plistlib.dumps(plist, sort_keys=False))
        print(run("bash", "DiskLens/scripts/build-app.sh", str(output / "package")), flush=True)
    finally:
        info.write_bytes(original)
    archive = output / f"DiskManage-{version}-macos-universal.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
        str(output / "package/Disk Manage.app"), str(archive))
    # Verify and run the app extracted from the archive that will be uploaded.
    with tempfile.TemporaryDirectory(prefix="disk-manage-qa-") as temporary:
        qa = Path(temporary)
        run("ditto", "-x", "-k", str(archive), str(qa))
        app = qa / "Disk Manage.app"
        run("codesign", "--verify", "--strict", str(app))
        run("plutil", "-lint", str(app / "Contents/Info.plist"))
        packaged = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if packaged["CFBundleShortVersionString"] != version:
            raise RuntimeError("Packaged app version differs from its release tag")
        arches = run("lipo", "-archs", str(app / "Contents/MacOS/DiskLens")).split()
        if set(arches) != {"arm64", "x86_64"}:
            raise RuntimeError("Packaged app must contain arm64 and x86_64")
        smoke(app, qa)
    manifest = output / "RELEASE.json"
    manifest.write_text(json.dumps({
        "version": version, "commit": commit, "archive": archive.name,
        "sha256": digest(archive), "architectures": sorted(arches),
        "runtime_verified": run("uname", "-m"), "macos": run("sw_vers", "-productVersion"),
        "verification": "make verify; extracted app signature, plist, architectures and fixture scan",
        "not_verified": ["Intel runtime", "Developer ID distribution", "notarization"],
    }, indent=2) + "\n")
    checksums = output / "SHA256SUMS.txt"
    checksums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in (archive, manifest)))
    print(f"Verified {archive.name}: {archive.stat().st_size} bytes, SHA-256 {digest(archive)}", flush=True)
    return [archive, manifest, checksums]


def assert_tag(api: GitHub, repo: str, tag: str, commit: str) -> None:
    obj = api.request("GET", f"/repos/{repo}/git/ref/tags/{quote(tag, safe='')}")["object"]
    # Accept earlier annotated tags too, but never move any existing tag.
    for _ in range(5):
        if obj["type"] == "commit" and obj["sha"] == commit:
            return
        if obj["type"] != "tag":
            break
        obj = api.request("GET", f"/repos/{repo}/git/tags/{obj['sha']}")["object"]
    raise RuntimeError("Release tag does not point to the verified commit")


def assert_assets(release: dict, version: str) -> None:
    assets = {item["name"]: item for item in release.get("assets", [])}
    expected = {f"DiskManage-{version}-macos-universal.zip", "RELEASE.json", "SHA256SUMS.txt"}
    if set(assets) != expected or any(item.get("state") != "uploaded" or item["size"] <= 0
                                      for item in assets.values()):
        raise RuntimeError("Release has missing or incomplete assets")


def publish(api: GitHub, repo: str, commit: str, version: str,
            assets: list[Path], existing: dict | None) -> dict:
    tag = f"v{version}"
    notes = (f"{marker(commit)}\nDisk Manage macOS preview, built from `{commit}`.\n\n"
             "English interface. Full file tree, saved measurements and incremental refresh. "
             "File removal requires explicit confirmation; AI recommendations never run cleanup.\n\n"
             "Verified: commercial validator, Python release tests, Swift tests and release build; "
             "universal package signature and a completed fixture scan in the extracted app. "
             "The optional system Trash test is skipped. See RELEASE.json for host architecture "
             "and macOS version, SHA256SUMS.txt for checksums.\n\n"
             "Requires macOS 14+. Contains Apple Silicon and Intel binaries. "
             "Intel runtime, Developer ID distribution and notarization are not verified. "
             "Default signing is ad-hoc; macOS may block the first launch. "
             "Unzip and move Disk Manage.app to Applications.\n")
    if existing and not existing["draft"]:
        raise RuntimeError("Refusing to modify a published release")
    if existing is None:
        api.request("POST", f"/repos/{repo}/git/refs",
                    payload={"ref": f"refs/tags/{tag}", "sha": commit})
    assert_tag(api, repo, tag, commit)
    release = existing or api.request("POST", f"/repos/{repo}/releases", payload={
        "tag_name": tag, "target_commitish": commit, "name": f"Disk Manage {tag}",
        "body": notes, "draft": True, "prerelease": True,
    })
    # Only our unpublished draft can have assets replaced after an interrupted upload.
    for old in release.get("assets", []):
        api.request("DELETE", f"/repos/{repo}/releases/assets/{old['id']}")
    upload = release["upload_url"].split("{", 1)[0]
    for path in assets:
        uploaded = api.request("POST", f"{upload}?{urlencode({'name': path.name})}",
                               raw=path.read_bytes(), content_type="application/octet-stream")
        if uploaded["size"] != path.stat().st_size or uploaded.get("digest") != f"sha256:{digest(path)}":
            raise RuntimeError(f"GitHub upload checksum mismatch: {path.name}")
    release_path = f"/repos/{repo}/releases/{release['id']}"
    assert_assets(api.request("GET", release_path), version)
    api.request("PATCH", release_path, payload={"draft": False, "prerelease": True, "body": notes})
    published = api.request("GET", release_path)
    assert_assets(published, version)
    if published["draft"] or not published["prerelease"]:
        raise RuntimeError("GitHub did not publish the expected preview release")
    return published


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Read-only GitHub access and version check")
    args = parser.parse_args()
    try:
        source = Path(os.environ.get("CODEX_RELEASE_SOURCE_REPO", ROOT)).resolve()
        commit = os.environ.get("CODEX_RELEASE_COMMIT", "")
        if not args.check and (not re.fullmatch(r"[0-9a-f]{40}", commit)
                               or source == ROOT or (ROOT / ".git").exists()):
            raise RuntimeError("Publication requires the global Stop hook's isolated committed snapshot")
        if not args.check:
            relocated = run_in_project_build(source)
            if relocated is not None:
                return relocated
        previous = Path.cwd()
        try:
            os.chdir(source)
            repo = resolve_repo(None)
            token, _ = resolve_token()
        finally:
            os.chdir(previous)
        api = GitHub(token)
        existing = release_for_commit(pages(api, f"/repos/{repo}/releases"), commit) if commit else None
        minimum = plistlib.loads((ROOT / "DiskLens/assets/Info.plist").read_bytes())["CFBundleShortVersionString"]
        version = (existing["tag_name"].removeprefix("v") if existing else
                   next_version(minimum, [item["name"] for item in pages(api, f"/repos/{repo}/tags")]))
        if args.check:
            access = api.request("GET", f"/repos/{repo}")
            if not access.get("permissions", {}).get("push"):
                raise RuntimeError("GitHub credential has no repository push permission")
            print(f"{repo}: push access confirmed; next preview v{version}")
            return 0
        assert_source(source, commit)
        if existing and not existing["draft"]:
            assert_tag(api, repo, existing["tag_name"], commit)
            assert_assets(existing, version)
            print(f"Already published: {existing['html_url']}")
            return 0
        with tempfile.TemporaryDirectory(prefix="disk-manage-release-") as temporary:
            assets = build(version, commit, Path(temporary) / "output")
            assert_source(source, commit)
            release = publish(api, repo, commit, version, assets, existing)
        print(f"Published: {release['html_url']}")
        return 0
    except (ApiError, RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
