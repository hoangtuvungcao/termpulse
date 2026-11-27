#!/usr/bin/env python3
"""Retry Android builds only for explicit Maven/Gradle HTTP 429 downloads."""

from __future__ import annotations

from collections import deque
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Callable, Sequence, TextIO


MAX_ATTEMPTS = 3
RETRY_DELAYS = (30, 60)


def is_dependency_throttle(output: str) -> bool:
    # A preceding Flutter retry must not mask a later compilation failure.
    latest_failure = re.split(
        r"FAILURE:\s*Build failed with an exception\.", output, flags=re.IGNORECASE
    )[-1]
    has_rate_limit = re.search(
        r"HTTP(?:/\d(?:\.\d)?)?\s+429\b"
        r"|\b(?:status|response)(?:\s+code)?\s*(?::|=|was)?\s*429\b"
        r"|\b429\s+(?:from server:\s*)?Too Many Requests\b",
        latest_failure,
        re.IGNORECASE,
    )
    has_download_failure = re.search(
        r"Could not (?:resolve|download|get resource|GET|HEAD)"
        r"|failed to download|downloading artifacts from the network",
        latest_failure,
        re.IGNORECASE,
    )
    has_artifact_url = re.search(
        r"https?://(?:plugins\.gradle\.org|repo\.maven\.apache\.org"
        r"|repo1\.maven\.org|dl\.google\.com|maven\.google\.com)(?:[/:])",
        latest_failure,
        re.IGNORECASE,
    )
    has_build_failure = re.search(
        r"(?:^|\n)e:\s+file:|Compilation (?:error|failed)"
        r"|error\[[A-Z]?\d+\]|fatal error:|error:\s+could not compile"
        r"|ld: symbol\(s\) not found|There were failing tests"
        r"|Execution failed for task ['\"][^'\"]*[Tt]est",
        latest_failure,
        re.IGNORECASE,
    )
    return bool(
        has_rate_limit
        and has_download_failure
        and has_artifact_url
        and not has_build_failure
    )


def run_android_build(
    command: Sequence[str],
    *,
    sleep: Callable[[float], None] | None = None,
    stream: TextIO | None = None,
) -> int:
    if (
        len(command) < 3
        or Path(command[0]).stem.lower() != "flutter"
        or command[1] != "build"
        or command[2] not in ("apk", "appbundle")
    ):
        raise ValueError("Expected a Flutter Android apk or appbundle build command.")
    destination = sys.stdout if stream is None else stream
    wait = time.sleep if sleep is None else sleep
    for attempt in range(MAX_ATTEMPTS):
        recent_output: deque[str] = deque(maxlen=4096)
        process = subprocess.Popen(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        assert process.stdout is not None
        try:
            for line in process.stdout:
                destination.write(line)
                destination.flush()
                recent_output.append(line)
        finally:
            process.stdout.close()
        returncode = process.wait()
        if (
            returncode == 0
            or attempt == MAX_ATTEMPTS - 1
            or not is_dependency_throttle("".join(recent_output))
        ):
            return returncode
        delay = RETRY_DELAYS[attempt]
        destination.write(
            f"Android dependency downloads were rate-limited (HTTP 429). "
            f"Retrying in {delay} seconds (attempt {attempt + 2}/{MAX_ATTEMPTS}).\n"
        )
        destination.flush()
        wait(delay)
    raise AssertionError("Unreachable retry state.")


def main(argv: Sequence[str] | None = None) -> int:
    command = list(sys.argv[1:] if argv is None else argv)
    if command and command[0] == "--":
        command.pop(0)
    try:
        return run_android_build(command)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    except OSError as error:
        print(f"Unable to start the Android build: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main())
