"""Synthetic fixtures for release completeness and secret-safe signing setup."""

import base64
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="termpulse-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "pubspec.yaml").write_text("name: termpulse\nversion: 1.0.0+1\n")
        self.output = self.root / "dist"

    def write(self, relative, content=b"fixture"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def native(self, target):
        base = "build/linux/x64/release/bundle" if target == "linux-x64" else "build/windows/x64/runner/Release"
        names = ("termpulse", "lib/librust_lib_termpulse.so", "lib/libflutter_linux_gtk.so") if target == "linux-x64" else ("termpulse.exe", "rust_lib_termpulse.dll", "flutter_windows.dll")
        for name in (*names, "data/flutter_assets/AssetManifest.bin"):
            self.write(f"{base}/{name}")
        if target == "linux-x64":
            (self.root / base / "termpulse").chmod(0o755)
        return self.root / base

    def android(self, abis, bundle=False, omit=None):
        path = self.root / ("fixture.aab" if bundle else "fixture.apk")
        prefix = "base/" if bundle else ""
        with zipfile.ZipFile(path, "w") as archive:
            for abi in abis:
                for library in ("librust_lib_termpulse.so", "libflutter.so", "libapp.so"):
                    if library != omit:
                        archive.writestr(f"{prefix}lib/{abi}/{library}", b"native")
            archive.writestr(prefix + "assets/flutter_assets/AssetManifest.bin", b"asset")
            if bundle:
                archive.writestr("META-INF/UPLOAD.RSA", b"certificate")
        return path

    def test_tag_must_match_version_without_build_number(self):
        self.assertEqual(release.validate_tag(self.root, "v1.0.0"), "v1.0.0")
        for tag in ("v1.0.1", "1.0.0", "v1.0.0+1", ""):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.validate_tag(self.root, tag)

    def test_java_properties_escape_passwords_and_unicode(self):
        self.assertEqual(release.property_escape(" a\\b:=#!\n\r\t"), "\\ a\\\\b\\:\\=\\#\\!\\n\\r\\t")
        self.assertEqual(release.property_escape("Việt 😀"), "Vi\\u1ec7t\\ \\ud83d\\ude00")

    def test_missing_privacy_and_signing_fail_before_writing(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(release.ReleaseError):
            release.prepare_signing(self.root)
        self.assertFalse((self.root / "android/key.properties").exists())

    def test_privacy_rejects_credentials_and_malformed_https_urls(self):
        env = {
            "PRIVACY_PUBLISHER_NAME": "Fixture publisher", "PRIVACY_CONTACT_EMAIL": "support@example.com",
            "PRIVACY_POLICY_URL": "https://example.com/privacy",
        }
        for url in ("http://example.com/privacy", "https://:password@example.com/privacy", "https://example.com:invalid/privacy", "https://localhost/privacy"):
            with self.subTest(url=url), patch.dict(os.environ, {**env, "PRIVACY_POLICY_URL": url}, clear=True):
                with self.assertRaises(release.ReleaseError):
                    release.privacy_values()

    def test_signing_setup_uses_private_files_and_cleans_only_owned_material(self):
        (self.root / "android").mkdir()
        env_path = self.write("github-env", b"")
        env = {
            "PRIVACY_PUBLISHER_NAME": "Fixture publisher", "PRIVACY_CONTACT_EMAIL": "support@example.com",
            "PRIVACY_POLICY_URL": "https://example.com/privacy", "RUNNER_TEMP": str(self.root),
            "GITHUB_ENV": str(env_path), "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"fixture keystore").decode(),
            "ANDROID_STORE_PASSWORD": "password:= with \\ newline\n", "ANDROID_KEY_ALIAS": "upload",
            "ANDROID_KEY_PASSWORD": "another password",
        }
        with patch.dict(os.environ, env, clear=True):
            release.prepare_signing(self.root)
            directory = Path(env_path.read_text().strip().split("=", 1)[1])
            props = self.root / "android/key.properties"
            self.assertEqual(props.stat().st_mode & 0o777, 0o600)
            self.assertEqual((directory / "upload.jks").stat().st_mode & 0o777, 0o600)
            self.assertIn("password\\:\\=\\ with\\ ", props.read_text())
            with self.assertRaises(release.ReleaseError):
                release.prepare_signing(self.root)
            os.environ["TERMPULSE_SIGNING_DIRECTORY"] = str(directory)
            original = props.read_bytes()
            props.write_text("unrelated modification")
            with self.assertRaises(release.ReleaseError):
                release.clean_signing(self.root)
            props.write_bytes(original)
            release.clean_signing(self.root)
            self.assertFalse(props.exists())
            self.assertFalse(directory.exists())

    def test_cleanup_refuses_outside_directory(self):
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root), "TERMPULSE_SIGNING_DIRECTORY": str(self.root.parent)}, clear=True):
            with self.assertRaises(release.ReleaseError):
                release.clean_signing(self.root)

    def test_android_abis_and_required_native_libraries(self):
        release.validate_android_zip(self.android(("arm64-v8a",)), ("arm64-v8a",))
        release.validate_android_zip(self.android(release.ANDROID_ABIS, True), release.ANDROID_ABIS, bundle=True)
        with self.assertRaises(release.ReleaseError):
            release.validate_android_zip(self.android(("arm64-v8a",), omit="librust_lib_termpulse.so"), ("arm64-v8a",))
        with self.assertRaises(release.ReleaseError):
            release.validate_android_zip(self.android(("x86_64",)), ("arm64-v8a",))

    def test_linux_archive_preserves_complete_bundle_modes_and_metadata(self):
        source = self.native("linux-x64")
        (source / "lib/libexample.so").symlink_to("librust_lib_termpulse.so")
        path = release.package_desktop(self.root, self.output, "linux-x64", {"commit": "fixture", "version": "1.0.0+1"})
        with tarfile.open(path) as archive:
            prefix = "termpulse-linux-x64/"
            self.assertEqual(archive.getmember(prefix + "termpulse").mode & 0o111, 0o111)
            self.assertTrue(archive.getmember(prefix + "lib/libexample.so").issym())
            self.assertEqual(json.load(archive.extractfile(prefix + "BUILD_INFO.json"))["commit"], "fixture")
            self.assertIsNotNone(archive.getmember(prefix + "data/flutter_assets/AssetManifest.bin"))

    def test_windows_archive_includes_all_libraries_and_assets(self):
        self.native("windows-x64")
        path = release.package_desktop(self.root, self.output, "windows-x64", {"commit": "fixture"})
        with zipfile.ZipFile(path) as archive:
            for item in ("termpulse.exe", "rust_lib_termpulse.dll", "flutter_windows.dll", "data/flutter_assets/AssetManifest.bin", "BUILD_INFO.json", "RELEASE_README.txt"):
                self.assertIn("termpulse-windows-x64/" + item, archive.namelist())

    def test_incomplete_native_bundle_and_escaping_symlink_fail(self):
        source = self.native("linux-x64")
        (source / "lib/librust_lib_termpulse.so").unlink()
        with self.assertRaises(release.ReleaseError):
            release.package_desktop(self.root, self.output, "linux-x64", {})
        (source / "lib/librust_lib_termpulse.so").write_bytes(b"library")
        (source / "outside").symlink_to(self.root / "pubspec.yaml")
        with self.assertRaises(release.ReleaseError):
            release.package_desktop(self.root, self.output, "linux-x64", {})

    def complete_assets(self):
        self.output.mkdir()
        for name in release.ASSETS:
            path = self.output / name
            if name.endswith(".tar.gz"):
                payload = self.write("payload", b"fixture")
                with tarfile.open(path, "w:gz") as archive:
                    archive.add(payload, arcname="fixture")
            else:
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("fixture", b"fixture")

    def test_checksums_require_every_platform_and_match_exact_bytes(self):
        self.complete_assets()
        release.checksums(self.output)
        entries = (self.output / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(entries), 9)
        for line in entries:
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        (self.output / release.ASSETS[0]).unlink()
        with self.assertRaises(release.ReleaseError):
            release.checksums(self.output)

    def test_unexpected_or_corrupt_asset_cannot_be_published(self):
        self.complete_assets()
        (self.output / "debug.apk").write_bytes(b"debug")
        with self.assertRaises(release.ReleaseError):
            release.verify_assets(self.output)
        (self.output / "debug.apk").unlink()
        (self.output / release.ASSETS[0]).write_bytes(b"not an apk")
        with self.assertRaises(zipfile.BadZipFile):
            release.verify_assets(self.output)


if __name__ == "__main__":
    unittest.main()
