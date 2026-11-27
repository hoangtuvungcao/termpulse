# TermPulse RFB clipboard compatibility patch

Upstream: vnc-rs 0.6.1, MIT/Apache-2.0 (licenses retained).

Standard RFB ClientCutText and ServerCutText use ISO-8859-1. Encode/decode
Latin-1 explicitly instead of sending UTF-8 or replacing its byte values.
Text outside Latin-1 must use Unicode key events; extended clipboard has not
been negotiated. No authentication or transport security behavior changes.
