#!/usr/bin/env python3
"""Fail-closed native release packaging. Uses only the Python standard library."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit
import zipfile


ROOT = Path(__file__).resolve().parent.parent
ANDROID_ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
ASSETS = tuple(
    [f"termpulse-android-{abi}.apk" for abi in ANDROID_ABIS]
    + [
        "termpulse-android-play-upload.aab",
        "termpulse-linux-x64.tar.gz",
        "termpulse-windows-x64.zip",
        "termpulse-macos-arm64.zip",
        "termpulse-macos-x64.zip",
        "termpulse-ios-unsigned-dev-only-arm64.app.zip",
    ]
)
PRIVACY_KEYS = ("PRIVACY_PUBLISHER_NAME", "PRIVACY_CONTACT_EMAIL", "PRIVACY_POLICY_URL")
SIGNING_KEYS = (
    "ANDROID_KEYSTORE_BASE64", "ANDROID_STORE_PASSWORD",
    "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
)


class ReleaseError(Exception):
    """A safe diagnostic that contains no credential values."""


def run(args: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    executable = shutil.which(args[0])
    if not executable:
        raise ReleaseError(f"Required tool is unavailable: {args[0]}")
    result = subprocess.run(
        [executable, *args[1:]], cwd=cwd, check=False, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if result.returncode:
        # Captured signing-tool output can include certificate subjects or paths.
        # Keep failure messages bounded and never echo command arguments/secrets.
        raise ReleaseError(f"{Path(executable).name} failed (exit {result.returncode}).")
    return result.stdout or ""


def version(root: Path) -> str:
    match = re.search(r"^version:\s*([^\s#]+)", (root / "pubspec.yaml").read_text(), re.M)
    if not match or not re.fullmatch(
        r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+\d+", match[1]
    ):
        raise ReleaseError("pubspec.yaml must contain a release version and numeric build number.")
    return match[1]


def validate_tag(root: Path, tag: str | None = None) -> str:
    current = tag if tag is not None else os.environ.get("GITHUB_REF_NAME", "")
    expected = "v" + version(root).split("+", 1)[0]
    if current != expected:
        raise ReleaseError(f"Release tag must match pubspec.yaml: expected {expected}.")
    return current


def required_env(names: tuple[str, ...]) -> dict[str, str]:
    missing = [key for key in names if not os.environ.get(key, "").strip()]
    if missing:
        raise ReleaseError("Missing required release settings: " + ", ".join(missing))
    return {key: os.environ[key] for key in names}


def privacy_values() -> dict[str, str]:
    values = {key: value.strip() for key, value in required_env(PRIVACY_KEYS).items()}
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", values["PRIVACY_CONTACT_EMAIL"]):
        raise ReleaseError("PRIVACY_CONTACT_EMAIL must be a valid public contact email.")
    try:
        parsed = urlsplit(values["PRIVACY_POLICY_URL"])
        valid = parsed.scheme.lower() == "https" and parsed.hostname and parsed.username is None and parsed.password is None
        valid = valid and parsed.hostname.lower() not in {"localhost", "127.0.0.1", "::1"}
        parsed.port  # Reject malformed port numbers while preserving an explicit HTTPS port.
    except ValueError:
        valid = False
    if not valid:
        raise ReleaseError("PRIVACY_POLICY_URL must be a public HTTPS policy URL without credentials.")
    return values


def property_escape(value: str) -> str:
    """Encode a value for java.util.Properties.load(InputStream), including Unicode."""
    result = []
    for char in value:
        if char in "\\=:#! ":
            result.append("\\" + char)
        elif char in "\n\r\t\f":
            result.append({"\n": "\\n", "\r": "\\r", "\t": "\\t", "\f": "\\f"}[char])
        elif ord(char) < 0x20 or ord(char) > 0x7E:
            encoded = char.encode("utf-16-be")
            result.extend(f"\\u{int.from_bytes(encoded[i:i + 2], 'big'):04x}" for i in range(0, len(encoded), 2))
        else:
            result.append(char)
    return "".join(result)


def private_write(path: Path, content: bytes) -> None:
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(content)


def prepare_signing(root: Path) -> None:
    privacy_values()
    values = required_env(SIGNING_KEYS)
    if not os.environ.get("GITHUB_ENV") or not os.environ.get("RUNNER_TEMP"):
        raise ReleaseError("CI signing preparation requires GITHUB_ENV and RUNNER_TEMP.")
    properties = root / "android/key.properties"
    if properties.exists() or properties.is_symlink():
        raise ReleaseError("Refusing to overwrite existing android/key.properties.")
    try:
        keystore = base64.b64decode("".join(values["ANDROID_KEYSTORE_BASE64"].split()), validate=True)
    except (ValueError, binascii.Error):
        raise ReleaseError("ANDROID_KEYSTORE_BASE64 is not valid base64.") from None
    if not keystore:
        raise ReleaseError("ANDROID_KEYSTORE_BASE64 decoded to an empty file.")
    temp_root = Path(os.environ["RUNNER_TEMP"]).resolve()
    directory = Path(tempfile.mkdtemp(prefix="termpulse-signing-", dir=temp_root))
    wrote_properties = False
    try:
        store = directory / "upload.jks"
        private_write(store, keystore)
        fields = {
            "storeFile": str(store), "storePassword": values["ANDROID_STORE_PASSWORD"],
            "keyAlias": values["ANDROID_KEY_ALIAS"], "keyPassword": values["ANDROID_KEY_PASSWORD"],
        }
        data = "".join(f"{key}={property_escape(value)}\n" for key, value in fields.items()).encode("ascii")
        private_write(properties, data)
        wrote_properties = True
        private_write(directory / "key.properties.created", hashlib.sha256(data).hexdigest().encode("ascii"))
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as stream:
            stream.write(f"TERMPULSE_SIGNING_DIRECTORY={directory}\n")
    except Exception:
        if wrote_properties:
            properties.unlink(missing_ok=True)
        shutil.rmtree(directory)
        raise
    print("Temporary upload signing is configured; release builds cannot use a debug key.")


def clean_signing(root: Path) -> None:
    value = os.environ.get("TERMPULSE_SIGNING_DIRECTORY")
    if not value:
        print("No temporary CI signing material was created.")
        return
    temp_root = Path(os.environ.get("RUNNER_TEMP", "")).resolve()
    directory = Path(value)
    if directory.is_symlink() or directory.resolve().parent != temp_root or not directory.name.startswith("termpulse-signing-"):
        raise ReleaseError("Refusing to clean a directory outside this job's signing scope.")
    marker = directory / "key.properties.created"
    properties = root / "android/key.properties"
    if not marker.is_file():
        raise ReleaseError("Signing cleanup ownership marker is missing.")
    if properties.exists():
        if properties.is_symlink() or hashlib.sha256(properties.read_bytes()).hexdigest() != marker.read_text():
            raise ReleaseError("Signing properties changed unexpectedly; refusing to delete them.")
        properties.unlink()
    shutil.rmtree(directory)
    print("Removed this job's temporary upload keystore and signing properties.")


def build_android(root: Path) -> None:
    values = privacy_values()
    if not (root / "android/key.properties").is_file():
        raise ReleaseError("Signed Android release requires android/key.properties; no debug fallback exists.")
    defines = [f"--dart-define={key}={value}" for key, value in values.items()]
    common = ["--release", "--no-pub", "--target-platform", "android-arm,android-arm64,android-x64", *defines]
    run(["flutter", "build", "apk", "--split-per-abi", *common], cwd=root)
    run(["flutter", "build", "appbundle", *common], cwd=root)


def metadata(root: Path, target: str) -> dict:
    def tool(args: list[str]) -> str:
        return run(args, cwd=root, capture=True).strip()

    flutter = json.loads(tool(["flutter", "--version", "--machine"]))
    return {
        "application": "TermPulse", "version": version(root), "platform": target,
        "commit": os.environ.get("GITHUB_SHA") or tool(["git", "rev-parse", "HEAD"]),
        "flutter": flutter.get("frameworkVersion"), "dart": flutter.get("dartSdkVersion"),
        "rustc": tool(["rustup", "run", "stable", "rustc", "--version"]),
        "cargo": tool(["rustup", "run", "stable", "cargo", "--version"]),
        "runner": {"os": platform.system(), "architecture": platform.machine()},
        "signing": (
            "Unsigned device application; requires developer signing before installation."
            if target.startswith("ios-") else
            "Ad-hoc signature only; not Developer-ID signed or notarized."
            if target.startswith("macos-") else
            "Unsigned executable; no Windows Authenticode certificate."
            if target == "windows-x64" else "No distribution code-signing certificate."
        ),
    }


def require_files(base: Path, names: tuple[str, ...]) -> None:
    for name in names:
        path = base / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ReleaseError(f"Native bundle is incomplete: missing or empty {name}.")


def require_assets(path: Path) -> None:
    if not path.is_dir() or not any(item.is_file() for item in path.rglob("*")):
        raise ReleaseError("Native bundle is missing its Flutter assets.")


def validate_symlinks(base: Path) -> None:
    for path in base.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(base.resolve()):
            raise ReleaseError("Native bundle contains a symlink outside its bundle.")


def package_desktop(root: Path, output: Path, target: str, info: dict | None = None) -> Path:
    sources = {
        "linux-x64": "build/linux/x64/release/bundle",
        "windows-x64": "build/windows/x64/runner/Release",
        "macos-arm64": "build/macos/Build/Products/Release/termpulse.app",
        "macos-x64": "build/macos/Build/Products/Release/termpulse.app",
        "ios-unsigned-dev-only-arm64": "build/ios/iphoneos/Runner.app",
    }
    source = root / sources[target]
    if target == "linux-x64":
        require_files(source, ("termpulse", "lib/librust_lib_termpulse.so", "lib/libflutter_linux_gtk.so"))
        require_assets(source / "data/flutter_assets")
        if not os.access(source / "termpulse", os.X_OK):
            raise ReleaseError("Linux executable has lost its executable permission.")
    elif target == "windows-x64":
        require_files(source, ("termpulse.exe", "rust_lib_termpulse.dll", "flutter_windows.dll"))
        require_assets(source / "data/flutter_assets")
    else:
        ios = target.startswith("ios-")
        executable = source / ("Runner" if ios else "Contents/MacOS/termpulse")
        require_files(source, ("Runner", "Info.plist") if ios else ("Contents/MacOS/termpulse", "Contents/Info.plist"))
        require_assets(source / ("Frameworks/App.framework/flutter_assets" if ios else "Contents/Frameworks/App.framework/Resources/flutter_assets"))
        expected = "arm64" if target.endswith("arm64") else "x86_64"
        architectures = run(["lipo", "-archs", str(executable)], capture=True).split()
        if expected not in architectures:
            raise ReleaseError(f"Apple application does not contain its labeled {expected} architecture.")
    validate_symlinks(source)
    build_info = info if info is not None else metadata(root, target)
    suffix = ".tar.gz" if target == "linux-x64" else ".app.zip" if target.startswith("ios-") else ".zip"
    destination = output / f"termpulse-{target}{suffix}"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="termpulse-package-") as temporary:
        stage = Path(temporary) / f"termpulse-{target}"
        if target.startswith(("macos-", "ios-")):
            stage.mkdir()
            # ditto preserves Apple bundle symlinks, modes and resource metadata.
            run(["ditto", str(source), str(stage / source.name)])
        else:
            shutil.copytree(source, stage, symlinks=True)
        (stage / "BUILD_INFO.json").write_text(json.dumps(build_info, indent=2) + "\n", encoding="utf-8")
        guidance = {
            "linux-x64": "Extract the entire archive and run ./termpulse. Keep lib/ and data/ beside the executable.\n",
            "windows-x64": "Extract the entire archive and run termpulse.exe. Keep all DLLs and data/. This build is not Authenticode signed.\n",
        }.get(target, (
            "DEVELOPMENT ONLY: This is an unsigned ARM64 iOS .app, not an App Store IPA. It cannot be installed as distributed; a developer must sign it for a permitted device.\n"
            if target.startswith("ios-") else
            "This macOS application is ad-hoc signed only, not Developer-ID signed or notarized. macOS may block it under Gatekeeper.\n"
        ))
        (stage / "RELEASE_README.txt").write_text(guidance, encoding="utf-8")
        if target == "linux-x64":
            with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
                archive.add(stage, arcname=stage.name)
        elif target.startswith(("macos-", "ios-")):
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(destination)])
        else:
            with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                for path in sorted(stage.rglob("*")):
                    archive.write(path, path.relative_to(stage.parent))
    print(f"Packaged {destination.name}")
    return destination


def validate_android_zip(path: Path, abis: tuple[str, ...], *, bundle: bool = False) -> None:
    with zipfile.ZipFile(path) as archive:
        if archive.testzip():
            raise ReleaseError(f"Android archive is corrupt: {path.name}.")
        names = set(archive.namelist())
        prefix = "base/" if bundle else ""
        native_abis = {name.split("/")[1 + bool(bundle)] for name in names if name.startswith(prefix + "lib/") and name.endswith(".so")}
        if native_abis != set(abis):
            raise ReleaseError(f"Android archive has unexpected or missing ABIs: {path.name}.")
        for abi in abis:
            for library in ("librust_lib_termpulse.so", "libflutter.so", "libapp.so"):
                name = f"{prefix}lib/{abi}/{library}"
                if name not in names or archive.getinfo(name).file_size == 0:
                    raise ReleaseError(f"Android archive is missing {abi}/{library}.")
        if not any(name.startswith(prefix + "assets/flutter_assets/") for name in names):
            raise ReleaseError("Android archive is missing Flutter assets.")
        if bundle and not any(re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC)", name, re.I) for name in names):
            raise ReleaseError("The Android app bundle has no upload signature.")


def android_tool(name: str) -> str:
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") or "")
    candidate = sdk / "build-tools/36.0.0" / name
    if not candidate.is_file():
        raise ReleaseError(f"Android SDK build-tools 36.0.0 is required for {name}.")
    return str(candidate)


def package_android(root: Path, output: Path) -> None:
    apk_dir = root / "build/app/outputs/flutter-apk"
    prepared: list[tuple[Path, str]] = []
    fingerprints = set()
    for abi in ANDROID_ABIS:
        apk = apk_dir / f"app-{abi}-release.apk"
        if not apk.is_file():
            raise ReleaseError(f"Signed release APK is missing for {abi}.")
        validate_android_zip(apk, (abi,))
        verified = run([android_tool("apksigner"), "verify", "--verbose", "--print-certs", str(apk)], capture=True)
        if "CN=Android Debug" in verified:
            raise ReleaseError("A debug-signed APK cannot be published as a release.")
        digests = re.findall(r"Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]+)", verified)
        if len(digests) != 1:
            raise ReleaseError("Release APK must have exactly one verifiable signing identity.")
        fingerprints.add(digests[0].lower())
        run([android_tool("zipalign"), "-c", "-P", "16", "4", str(apk)], capture=True)
        prepared.append((apk, f"termpulse-android-{abi}.apk"))
    if len(fingerprints) != 1:
        raise ReleaseError("Android split APK signing identities do not match.")
    aab = root / "build/app/outputs/bundle/release/app-release.aab"
    if not aab.is_file():
        raise ReleaseError("Signed Play upload app bundle is missing.")
    validate_android_zip(aab, ANDROID_ABIS, bundle=True)
    result = run(["jarsigner", "-verify", str(aab)], capture=True)
    if "jar verified" not in result.lower():
        raise ReleaseError("Android app bundle upload signature verification failed.")
    certificate = run(["keytool", "-printcert", "-jarfile", str(aab)], capture=True)
    match = re.search(r"SHA256:\s*([0-9a-fA-F:]+)", certificate)
    if not match or match[1].replace(":", "").lower() not in fingerprints:
        raise ReleaseError("Play upload bundle and split APK signing identities do not match.")
    prepared.append((aab, "termpulse-android-play-upload.aab"))
    output.mkdir(parents=True, exist_ok=True)
    for source, name in prepared:
        shutil.copy2(source, output / name)
    print("Packaged three signed Android ABIs and the matching signed Play upload bundle.")


def verify_assets(output: Path) -> list[Path]:
    if not output.is_dir():
        raise ReleaseError("Release asset directory does not exist.")
    actual = {path.name for path in output.iterdir()}
    missing = set(ASSETS) - actual
    extra = actual - set(ASSETS) - {"SHA256SUMS"}
    if missing or extra:
        raise ReleaseError(f"Release asset set is incomplete or unexpected. Missing: {', '.join(sorted(missing)) or 'none'}; unexpected: {', '.join(sorted(extra)) or 'none'}.")
    paths = [output / name for name in sorted(ASSETS)]
    for path in paths:
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ReleaseError(f"Release asset is empty or unsafe: {path.name}.")
        if path.suffix in {".zip", ".apk", ".aab"}:
            with zipfile.ZipFile(path) as archive:
                if archive.testzip():
                    raise ReleaseError(f"Release asset is corrupt: {path.name}.")
        else:
            with tarfile.open(path, "r:gz") as archive:
                if not archive.getmembers():
                    raise ReleaseError(f"Release archive is empty: {path.name}.")
    return paths


def checksum_text(paths: list[Path]) -> str:
    lines = []
    for path in paths:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        lines.append(f"{digest.hexdigest()}  {path.name}\n")
    return "".join(lines)


def checksums(output: Path) -> None:
    text = checksum_text(verify_assets(output))
    (output / "SHA256SUMS").write_text(text, encoding="ascii")
    print(f"Verified all {len(ASSETS)} native assets and generated SHA256SUMS.")


def publish(root: Path, output: Path) -> None:
    tag = validate_tag(root)
    paths = verify_assets(output)
    sums = output / "SHA256SUMS"
    if not sums.is_file() or sums.read_text(encoding="ascii") != checksum_text(paths):
        raise ReleaseError("SHA256SUMS is missing or does not match the release assets.")
    required_env(("GH_TOKEN", "GH_REPO"))
    notes = (
        f"TermPulse {tag} — native applications for Android, Linux, Windows and macOS.\n\n"
        "Download the asset matching your operating system and CPU, then verify SHA256SUMS. "
        "Extract desktop archives completely; their libraries and Flutter assets are required.\n\n"
        "Android: the three APKs and Play upload AAB are signed with the same upload key. "
        "The AAB is for a Play Console upload, not direct installation.\n\n"
        "Windows: executable is not Authenticode signed. "
        "macOS: ad-hoc signed only, not Developer-ID signed or notarized; Gatekeeper may block it.\n\n"
        "iOS DEVELOPMENT ONLY: unsigned ARM64 .app archive, not an App Store IPA. "
        "It cannot be installed as distributed and requires a developer's signing setup.\n\n"
        "Each desktop/iOS archive includes BUILD_INFO.json with the source commit and tool versions.\n"
    )
    with tempfile.TemporaryDirectory(prefix="termpulse-release-notes-") as temporary:
        note_file = Path(temporary) / "notes.md"
        note_file.write_text(notes, encoding="utf-8")
        args = ["gh", "release", "create", tag, "--verify-tag", "--title", f"TermPulse {tag}", "--notes-file", str(note_file)]
        args.append("--prerelease" if "-" in tag else "--latest")
        run([*args, *map(str, paths), str(sums)], cwd=root)
    print(f"Published {tag} with all native assets and SHA256SUMS.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("validate-tag", "prepare-android-signing", "clean-android-signing", "build-android-release", "checksums", "publish"):
        commands.add_parser(command)
    package = commands.add_parser("package")
    package.add_argument("platform", choices=("linux-x64", "windows-x64", "macos-arm64", "macos-x64", "ios-unsigned-dev-only-arm64", "android"))
    args = parser.parse_args()
    root = args.root.resolve()
    output = (args.output or root / "dist").resolve()
    if args.command == "validate-tag":
        print(f"Validated {validate_tag(root)} against application version {version(root)}.")
    elif args.command == "prepare-android-signing":
        prepare_signing(root)
    elif args.command == "clean-android-signing":
        clean_signing(root)
    elif args.command == "build-android-release":
        build_android(root)
    elif args.command == "checksums":
        checksums(output)
    elif args.command == "publish":
        publish(root, output)
    elif args.platform == "android":
        package_android(root, output)
    else:
        package_desktop(root, output, args.platform)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, zipfile.BadZipFile, tarfile.TarError, json.JSONDecodeError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
