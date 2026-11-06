"""Release safety and recovery checks without network access or real publication."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release

COMMIT = "a" * 40


class FakeGitHub:
    def __init__(self, corrupt=False):
        self.calls = []
        self.corrupt = corrupt
        self.release = {"id": 7, "draft": True, "prerelease": True, "tag_name": "v0.2.0",
                        "upload_url": "https://uploads.github.com/release{?name}",
                        "html_url": "https://github.com/owner/repo/releases/tag/v0.2.0",
                        "body": release.marker(COMMIT), "assets": []}

    def request(self, method, path, **kwargs):
        self.calls.append((method, path))
        if "/git/ref/tags/" in path:
            return {"object": {"type": "commit", "sha": COMMIT}}
        if path.startswith("https://uploads.github.com/"):
            from urllib.parse import parse_qs, urlsplit
            raw = kwargs["raw"]
            asset = {"id": len(self.release["assets"]) + 1,
                     "name": parse_qs(urlsplit(path).query)["name"][0],
                     "size": len(raw), "state": "uploaded",
                     "digest": "sha256:" + ("invalid" if self.corrupt else hashlib.sha256(raw).hexdigest())}
            self.release["assets"].append(asset)
            return asset
        if method == "DELETE":
            identifier = int(path.rsplit("/", 1)[-1])
            self.release["assets"] = [item for item in self.release["assets"] if item["id"] != identifier]
            return None
        if method == "PATCH":
            self.release.update(kwargs["payload"])
        return self.release


class ReleaseTests(unittest.TestCase):
    def test_versions_have_a_floor_and_never_reuse_existing_tags(self):
        self.assertEqual(release.next_version("0.2.0", ["v0.1.0"]), "0.2.0")
        self.assertEqual(release.next_version("0.2.0", ["v0.2.0", "other", "v0.3.9"]), "0.3.10")
        self.assertEqual(release.next_version("1.0.0", ["v0.2.9"]), "1.0.0")

    def test_commit_identity_is_exact_and_ambiguous_releases_fail(self):
        item = {"body": release.marker(COMMIT)}
        self.assertIsNone(release.release_for_commit([item], "b" * 40))
        self.assertIs(release.release_for_commit([item], COMMIT), item)
        with self.assertRaises(RuntimeError):
            release.release_for_commit([item, item], COMMIT)

    def test_existing_tag_must_point_to_the_verified_commit(self):
        with self.assertRaisesRegex(RuntimeError, "does not point"):
            release.assert_tag(FakeGitHub(), "owner/repo", "v0.2.0", "b" * 40)

    def test_published_release_is_never_modified(self):
        api = FakeGitHub()
        with self.assertRaisesRegex(RuntimeError, "published release"):
            release.publish(api, "owner/repo", COMMIT, "0.2.0", [], {"draft": False})
        self.assertEqual(api.calls, [])

    def assets(self, root):
        result = []
        for name in ("DiskManage-0.2.0-macos-universal.zip", "RELEASE.json", "SHA256SUMS.txt"):
            path = root / name
            path.write_text("verified fixture")
            result.append(path)
        return result

    def test_upload_checksum_failure_leaves_release_unpublished(self):
        api = FakeGitHub(corrupt=True)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                release.publish(api, "owner/repo", COMMIT, "0.2.0", self.assets(Path(temporary)), None)
        self.assertTrue(api.release["draft"])
        self.assertFalse(any(method == "PATCH" for method, _ in api.calls))

    def test_all_assets_are_verified_before_publication(self):
        api = FakeGitHub()
        with tempfile.TemporaryDirectory() as temporary:
            result = release.publish(api, "owner/repo", COMMIT, "0.2.0", self.assets(Path(temporary)), None)
        self.assertFalse(result["draft"])
        patch_index = next(i for i, (method, _) in enumerate(api.calls) if method == "PATCH")
        uploads = [i for i, (_, path) in enumerate(api.calls) if path.startswith("https://uploads.")]
        self.assertEqual(len(uploads), 3)
        self.assertLess(max(uploads), patch_index)

    def test_retry_only_replaces_assets_in_our_draft_and_preserves_tag(self):
        api = FakeGitHub()
        api.release["assets"] = [{"id": 99, "name": "interrupted-upload"}]
        with tempfile.TemporaryDirectory() as temporary:
            release.publish(api, "owner/repo", COMMIT, "0.2.0", self.assets(Path(temporary)), api.release)
        self.assertIn(("DELETE", "/repos/owner/repo/releases/assets/99"), api.calls)
        self.assertNotIn(("POST", "/repos/owner/repo/git/refs"), api.calls)
        release.assert_assets(api.release, "0.2.0")

    def test_published_commit_does_not_rebuild_or_create_another_release(self):
        api = FakeGitHub()
        api.release.update(draft=False)
        api.release["assets"] = [{"name": name, "size": 1, "state": "uploaded"} for name in
                                 ("DiskManage-0.2.0-macos-universal.zip", "RELEASE.json", "SHA256SUMS.txt")]
        with tempfile.TemporaryDirectory() as temporary:
            with (patch.dict(os.environ, {"CODEX_RELEASE_SOURCE_REPO": temporary,
                                          "CODEX_RELEASE_COMMIT": COMMIT}),
                  patch.object(sys, "argv", ["release.py"]),
                  patch.object(release, "resolve_repo", return_value="owner/repo"),
                  patch.object(release, "resolve_token", return_value=("fixture", "test")),
                  patch.object(release, "GitHub", return_value=api),
                  patch.object(release, "pages", return_value=[api.release]),
                  patch.object(release, "assert_source"),
                  patch.object(release, "build") as build):
                self.assertEqual(release.main(), 0)
                build.assert_not_called()
        self.assertFalse(any(method != "GET" for method, _ in api.calls))

    def test_incomplete_assets_do_not_pass_release_validation(self):
        with self.assertRaisesRegex(RuntimeError, "missing or incomplete"):
            release.assert_assets({"assets": []}, "0.2.0")


if __name__ == "__main__":
    unittest.main()
