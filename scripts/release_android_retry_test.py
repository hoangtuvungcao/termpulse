from __future__ import annotations

import io
import unittest
from unittest.mock import patch

import release_android_retry as retry


THROTTLE = """FAILURE: Build failed with an exception.
Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.0.21.
Could not GET 'https://repo.maven.apache.org/maven2/example.pom'.
Received status code 429 from server: Too Many Requests
"""
COMPILE_FAILURE = """FAILURE: Build failed with an exception.
Execution failed for task ':app:compileReleaseKotlin'.
e: file:///source/Main.kt: Compilation error.
"""


class FakeProcess:
    def __init__(self, output: str, returncode: int):
        self.stdout = io.StringIO(output)
        self.returncode = returncode

    def wait(self) -> int:
        return self.returncode


class AndroidRetryTests(unittest.TestCase):
    def run_build(self, results):
        stream = io.StringIO()
        delays = []
        processes = [FakeProcess(output, code) for output, code in results]
        with patch.object(retry.subprocess, "Popen", side_effect=processes) as popen:
            result = retry.run_android_build(
                ["flutter", "build", "apk", "--debug"],
                sleep=delays.append,
                stream=stream,
            )
        return result, delays, stream.getvalue(), popen.call_count

    def test_recognizes_actual_maven_throttle(self):
        self.assertTrue(retry.is_dependency_throttle(THROTTLE))

    def test_does_not_retry_ordinary_network_failure(self):
        self.assertFalse(
            retry.is_dependency_throttle(
                THROTTLE.replace(
                    "Received status code 429 from server: Too Many Requests",
                    "Connection timed out",
                )
            )
        )

    def test_does_not_retry_application_http_error(self):
        self.assertFalse(
            retry.is_dependency_throttle(
                "Could not GET https://api.example.test HTTP 429 Too Many Requests"
            )
        )

    def test_does_not_retry_compiler_output_containing_number_429(self):
        self.assertFalse(
            retry.is_dependency_throttle(COMPILE_FAILURE + "source line 429\n")
        )

    def test_old_throttle_does_not_mask_latest_compilation_failure(self):
        self.assertFalse(retry.is_dependency_throttle(THROTTLE + COMPILE_FAILURE))

    def test_compiler_error_in_same_failure_is_not_retried(self):
        self.assertFalse(
            retry.is_dependency_throttle(
                THROTTLE + "error[E0429]: could not compile application\n"
            )
        )

    def test_test_failure_in_same_failure_is_not_retried(self):
        self.assertFalse(
            retry.is_dependency_throttle(
                THROTTLE + "Execution failed for task ':app:testReleaseUnitTest'.\n"
            )
        )

    def test_success_runs_once_and_streams_output(self):
        result, delays, output, count = self.run_build([("Build output\n", 0)])
        self.assertEqual((result, delays, count), (0, [], 1))
        self.assertEqual(output, "Build output\n")

    def test_throttle_then_success_retries_after_30_seconds(self):
        result, delays, output, count = self.run_build(
            [(THROTTLE, 1), ("Build succeeded\n", 0)]
        )
        self.assertEqual((result, delays, count), (0, [30], 2))
        self.assertTrue(output.startswith(THROTTLE))
        self.assertIn("attempt 2/3", output)
        self.assertTrue(output.endswith("Build succeeded\n"))

    def test_three_failures_keep_last_exit_code_and_bound_waits(self):
        result, delays, output, count = self.run_build(
            [(THROTTLE, 1), (THROTTLE, 2), (THROTTLE, 73)]
        )
        self.assertEqual((result, delays, count), (73, [30, 60], 3))
        self.assertIn("attempt 3/3", output)
        self.assertNotIn("attempt 4", output)

    def test_compilation_failure_stops_immediately(self):
        result, delays, _, count = self.run_build([(COMPILE_FAILURE, 19)])
        self.assertEqual((result, delays, count), (19, [], 1))

    def test_does_not_retry_other_failure_after_initial_throttle(self):
        result, delays, _, count = self.run_build(
            [(THROTTLE, 1), (COMPILE_FAILURE, 29)]
        )
        self.assertEqual((result, delays, count), (29, [30], 2))

    def test_non_android_commands_are_rejected(self):
        for command in (
            ["flutter", "test"],
            ["flutter", "build", "linux"],
            ["python3", "scripts/release.py", "build-android"],
        ):
            with self.subTest(command=command):
                with self.assertRaises(ValueError):
                    retry.run_android_build(command)

    def test_appbundle_build_is_supported(self):
        with patch.object(
            retry.subprocess, "Popen", return_value=FakeProcess("AAB built\n", 0)
        ):
            self.assertEqual(
                retry.run_android_build(
                    ["flutter", "build", "appbundle", "--release"],
                    sleep=lambda _: self.fail("Unexpected delay"),
                    stream=io.StringIO(),
                ),
                0,
            )


if __name__ == "__main__":
    unittest.main()
