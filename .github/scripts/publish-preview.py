#!/usr/bin/env python3
"""Publish inspected native CI outputs; never execute artifact content."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

REPO = "hoangtuvungcao/termpulse"
WORKFLOW = ".github/workflows/platform-checks.yml"
ARTIFACTS = {
    "native-linux-x64", "native-windows-x64",
    "native-macos-arm64", "native-macos-x64",
    "android-debug-preview-not-for-store",
}
PAYLOADS = {
    "native-linux-x64": {"termpulse-linux-x64.tar.gz"},
    "native-windows-x64": {"termpulse-windows-x64.zip"},
    "native-macos-arm64": {
        "termpulse-macos-arm64.zip",
        "termpulse-ios-unsigned-dev-only-arm64.app.zip",
    },
    "native-macos-x64": {"termpulse-macos-x64.zip"},
    "android-debug-preview-not-for-store": {
        "app-armeabi-v7a-debug.apk", "app-arm64-v8a-debug.apk", "app-x86_64-debug.apk",
    },
}
ABIS = {"armeabi-v7a", "arm64-v8a", "x86_64"}
PLATFORMS = {"linux", "windows", "macos", "ios", "android"}
ARCHIVE = re.compile(r"termpulse-(linux|windows|macos|ios)-[A-Za-z0-9._-]+\.(tar\.gz|zip)")
APK = re.compile(r"app-(armeabi-v7a|arm64-v8a|x86_64)-debug\.apk")
LIMIT = 8 * 1024**3
DOWNLOAD_LIMIT = 2 * 1024**3
MEMBER_LIMIT = 100000


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def gh(*args, data=None, output=None, missing_ok=False):
    command = ["gh", *args]
    if data is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(
        command, input=json.dumps(data).encode() if data is not None else None,
        stdout=output if output is not None else subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        if missing_ok and b"HTTP 404" in result.stderr:
            return None
        # Never print raw CLI errors: they can contain signed storage URLs.
        raise RuntimeError("GitHub CLI request failed.")
    if output is None:
        return json.loads(result.stdout) if result.stdout else None
    return None


def api(path, method="GET", data=None, missing_ok=False):
    return gh("api", "--method", method, path, data=data, missing_ok=missing_ok)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def consume(stream):
    total = 0
    while chunk := stream.read(1024 * 1024):
        total += len(chunk)
        require(total <= LIMIT, "Archive exceeds the size limit.")
    return total


def safe_path(name):
    require(
        bool(name) and "\x00" not in name and "\\" not in name
        and ":" not in name and not name.startswith("/"),
        "Archive contains an unsafe path.",
    )
    path = PurePosixPath(name)
    require(".." not in path.parts, "Archive contains path traversal.")
    return path


def safe_link(member, target, hardlink=False):
    require(
        bool(target) and "\x00" not in target and "\\" not in target
        and ":" not in target and not target.startswith("/"),
        "Archive contains an unsafe link.",
    )
    parts = [] if hardlink else list(member.parent.parts)
    for part in PurePosixPath(target).parts:
        if part == "..":
            require(bool(parts), "Archive link escapes its root.")
            parts.pop()
        elif part != ".":
            parts.append(part)
    require(bool(parts), "Archive link target is invalid.")


def inspect_zip(path, abi=None, outer=False):
    names = set()
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        require(0 < len(members) <= MEMBER_LIMIT, "ZIP member count is invalid.")
        require(sum(item.file_size for item in members) <= LIMIT, "ZIP exceeds the size limit.")
        require(any(not item.is_dir() and item.file_size > 0 for item in members),
                "ZIP has no nonempty payload.")
        for item in members:
            member = safe_path(item.orig_filename)
            require(item.filename not in names, "ZIP contains duplicate paths.")
            names.add(item.filename)
            require(not item.flag_bits & 1, "Encrypted ZIP members are not accepted.")
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                require(not outer and item.file_size <= 4096, "Unexpected artifact link.")
                safe_link(member, archive.read(item).decode("utf-8"))
            else:
                require(
                    stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR),
                    "ZIP contains a special filesystem object.",
                )
                if not item.is_dir():
                    with archive.open(item) as stream:
                        require(consume(stream) == item.file_size, "ZIP member size is incorrect.")
    if abi:
        require(
            {"AndroidManifest.xml", "classes.dex", f"lib/{abi}/libflutter.so"} <= names,
            "APK is missing its manifest, bytecode or expected ABI.",
        )
        found = {name.split("/")[1] for name in names
                 if name.startswith("lib/") and len(name.split("/")) >= 3}
        require(found == {abi}, "APK ABI does not match its filename.")
    return names


def inspect_tar(path):
    with gzip.open(path, "rb") as stream:
        consume(stream)  # Complete stream read checks gzip CRC and truncation.
    names = set()
    total = 0
    with tarfile.open(path, "r:gz") as archive:
        for item in archive:
            require(len(names) < MEMBER_LIMIT, "TAR has too many members.")
            member = safe_path(item.name)
            require(item.name not in names, "TAR contains duplicate paths.")
            names.add(item.name)
            total += item.size
            require(total <= LIMIT, "TAR exceeds the size limit.")
            if item.issym() or item.islnk():
                safe_link(member, item.linkname, item.islnk())
            else:
                require(item.isfile() or item.isdir(), "TAR contains a special object.")
                if item.isfile():
                    stream = archive.extractfile(item)
                    require(stream is not None, "TAR member cannot be read.")
                    with stream:
                        require(consume(stream) == item.size, "TAR member is truncated.")
    require(bool(names), "TAR is empty.")
    return names


def collect(artifact, destination, seen, supplied_checksums):
    inspect_zip(artifact, outer=True)
    with zipfile.ZipFile(artifact) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            name = safe_path(item.filename).name
            if name in {"BUILD_INFO", "BUILD_INFO.txt"}:
                continue  # Regenerate provenance from trusted run metadata.
            if name == "SHA256SUMS" or name.endswith(".sha256") or name.endswith("-SHA256SUMS"):
                require(item.file_size <= 1024 * 1024, "Checksum metadata is too large.")
                for line in archive.read(item).decode("utf-8").splitlines():
                    match = re.fullmatch(r"([0-9a-fA-F]{64})[ \t]+\*?([A-Za-z0-9._-]+)", line)
                    if not line.strip():
                        continue
                    if not match and re.fullmatch(r"[0-9a-fA-F]{64}", line.strip()) and name.endswith(".sha256"):
                        supplied_checksums.append((name[:-7], line.strip().lower()))
                    else:
                        require(match is not None, "Checksum metadata is malformed.")
                        supplied_checksums.append((match[2], match[1].lower()))
                continue
            packaged, apk = ARCHIVE.fullmatch(name), APK.fullmatch(name)
            require(packaged is not None or apk is not None, "Artifact has an unexpected payload.")
            public_name = f"termpulse-android-{apk[1]}-debug-preview.apk" if apk else name
            require(public_name not in seen, "Native artifacts contain duplicate payloads.")
            output = destination / public_name
            with archive.open(item) as source, output.open("xb") as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            if apk:
                inspect_zip(output, abi=apk[1])
            elif name.endswith(".tar.gz"):
                inspect_tar(output)
            else:
                inspect_zip(output)
            seen[public_name] = {
                "platform": "android" if apk else packaged[1],
                "abi": apk[1] if apk else None,
                "source_name": name,
                "sha256": sha256(output),
            }


def validate_run(run, workflow):
    require(
        workflow.get("path") == WORKFLOW
        and workflow.get("name") == "Native platform checks"
        and run.get("workflow_id") == workflow.get("id"),
        "Source run is not the expected native-check workflow.",
    )
    require(
        run.get("status") == "completed" and run.get("conclusion") == "success",
        "Source run must have completed successfully.",
    )
    require(
        run.get("repository", {}).get("full_name") == REPO
        and run.get("head_repository", {}).get("full_name") == REPO
        and run.get("head_branch") == "main"
        and run.get("event") in {"push", "workflow_dispatch"},
        "Source run is not a trusted main push/manual run.",
    )
    require(re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")) is not None,
            "Source commit SHA is invalid.")
    for key in ("id", "run_number", "run_attempt"):
        require(type(run.get(key)) is int and run[key] > 0, "Source run identity is invalid.")


def notes(sha, source_url):
    return f"""## Bản xem trước cộng đồng / Community preview

Commit: {sha}
Source workflow: {source_url}

VI: Bản tự động để cộng đồng kiểm thử, chưa phải bản ổn định hoặc xác nhận Google Play/App Store.
- Linux/Windows chưa ký phát hành; macOS chỉ ký ad-hoc, chưa ký Developer ID và chưa notarize. Hệ điều hành có thể cảnh báo.
- Android là APK debug ký bằng khóa phát triển, không dùng để nộp Google Play. Chỉ dùng bản cài thử riêng; không bảo đảm chữ ký hoặc nâng cấp giữa các lượt build. Bảo vệ Vault hiện có trước khi thử.
- iOS là gói biên dịch không ký, không cài trực tiếp; cần macOS/Xcode và cấu hình ký riêng.
- Kiểm tra SHA256SUMS và BUILD_INFO. Xem README/báo cáo QA để biết giới hạn giao thức, thiết bị và nền tảng.

EN: Automated community testing preview, not a stable release or Google Play/App Store approval.
- Linux/Windows artifacts are unsigned; macOS is ad-hoc signed only, not Developer ID signed or notarized. OS warnings may appear.
- Android APKs are debug-signed development builds, not Google Play releases. Use a disposable test install; signing or upgrade continuity is not guaranteed. Protect any existing Vault before testing.
- iOS is an unsigned compile artifact, not directly installable. A macOS/Xcode environment and separate signing configuration are required.
- Verify SHA256SUMS and BUILD_INFO. See README and dated QA reports for protocol, device and platform limitations.

This preview supplies no project license, publisher identity or privacy contact.
"""


def publish(source_id, repository):
    require(repository == REPO, "Unexpected publisher repository.")
    require(re.fullmatch(r"[1-9][0-9]*", source_id) is not None, "Source run ID is invalid.")
    prefix = f"repos/{REPO}"
    run = api(f"{prefix}/actions/runs/{source_id}")
    workflow = api(f"{prefix}/actions/workflows/platform-checks.yml")
    validate_run(run, workflow)
    require(run["id"] == int(source_id), "Source run ID does not match.")
    tag = f"community-preview-{run['run_number']}-{run['run_attempt']}"
    existing_refs = api(f"{prefix}/git/matching-refs/tags/{tag}")
    require(
        api(f"{prefix}/releases/tags/{tag}", missing_ok=True) is None
        and not any(item.get("ref") == "refs/tags/" + tag for item in existing_refs),
        "Preview tag/release already exists; refusing to overwrite.",
    )
    artifacts = []
    for page in range(1, 11):
        result = api(f"{prefix}/actions/runs/{source_id}/artifacts?per_page=100&page={page}")
        batch = result["artifacts"]
        artifacts.extend(item for item in batch if item.get("name") in ARTIFACTS)
        if len(batch) < 100:
            break
    else:
        raise RuntimeError("Unexpected source artifact count.")
    require(
        len(artifacts) == len(ARTIFACTS) and {item["name"] for item in artifacts} == ARTIFACTS,
        "Expected native artifacts are missing or duplicated.",
    )
    source_url = f"https://github.com/{REPO}/actions/runs/{source_id}/attempts/{run['run_attempt']}"
    with tempfile.TemporaryDirectory(prefix="termpulse-preview-") as temporary:
        root = Path(temporary)
        assets = root / "assets"
        assets.mkdir()
        seen, supplied_checksums, provenance = {}, [], []
        for item in sorted(artifacts, key=lambda value: value["name"]):
            identity = item.get("workflow_run", {})
            require(
                not item.get("expired") and type(item.get("id")) is int
                and 0 < item.get("size_in_bytes", 0) <= DOWNLOAD_LIMIT
                and identity.get("id") == run["id"] and identity.get("head_sha") == run["head_sha"]
                and identity.get("head_branch") == "main",
                "Artifact provenance, availability or size is invalid.",
            )
            downloaded = root / f"{item['id']}.zip"
            with downloaded.open("xb") as output:
                gh("api", f"{prefix}/actions/artifacts/{item['id']}/zip", output=output)
            require(downloaded.stat().st_size <= DOWNLOAD_LIMIT, "Artifact download is too large.")
            checksum = sha256(downloaded)
            if item.get("digest"):
                require(item["digest"] == "sha256:" + checksum, "Source artifact digest mismatch.")
            provenance.append(f"Source artifact: {item['name']} / id {item['id']} / sha256:{checksum}")
            before = set(seen)
            collect(downloaded, assets, seen, supplied_checksums)
            require(
                {seen[name]["source_name"] for name in set(seen) - before} == PAYLOADS[item["name"]],
                "Native artifact payloads do not match the expected platform bundle.",
            )
        require({value["platform"] for value in seen.values()} == PLATFORMS,
                "Required native platform payload is missing.")
        require({value["abi"] for value in seen.values() if value["platform"] == "android"} == ABIS,
                "Required Android debug ABI is missing.")
        require(
            any("macos-arm64" in name for name in seen)
            and any("macos-x64" in name for name in seen),
            "Both macOS architecture bundles are required.",
        )
        source_digests = {value["source_name"]: value["sha256"] for value in seen.values()}
        for name, expected in supplied_checksums:
            require(source_digests.get(name) == expected, "Supplied payload checksum mismatch.")
        build_info = "\n".join([
            "TermPulse public community preview", f"Repository: {REPO}",
            f"Commit: {run['head_sha']}", f"Source workflow: {WORKFLOW}",
            f"Source workflow URL: {source_url}",
            f"Source run: {run['run_number']} / attempt {run['run_attempt']}",
            f"Source event: {run['event']}",
            "Artifact contents were inspected, never executed.",
            "Linux/Windows unsigned; macOS ad-hoc only, not Developer ID signed or notarized.",
            "Android debug-signed development APKs, not store releases.",
            "iOS unsigned compile artifact, not directly installable.",
            *provenance, "",
        ])
        (assets / "BUILD_INFO").write_text(build_info, encoding="utf-8")
        sums = "".join(f"{sha256(path)}  {path.name}\n" for path in sorted(assets.iterdir()))
        (assets / "SHA256SUMS").write_text(sums, encoding="utf-8")
        release = api(f"{prefix}/releases", "POST", {
            "tag_name": tag, "target_commitish": run["head_sha"],
            "name": f"Community preview {run['run_number']} (attempt {run['run_attempt']})",
            "body": notes(run["head_sha"], source_url),
            "draft": True, "prerelease": True, "make_latest": "false",
        })
        files = sorted(assets.iterdir())
        gh("release", "upload", tag, *[str(path) for path in files], "--repo", REPO,
           output=subprocess.DEVNULL)
        uploaded = api(f"{prefix}/releases/{release['id']}/assets?per_page=100")
        require(
            {(item["name"], item["size"]) for item in uploaded}
            == {(path.name, path.stat().st_size) for path in files},
            "Uploaded release asset list is incomplete.",
        )
        by_name = {path.name: path for path in files}
        for item in uploaded:
            if item.get("digest"):
                require(item["digest"] == "sha256:" + sha256(by_name[item["name"]]),
                        "Uploaded release asset digest mismatch.")
        result = api(f"{prefix}/releases/{release['id']}", "PATCH", {
            "draft": False, "prerelease": True, "make_latest": "false",
        })
        require(not result.get("draft") and result.get("prerelease") is True
                and result.get("tag_name") == tag
                and result.get("target_commitish") == run["head_sha"],
                "Prerelease publication failed.")
        print(f"Published: https://github.com/{REPO}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    publish(args.source_run_id, args.repository)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::Community preview failed ({type(error).__name__}); validation or upload failed. An incomplete draft may remain.")
        raise SystemExit(1)
