#!/usr/bin/env python3
"""Publish GitHub Releases without requiring the gh CLI."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


API_ROOT = "https://api.github.com"
API_VERSION = "2022-11-28"


class ApiError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(f"GitHub API returned {status}: {message}")
        self.status = status


def run_git(*args: str, input_text: str | None = None) -> str:
    result = subprocess.run(
        ["git", *args],
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
        timeout=20,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "git command failed"
        raise RuntimeError(detail)
    return result.stdout.strip()


def resolve_repo(explicit: str | None) -> str:
    if explicit:
        if re.fullmatch(r"[^/\s]+/[^/\s]+", explicit):
            return explicit.removesuffix(".git")
        raise RuntimeError("--repo must use owner/name format")

    remote = run_git("remote", "get-url", "origin")
    patterns = (
        r"https?://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
        r"git@github\.com:([^/]+/[^/]+?)(?:\.git)?$",
        r"ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, remote)
        if match:
            return match.group(1)
    raise RuntimeError(f"Cannot derive a GitHub repository from origin: {remote}")


def resolve_token() -> tuple[str, str]:
    for key in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(key)
        if value:
            return value, key

    filled = run_git(
        "credential",
        "fill",
        input_text="protocol=https\nhost=github.com\n\n",
    )
    credentials = dict(
        line.split("=", 1) for line in filled.splitlines() if "=" in line
    )
    token = credentials.get("password")
    if token:
        return token, "git credential helper"
    raise RuntimeError(
        "No GitHub credential found. Set GH_TOKEN/GITHUB_TOKEN or configure git credentials."
    )


class GitHub:
    def __init__(self, token: str):
        self.token = token

    def request(
        self,
        method: str,
        url_or_path: str,
        *,
        payload: dict[str, Any] | None = None,
        raw: bytes | None = None,
        content_type: str = "application/json",
    ) -> Any:
        url = (
            url_or_path
            if url_or_path.startswith("https://")
            else f"{API_ROOT}{url_or_path}"
        )
        data = raw
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "codex-publish-github-release",
            "X-GitHub-Api-Version": API_VERSION,
        }
        if data is not None:
            headers["Content-Type"] = content_type
        request = Request(url, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=180) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            try:
                message = json.loads(body).get("message", body)
            except json.JSONDecodeError:
                message = body or error.reason
            raise ApiError(error.code, str(message)) from None
        except URLError as error:
            raise RuntimeError(f"GitHub request failed: {error.reason}") from None


def get_release(api: GitHub, repo: str, tag: str) -> dict[str, Any] | None:
    try:
        return api.request("GET", f"/repos/{repo}/releases/tags/{quote(tag, safe='')}")
    except ApiError as error:
        if error.status == 404:
            return None
        raise


def check(api: GitHub, repo: str, source: str) -> None:
    user = api.request("GET", "/user")
    repository = api.request("GET", f"/repos/{repo}")
    output = {
        "authenticated_as": user.get("login"),
        "credential_source": source,
        "repository": repository.get("full_name"),
        "permissions": repository.get("permissions", {}),
        "default_branch": repository.get("default_branch"),
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))


def view(api: GitHub, repo: str, tag: str) -> None:
    release = get_release(api, repo, tag)
    if release is None:
        raise RuntimeError(f"Release {tag} does not exist in {repo}")
    output = {
        "tag": release.get("tag_name"),
        "name": release.get("name"),
        "url": release.get("html_url"),
        "draft": release.get("draft"),
        "prerelease": release.get("prerelease"),
        "assets": [
            {"name": item.get("name"), "size": item.get("size")}
            for item in release.get("assets", [])
        ],
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))


def publish(api: GitHub, repo: str, args: argparse.Namespace) -> None:
    notes = Path(args.notes_file).read_text(encoding="utf-8")
    payload = {
        "tag_name": args.tag,
        "name": args.name or args.tag,
        "body": notes,
        "draft": args.draft,
        "prerelease": args.prerelease,
    }
    if args.target:
        payload["target_commitish"] = args.target

    release = get_release(api, repo, args.tag)
    if release is None:
        release = api.request("POST", f"/repos/{repo}/releases", payload=payload)
    elif args.update_existing:
        release = api.request(
            "PATCH", f"/repos/{repo}/releases/{release['id']}", payload=payload
        )
    else:
        raise RuntimeError(
            f"Release {args.tag} already exists; pass --update-existing to update it"
        )

    existing = {item["name"]: item for item in release.get("assets", [])}
    uploaded: list[dict[str, Any]] = []
    upload_url = release["upload_url"].split("{", 1)[0]
    for raw_path in args.asset:
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file():
            raise RuntimeError(f"Asset does not exist: {path}")
        old = existing.get(path.name)
        if old and not args.replace_assets:
            raise RuntimeError(
                f"Asset {path.name} already exists; pass --replace-assets to replace it"
            )
        if old:
            api.request("DELETE", f"/repos/{repo}/releases/assets/{old['id']}")
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        asset = api.request(
            "POST",
            f"{upload_url}?{urlencode({'name': path.name})}",
            raw=path.read_bytes(),
            content_type=content_type,
        )
        uploaded.append({"name": asset.get("name"), "size": asset.get("size")})

    output = {
        "tag": release.get("tag_name"),
        "url": release.get("html_url"),
        "draft": release.get("draft"),
        "prerelease": release.get("prerelease"),
        "uploaded_assets": uploaded,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--repo", help="GitHub repository in owner/name format")
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("check", help="Verify authentication and repository access")

    view_parser = commands.add_parser("view", help="Show one release")
    view_parser.add_argument("--tag", required=True)

    publish_parser = commands.add_parser("publish", help="Create or update a release")
    publish_parser.add_argument("--tag", required=True)
    publish_parser.add_argument("--name")
    publish_parser.add_argument("--notes-file", required=True)
    publish_parser.add_argument("--target")
    publish_parser.add_argument("--asset", action="append", default=[])
    publish_parser.add_argument("--draft", action="store_true")
    publish_parser.add_argument("--prerelease", action="store_true")
    publish_parser.add_argument("--update-existing", action="store_true")
    publish_parser.add_argument("--replace-assets", action="store_true")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        repo = resolve_repo(args.repo)
        token, source = resolve_token()
        api = GitHub(token)
        if args.command == "check":
            check(api, repo, source)
        elif args.command == "view":
            view(api, repo, args.tag)
        elif args.command == "publish":
            publish(api, repo, args)
        return 0
    except (ApiError, RuntimeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
