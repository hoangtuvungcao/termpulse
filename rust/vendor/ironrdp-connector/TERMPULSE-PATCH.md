# TermPulse compatibility patch

Upstream: IronRDP connector 0.10.0, MIT/Apache-2.0 (licenses retained).

This is the Rust 1.89-compatible connector used by IronRDP 0.17. TermPulse's
existing patched SSPI 0.23.1 and picky 7.0.0-rc.27 are retained. The connector
dependency pins and the two SSPI API changes (KdcResolution and checked
TsRequest::buffer_len) are adapted. Smartcard authentication is disabled and
returns an explicit error; TermPulse exposes username/password RDP only.
Unused smartcard certificate helpers and their direct picky dependencies are
removed; SSPI retains its existing picky implementation.
No changes disable TLS certificate or handshake-signature verification.
