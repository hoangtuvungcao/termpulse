# Contributing to TermPulse

Start with the platform and feature limits in [README.md](README.md). Ask usage or design questions in [Discussions](https://github.com/hoangtuvungcao/termpulse/discussions); use [Issues](https://github.com/hoangtuvungcao/termpulse/issues/new/choose) for reproducible bugs and specific feature requests. Report vulnerabilities through [SECURITY.md](SECURITY.md).

No project-wide license has been selected for TermPulse. Agree on contribution and reuse terms with the maintainer before submitting code; do not assume a public repository grants a license or that this guide supplies contribution terms. Existing third-party licenses remain in force for their respective files.

## Set up a development build

Use the versions configured in `.github/workflows/platform-checks.yml`: Flutter 3.38.9, the stable Rust toolchain (the actual version is printed in CI logs), and JDK 17 for Android. The Dart SDK constraint is `^3.10.8`. Install the native toolchain for the target platform. Build Windows on Windows and macOS/iOS on macOS; an unsigned iOS compile does not produce a signed, installable App Store release.

On Ubuntu, install `clang`, `cmake`, `ninja-build`, `pkg-config` and `libgtk-3-dev`. Then run from the repository root:

```sh
flutter pub get
flutter run -d linux
```

Use `flutter devices` to find another target. Cargokit in `rust_builder/` builds the Rust library automatically. Keep `rust/vendor/` and its license/provenance files: these paths are required by `rust/Cargo.toml`.

For Android, install SDK 36 and NDK `27.0.12077973`, then:

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
flutter build apk --debug
```

Use a disposable emulator or an explicitly approved test device. Integration runners can replace or uninstall the app; do not run them over a user's only copy of a Vault. Use a separate temporary Vault and synthetic servers. USB Serial and other hardware behavior need real hardware evidence in addition to compilation or mocks.

Release signing is a maintainer operation. Do not commit `android/key.properties`, an upload keystore or its passwords. Release builds require real publisher/privacy details and do not fall back to a debug key; see [the release review](docs/GOOGLE_PLAY_RELEASE_REVIEW.md).

## Make a focused change

Keep each change scoped to one problem, preserve unrelated work, and follow the nearest existing Dart/Rust style. Explain behavior changes and known limits. Add a regression test when it would detect the reported defect; do not weaken a failing assertion just to make a suite pass.

For a Rust API change, regenerate the bridge using the matching version:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

Use `flutter_rust_bridge.yaml`; do not hand-edit `frb_generated*`. Preserve upstream copyright/license notices and document any vendor patch in the relevant vendor directory.

## Validate and describe the result

Run checks appropriate to the changed area. The main local/CI checks are:

```sh
flutter analyze --no-pub
flutter test --no-pub
cargo test --manifest-path rust/Cargo.toml --workspace --locked
cargo check --manifest-path rust/Cargo.toml --workspace --all-targets --locked
flutter build linux --release
```

Run the final build command on the appropriate desktop target. Format changed Dart files with `dart format`; check changed Rust code with `cargo fmt --manifest-path rust/Cargo.toml --all -- --check`. Follow the controlled fixture instructions in [README.md](README.md) for integration checks. A skipped network/hardware test is not evidence that the external feature passed.

In a pull request, state the problem, resulting behavior, tests actually run, and platform/hardware limitations. Give exact commands and distinguish a compile, mock, controlled fixture, physical-device test and external-service smoke test. Do not turn historical results into claims about a new artifact.

Before attaching screenshots, logs or a patch, inspect them for credentials, private hosts, device identifiers and local paths. Do not upload raw Vault data, exports, personal terminal history, private desktop captures or signing material. Use `build/qa_screenshots/` for generated host-side QA captures and keep generated artifacts out of source changes. See [PUBLIC_RELEASE.md](docs/PUBLIC_RELEASE.md) for publication checks.

Participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
