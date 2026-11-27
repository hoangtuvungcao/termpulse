"""Offline safety and integrity tests for the public preview publisher."""
import gzip
import hashlib
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "publish_preview", Path(__file__).with_name("publish-preview.py")
)
preview = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preview)


def zip_bytes(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries:
            archive.writestr(name, data)
    return output.getvalue()


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.workflow = {"id": 7, "name": "Native platform checks",
                         "path": ".github/workflows/platform-checks.yml"}
        self.run = {
            "workflow_id": 7, "status": "completed", "conclusion": "success",
            "repository": {"full_name": preview.REPO},
            "head_repository": {"full_name": preview.REPO},
            "head_branch": "main", "event": "push", "head_sha": "a" * 40,
            "id": 10, "run_number": 20, "run_attempt": 1,
        }

    def test_only_trusted_completed_main_runs(self):
        preview.validate_run(self.run, self.workflow)
        preview.validate_run({**self.run, "event": "workflow_dispatch"}, self.workflow)
        for key, value in [
            ("event", "pull_request"), ("event", "pull_request_target"),
            ("head_branch", "feature"), ("status", "in_progress"),
            ("conclusion", "failure"), ("head_sha", "bad"), ("run_attempt", 0),
            ("head_repository", {"full_name": "fork/termpulse"}),
            ("repository", {"full_name": "fork/termpulse"}),
        ]:
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                preview.validate_run({**self.run, key: value}, self.workflow)
        with self.assertRaises(RuntimeError):
            preview.validate_run(self.run, {**self.workflow, "id": 8})
        with self.assertRaises(RuntimeError):
            preview.validate_run(self.run, {**self.workflow, "path": ".github/workflows/other.yml"})

    def test_archive_validation_and_apk_renaming(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "assets"
            destination.mkdir()
            payloads = {}
            for platform in ("windows-x64", "macos-arm64", "macos-x64", "ios-unsigned-dev-only-arm64"):
                payloads[f"termpulse-{platform}.zip"] = zip_bytes([("bundle/file", b"synthetic")])
            tar = io.BytesIO()
            with tarfile.open(fileobj=tar, mode="w:gz") as archive:
                info = tarfile.TarInfo("termpulse/termpulse")
                info.size = 9
                archive.addfile(info, io.BytesIO(b"synthetic"))
            payloads["termpulse-linux-x64.tar.gz"] = tar.getvalue()
            for abi in preview.ABIS:
                payloads[f"app-{abi}-debug.apk"] = zip_bytes([
                    ("AndroidManifest.xml", b"synthetic"), ("classes.dex", b"synthetic"),
                    (f"lib/{abi}/libflutter.so", b"synthetic"),
                ])
            artifact = root / "artifact.zip"
            artifact.write_bytes(zip_bytes(payloads.items()))
            seen, checksums = {}, []
            preview.collect(artifact, destination, seen, checksums)
            self.assertEqual(len(seen), 8)
            self.assertEqual({value["platform"] for value in seen.values()}, preview.PLATFORMS)
            self.assertIn("termpulse-android-arm64-v8a-debug-preview.apk", seen)
            self.assertEqual(preview.sha256(artifact), hashlib.sha256(artifact.read_bytes()).hexdigest())
            with self.assertRaises(RuntimeError):
                preview.collect(artifact, destination, seen, checksums)
            with self.assertRaises(RuntimeError):
                preview.inspect_zip(destination / "termpulse-android-arm64-v8a-debug-preview.apk", abi="x86_64")

    def test_unsafe_zip_members_and_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.zip"
            for name in ("../escape", "/absolute", "C:/drive", "directory\\escape"):
                path.write_bytes(zip_bytes([(name, b"synthetic")]))
                with self.subTest(name=name), self.assertRaises(RuntimeError):
                    preview.inspect_zip(path)
            path.write_bytes(zip_bytes([]))
            with self.assertRaises(RuntimeError):
                preview.inspect_zip(path)
            path.write_bytes(b"not a zip")
            with self.assertRaises(zipfile.BadZipFile):
                preview.inspect_zip(path)
            info = zipfile.ZipInfo("bundle/link")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            path.write_bytes(zip_bytes([(info, "../../escape")]))
            with self.assertRaises(RuntimeError):
                preview.inspect_zip(path)
            path.write_bytes(zip_bytes([(info, "file"), ("bundle/file", b"synthetic")]))
            preview.inspect_zip(path)
            with self.assertRaises(RuntimeError):
                preview.inspect_zip(path, outer=True)
            with self.assertRaises(RuntimeError):
                preview.collect(path, Path(temporary), {}, [])

    def test_escaping_tar_link_and_truncated_gzip_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.tar.gz"
            with tarfile.open(path, "w:gz") as archive:
                info = tarfile.TarInfo("bundle/link")
                info.type = tarfile.SYMTYPE
                info.linkname = "../../escape"
                archive.addfile(info)
            with self.assertRaises(RuntimeError):
                preview.inspect_tar(path)
            path.write_bytes(path.read_bytes()[:-8])
            with self.assertRaises((EOFError, gzip.BadGzipFile)):
                preview.inspect_tar(path)

    def test_unknown_payload_and_metadata_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "fixture.zip"
            path.write_bytes(zip_bytes([("vault.db", b"synthetic unapproved data")]))
            with self.assertRaises(RuntimeError):
                preview.collect(path, root, {}, [])
            path.write_bytes(zip_bytes([("SHA256SUMS", "not a checksum")]))
            with self.assertRaises(RuntimeError):
                preview.collect(path, root, {}, [])
            path.write_bytes(zip_bytes([("sample.tar.gz.sha256", "a" * 64 + "\n")]))
            checksums = []
            preview.collect(path, root, {}, checksums)
            self.assertEqual(checksums, [("sample.tar.gz", "a" * 64)])

    def test_rejects_invalid_dispatch_before_network(self):
        with patch.object(preview, "api", side_effect=AssertionError("No network expected")):
            for source_id, repository in [("1;echo bad", preview.REPO), ("10", "fork/repo")]:
                with self.assertRaises(RuntimeError):
                    preview.publish(source_id, repository)

    def test_notes_explicitly_disclose_distribution_limits(self):
        notes = preview.notes("a" * 40, "https://example.invalid/source")
        for wording in ("debug-signed", "or notarized", "not directly installable",
                        "chưa phải", "SHA256SUMS", "BUILD_INFO", "no project license"):
            self.assertIn(wording, notes)

    def test_publish_is_draft_until_all_eight_payloads_and_metadata_are_uploaded(self):
        archives = {}
        for artifact, names in preview.PAYLOADS.items():
            files = {}
            for name in names:
                if name.endswith(".apk"):
                    abi = preview.APK.fullmatch(name)[1]
                    files[name] = zip_bytes([
                        ("AndroidManifest.xml", b"synthetic"), ("classes.dex", b"synthetic"),
                        (f"lib/{abi}/libflutter.so", b"synthetic"),
                    ])
                elif name.endswith(".tar.gz"):
                    buffer = io.BytesIO()
                    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                        info = tarfile.TarInfo("termpulse/termpulse")
                        info.size = 9
                        archive.addfile(info, io.BytesIO(b"synthetic"))
                    files[name] = buffer.getvalue()
                else:
                    files[name] = zip_bytes([("bundle/file", b"synthetic")])
            archives[artifact] = zip_bytes(files.items())
        artifacts = [{
            "id": index, "name": name, "size_in_bytes": len(data), "expired": False,
            "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
            "workflow_run": {"id": 10, "head_sha": "a" * 40, "head_branch": "main"},
        } for index, (name, data) in enumerate(archives.items(), start=100)]
        artifacts.append({"id": 999, "name": "website-dist"})
        calls, uploaded = [], []

        def fake_api(path, method="GET", data=None, missing_ok=False):
            calls.append((path, method, data))
            if path.endswith("/actions/runs/10"):
                return self.run
            if path.endswith("/actions/workflows/platform-checks.yml"):
                return self.workflow
            if "/releases/tags/" in path:
                return None
            if "/git/matching-refs/" in path:
                # A longer tag sharing this prefix must not block the exact new tag.
                return [{"ref": "refs/tags/community-preview-20-10"}]
            if "/artifacts?" in path:
                return {"artifacts": artifacts}
            if method == "POST" and path.endswith("/releases"):
                self.assertTrue(data["draft"])
                self.assertTrue(data["prerelease"])
                self.assertEqual(data["make_latest"], "false")
                self.assertEqual(data["target_commitish"], "a" * 40)
                self.assertEqual(data["tag_name"], "community-preview-20-1")
                self.assertEqual(uploaded, [])
                return {"id": 55}
            if path.endswith("/releases/55/assets?per_page=100"):
                return uploaded
            if path.endswith("/releases/55") and method == "PATCH":
                self.assertEqual(len(uploaded), 10)
                self.assertEqual(data, {"draft": False, "prerelease": True, "make_latest": "false"})
                return {**data, "tag_name": "community-preview-20-1", "target_commitish": "a" * 40}
            raise AssertionError("Unexpected API call: " + path)

        def fake_gh(*args, data=None, output=None, missing_ok=False):
            if args[0] == "api":
                identity = int(args[1].split("/")[-2])
                artifact = next(item for item in artifacts if item["id"] == identity)
                self.assertNotEqual(identity, 999)
                output.write(archives[artifact["name"]])
                return
            self.assertEqual(args[:3], ("release", "upload", "community-preview-20-1"))
            files = [Path(name) for name in args[3:-2]]
            self.assertEqual(args[-2:], ("--repo", preview.REPO))
            self.assertEqual(len(files), 10)
            checksums = next(path for path in files if path.name == "SHA256SUMS")
            entries = dict(line.split("  ", 1)[::-1] for line in checksums.read_text().splitlines())
            self.assertEqual(len(entries), 9)
            for path in files:
                if path.name != "SHA256SUMS":
                    self.assertEqual(entries[path.name], preview.sha256(path))
                uploaded.append({
                    "name": path.name, "size": path.stat().st_size,
                    "digest": "sha256:" + preview.sha256(path),
                })
            build_info = next(path for path in files if path.name == "BUILD_INFO").read_text()
            self.assertIn("Commit: " + "a" * 40, build_info)
            self.assertIn("/actions/runs/10/attempts/1", build_info)

        with patch.object(preview, "api", side_effect=fake_api), patch.object(preview, "gh", side_effect=fake_gh), redirect_stdout(io.StringIO()):
            preview.publish("10", preview.REPO)
        self.assertEqual(calls[-1][1], "PATCH")


if __name__ == "__main__":
    unittest.main()
