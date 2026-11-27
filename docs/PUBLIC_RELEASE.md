# Public source release checklist

This document separates publishing reviewed source from shipping a signed application. It records the intended publication boundary; it does not establish Google Play approval, a project license, or support for every platform.

## Publish reviewed paths explicitly

Initialize and stage from the TermPulse application directory. Do not recursively stage the parent workspace. Use an explicit source allowlist, inspect the resulting index, and review every addition before pushing. `.gitignore` is a convenience, not the publication boundary: it does not remove files already staged or committed.

Expected source categories are:

- Application source in `lib/`, reviewed tests in `test/`, `integration_test/` and `test_driver/`, and required root Flutter/bridge configuration and lockfiles.
- Android, Linux, Windows, macOS and iOS source scaffolds, excluding local SDK configuration, generated build outputs and signing material.
- Rust source, workspace/crate manifests, `Cargo.lock`, local vendor patches, provenance and upstream license/fixture files required by those dependencies.
- The Cargokit build integration in `rust_builder/`, excluding downloaded tools, caches and generated libraries.
- Required branding/fonts and their licenses, reviewed documentation, community templates and CI definitions.
- Reviewed website source under `website/` when included. Review the deploy output separately; deploy only the approved static `website/dist` contents, not the raw workspace or an unreviewed asset directory.

This list identifies categories rather than authorizing an indiscriminate `git add .`. Check filenames and contents, including hidden files, symlinks, archives and binary assets.

## Keep private and generated data out

Exclude build/cache directories such as `build/`, `rust/target/`, `.dart_tool/`, `.gradle/`, IDE metadata, downloaded SDKs and generated platform environment files. In particular, do not publish `android/local.properties`, `.flutter-plugins-dependencies`, `ios/Flutter/Generated.xcconfig`, `ios/Flutter/flutter_export_environment.sh`, ephemeral platform output or Cargokit tool caches.

Never publish real signing keys/properties, passwords, API tokens, private certificates/keys, personal hostnames/IP addresses, Vault databases or sidecars, exported connection data, terminal recordings, device logs, private desktop captures, APK/AAB/IPA installers or old release archives as source. Review all screenshots, including website source images, before allowing them into a public asset bundle. Synthetic screenshots still require a visual privacy review.

Upstream vendored test fixtures may intentionally contain sample key/certificate material. Preserve their license and provenance. Use a narrowly documented scanner exception for an identified upstream fixture; never suppress a whole directory to conceal an unexplained finding. A public certificate is not the same as a private signing key.

## Review the staged result

After staging the approved paths, inspect the index rather than only the working tree:

```sh
git status --short
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
git diff --cached -- .
```

Run a credential scanner over the staged publication set and review every finding. Scan text for personal absolute paths and connection/device data without printing secret values to a shared log. Inspect binaries/images separately; a text-only scan does not inspect pixels or prove the absence of secrets. Do not include existing QA captures merely because their filenames look harmless.

Verify that generated output is ignored and no ignored private file was force-added. If sensitive material has already been committed or pushed, removing the working-tree file is insufficient: stop publication, revoke/rotate the affected secret and review history remediation before continuing.

## State build and platform evidence accurately

The platform matrix in [README.md](../README.md), [dated Android report](ANDROID_VERIFICATION_2026-11-27.md) and [historical QA notes](../QUALITY_REVIEW.md) define the evidence available. Do not describe a configured CI job as a successful run, an unsigned iOS compile as device verification, or a controlled loopback result as a real-network performance guarantee.

Android debug/profile APKs used for QA are development builds signed with a debug key. Android release tasks require the maintainer's untracked upload-key configuration and publisher/privacy definitions; they never fall back to debug signing. Windows installer signing, Apple signing/notarization, App Store distribution and iOS runtime behavior have not been established by this source publication. Native Android VNC, physical USB Serial, Android 16 and runtime 16 KB still need the verification recorded in the Android report.

Keep build outputs separate from source publication. A distributable artifact needs its own version, build provenance, signature, checksum and target-device checks. Do not reuse an old artifact after a source fix and assume it contains that fix.

## Maintainer decisions before publication or distribution

- Choose the legal terms for TermPulse. No project-wide license is currently selected; do not label the project MIT-licensed or assume third-party licenses cover the application. Preserve existing third-party notices.
- Enable private vulnerability reporting and Discussions on the canonical repository, `hoangtuvungcao/termpulse`, and check the links in the community templates. Discussion form filenames must match the configured category slugs (`q-a` and `show-and-tell`).
- Designate a public privacy/support contact and legal publisher identity. Do not fill those fields using a developer's authenticated identity or an unrelated email address.
- Publish and verify the real HTTPS privacy policy, configure the upload key privately, complete the Play Console declarations and test the final signed artifact. See [GOOGLE_PLAY_RELEASE_REVIEW.md](GOOGLE_PLAY_RELEASE_REVIEW.md) for remaining Android release work.

Publishing reviewed source does not complete those store, signing or legal steps.
