# Security policy

## Scope and supported versions

TermPulse is under development. Security work targets the current development branch; there is no published long-term support or backport commitment. A configured CI job or passing fixture does not establish support for every operating system, server, authentication mechanism or network environment. See the platform status in [README.md](README.md) and the dated [Android verification report](docs/ANDROID_VERIFICATION_2026-11-27.md).

## Report a vulnerability privately

Use the repository's [private vulnerability reporting form](https://github.com/hoangtuvungcao/termpulse/security/advisories/new). Do not put suspected vulnerabilities, credentials or exploit details in a public issue, discussion or pull request before coordinating with the maintainer. If the private reporting form is unavailable, wait for a private reporting channel rather than posting sensitive details publicly.

Include the affected version or commit, platform, build mode, relevant feature, expected behavior and a minimal reproduction using disposable hosts and synthetic data. Explain the possible impact and any mitigation you have tested. Share only what is needed to reproduce the issue; redact values rather than pasting production configuration.

Do not attach real Vault databases or exports, upload keystores, private keys, passwords, API tokens, personal hostnames/IP addresses, SSH known-host files, full terminal logs or private remote-desktop captures. Logs and crash reports can contain connection or device metadata. Reproduce against a local fixture wherever possible. Never access a third party's server or data without authorization.

The maintainer will review reports as capacity permits. This policy does not promise a response time, bounty, fix date or coordinated disclosure deadline; agree on disclosure with the maintainer in the private report.

## Security boundaries to keep in mind

- Credential secret fields are encrypted locally; the entire SQLite database is not. Host metadata, snippets, command history, preferences, trust files, logs and exports can remain readable.
- SSH/TLS trust must be verified through a trusted channel. Do not work around certificate or host-key errors by disabling verification.
- Telnet and classic VNC TCP are unencrypted. AI requests go to the user-configured endpoint, which may have its own retention and access policy.
- Terminal output, remote files and AI-generated commands are untrusted input. Review commands before executing them; warning dialogs are not an execution sandbox.

For application data and Android permission disclosures, see the in-app privacy screen and [Google Play release review](docs/GOOGLE_PLAY_RELEASE_REVIEW.md). Publishing source or passing automated checks is not a security certification.
