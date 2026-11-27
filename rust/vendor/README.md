# SSPI dependency compatibility

This directory contains the published `sspi 0.23.1` and `picky 7.0.0-rc.27`
sources from crates.io, with their original MIT and Apache 2.0 licenses.

The upstream manifests pin `rsa =0.10.0-rc.18` and `pkcs1 =0.8.0-rc.4`.
Those exact prerelease constraints cannot coexist in Cargo's resolver with the
stable `rsa 0.10` / `pkcs1 0.8` used by the current `russh 0.65.4` release.
The local manifests change only those four dependency version constraints to
the compatible stable releases. Picky explicitly enables RSA's `pkcs1v15`
feature, which became optional in the stable API. In Picky's RSA key generation adapter, the
stable RSA API's `Odd<BoxedUint>` prime values are cloned into plain `BoxedUint`
values before passing to the existing component constructor. No cryptographic
algorithm or authentication protocol is changed. `sspi`'s `pkcs1` constraint is
specific to macOS and iOS, but Cargo resolves it on other platforms as well.

The root manifest excludes these dependencies from application workspace tests
and selects them through `[patch.crates-io]`. Each vendored manifest declares an
empty workspace boundary. `cargo check -p sspi --lib` from `rust/` checks the
application's selected SSPI features. Running SSPI's upstream unit tests in
isolation requires a temporary manifest without the unused optional `winscard`
dependency: that crate pins an older, incompatible Picky release. This
application uses password-based NTLM and Kerberos, with smart-card support
disabled. Keep application protocol tests and SSPI's NTLM/Kerberos tests passing
when changing these patches. Remove both
patches once an upstream SSPI release supports stable RustCrypto dependencies.
