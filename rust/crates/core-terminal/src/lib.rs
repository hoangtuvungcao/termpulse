use aho_corasick::AhoCorasick;
use core_model::{EnvTag, HighlightRule};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TerminalPassiveEvent {
    CwdChanged(String),
    TitleChanged(String),
    AgentNotification { title: String, body: String },
    ZmodemDetected,
    TrzszDetected,
}

/// Passive inspector over raw terminal byte streams.
/// Never alters or drops the raw stream forwarded to the terminal emulator.
pub struct TerminalStreamInspector {
    buf: Vec<u8>,
    marker_tail: Vec<u8>,
}

impl Default for TerminalStreamInspector {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalStreamInspector {
    pub fn new() -> Self {
        Self {
            buf: Vec::new(),
            marker_tail: Vec::new(),
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) -> Vec<TerminalPassiveEvent> {
        let mut events = Vec::new();
        let retained = self.marker_tail.len();
        self.marker_tail.extend_from_slice(chunk);
        let contains_new_marker = |marker: &[u8]| {
            self.marker_tail
                .windows(marker.len())
                .enumerate()
                .any(|(start, bytes)| bytes == marker && start + marker.len() > retained)
        };
        if contains_new_marker(b"\x18B00") || contains_new_marker(b"rz\r") {
            events.push(TerminalPassiveEvent::ZmodemDetected);
        }
        if contains_new_marker(b"::TRZSZ") {
            events.push(TerminalPassiveEvent::TrzszDetected);
        }
        // Preserve enough bytes to recognize transfer markers split by PTY/network reads.
        let discard = self.marker_tail.len().saturating_sub(6);
        self.marker_tail.drain(..discard);

        self.buf.extend_from_slice(chunk);
        // Cap pending OSC scan buffer to prevent unbounded growth on binary output
        if self.buf.len() > 16 * 1024 {
            let drain = self.buf.len() - 4096;
            self.buf.drain(..drain);
        }

        loop {
            let Some(start) = find_subslice(&self.buf, b"\x1b]") else {
                // Keep possible trailing ESC byte across chunk boundaries
                let keep_esc = self.buf.last() == Some(&0x1b);
                let len = self.buf.len();
                if len > usize::from(keep_esc) {
                    self.buf.drain(..len - usize::from(keep_esc));
                }
                break;
            };

            let after = &self.buf[start + 2..];
            let end_rel = find_osc_terminator(after);
            let Some((end, term_len)) = end_rel else {
                // Incomplete OSC; wait for next chunk
                if start > 0 {
                    self.buf.drain(..start);
                }
                break;
            };

            let payload = String::from_utf8_lossy(&after[..end]).to_string();
            if let Some(ev) = parse_osc_payload(&payload) {
                events.push(ev);
            }
            self.buf.drain(..start + 2 + end + term_len);
        }

        events
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn find_osc_terminator(buf: &[u8]) -> Option<(usize, usize)> {
    let mut i = 0;
    while i < buf.len() {
        if buf[i] == 0x07 {
            return Some((i, 1));
        }
        if buf[i] == 0x1b && i + 1 < buf.len() && buf[i + 1] == b'\\' {
            return Some((i, 2));
        }
        i += 1;
    }
    None
}

fn parse_osc_payload(payload: &str) -> Option<TerminalPassiveEvent> {
    if let Some(rest) = payload.strip_prefix("7;") {
        // file://hostname/path/to/dir -> /path/to/dir
        if let Some(after_scheme) = rest.strip_prefix("file://") {
            if let Some(idx) = after_scheme.find('/') {
                let raw_path = &after_scheme[idx..];
                return Some(TerminalPassiveEvent::CwdChanged(percent_decode(raw_path)));
            }
        } else if rest.starts_with('/') {
            return Some(TerminalPassiveEvent::CwdChanged(rest.to_string()));
        }
    } else if let Some(rest) = payload.strip_prefix("0;").or_else(|| payload.strip_prefix("2;")) {
        return Some(TerminalPassiveEvent::TitleChanged(rest.to_string()));
    } else if let Some(rest) = payload.strip_prefix("9;") {
        if !rest.starts_with("4;") {
            return Some(TerminalPassiveEvent::AgentNotification {
                title: "TermPulse".into(),
                body: rest.to_string(),
            });
        }
    } else if let Some(rest) = payload.strip_prefix("777;notify;") {
        let mut parts = rest.splitn(2, ';');
        let title = parts.next().unwrap_or("Notification").to_string();
        let body = parts.next().unwrap_or("").to_string();
        return Some(TerminalPassiveEvent::AgentNotification { title, body });
    }
    None
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GuardSeverity {
    Safe,
    Warn,
    Confirm,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuardCheckResult {
    pub severity: GuardSeverity,
    pub matched_rule: Option<String>,
    pub reason: Option<String>,
    pub is_multiline: bool,
    pub line_count: usize,
}

pub struct CommandGuard {
    patterns: Vec<(String, Regex, &'static str)>,
}

impl Default for CommandGuard {
    fn default() -> Self {
        Self::new()
    }
}

impl CommandGuard {
    pub fn new() -> Self {
        let raw = [
            ("rm_rf_root", r"(?i)\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(/|\*|~|\$HOME)\b", "Xoá đệ quy thư mục gốc hoặc toàn bộ dữ liệu"),
            ("mkfs", r"(?i)\bmkfs(\.[a-z0-9]+)?\b", "Định dạng lại phân vùng ổ đĩa"),
            ("dd_dev", r"(?i)\bdd\b.*\bof=/dev/", "Ghi đè trực tiếp thiết bị khối"),
            ("shutdown", r"(?i)\b(shutdown|poweroff|halt|reboot|init\s+[06])\b", "Tắt hoặc khởi động lại máy chủ"),
            ("drop_db", r"(?i)\b(DROP\s+(DATABASE|TABLE|SCHEMA)|TRUNCATE\s+TABLE)\b", "Xoá toàn bộ cơ sở dữ liệu / bảng"),
            ("iptables_flush", r"(?i)\biptables\s+(-[A-Za-z]+\s+)*(-F|--flush)\b", "Xoá toàn bộ quy tắc tường lửa"),
            ("fork_bomb", r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:", "Fork bomb làm treo hệ thống"),
        ];
        let patterns = raw
            .into_iter()
            .filter_map(|(name, pat, reason)| {
                Regex::new(pat).ok().map(|re| (name.to_string(), re, reason))
            })
            .collect();
        Self { patterns }
    }

    pub fn check(&self, input: &str, env_tag: EnvTag) -> GuardCheckResult {
        let lines: Vec<&str> = input.lines().collect();
        let is_multiline = input.contains('\n') || input.contains('\r');
        let line_count = lines.len().max(1);

        for (name, re, reason) in &self.patterns {
            if re.is_match(input) {
                let severity = if env_tag == EnvTag::Prod {
                    GuardSeverity::Confirm
                } else {
                    GuardSeverity::Warn
                };
                return GuardCheckResult {
                    severity,
                    matched_rule: Some(name.clone()),
                    reason: Some((*reason).to_string()),
                    is_multiline,
                    line_count,
                };
            }
        }

        GuardCheckResult {
            severity: GuardSeverity::Safe,
            matched_rule: None,
            reason: None,
            is_multiline,
            line_count,
        }
    }
}

pub fn highlight_spans(line: &str, rules: &[HighlightRule]) -> Vec<(usize, usize, String)> {
    let mut hits = Vec::new();
    for rule in rules {
        if let Ok(ac) = AhoCorasick::builder()
            .ascii_case_insensitive(true)
            .build([&rule.pattern])
        {
            for m in ac.find_iter(line) {
                hits.push((m.start(), m.end(), rule.fg_hex.clone()));
            }
        }
    }
    hits.sort_by_key(|x| x.0);
    hits
}

pub fn suggest_ghost_text(prefix: &str, history: &[(String, i64)]) -> Option<String> {
    let p = prefix.trim_start();
    if p.is_empty() {
        return None;
    }
    history
        .iter()
        .filter(|(cmd, _)| cmd.starts_with(p) && cmd.len() > p.len())
        .max_by_key(|(_, score)| *score)
        .map(|(cmd, _)| cmd[p.len()..].to_string())
}

pub struct AsciicastRecorder {
    start_ns: u128,
    pub header_json: String,
}

impl AsciicastRecorder {
    pub fn new(width: u16, height: u16, title: &str) -> Self {
        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let now_ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let header = serde_json::json!({
            "version": 2,
            "width": width,
            "height": height,
            "timestamp": now_secs,
            "title": title,
        });
        Self {
            start_ns: now_ns,
            header_json: header.to_string(),
        }
    }

    pub fn format_output_event(&self, text: &str) -> String {
        let now_ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let elapsed = (now_ns.saturating_sub(self.start_ns)) as f64 / 1_000_000_000.0;
        serde_json::json!([elapsed, "o", text]).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_osc7_across_split_chunks() {
        let mut insp = TerminalStreamInspector::new();
        let ev1 = insp.feed(b"hello \x1b]7;file://myhost/var");
        assert!(ev1.is_empty());
        let ev2 = insp.feed(b"/log/nginx%20old\x07world");
        assert_eq!(
            ev2,
            vec![TerminalPassiveEvent::CwdChanged("/var/log/nginx old".into())]
        );
    }

    #[test]
    fn detects_osc777_agent_notification() {
        let mut insp = TerminalStreamInspector::new();
        let ev = insp.feed(b"\x1b]777;notify;Claude Code;Finished tests\x1b\\");
        assert_eq!(
            ev,
            vec![TerminalPassiveEvent::AgentNotification {
                title: "Claude Code".into(),
                body: "Finished tests".into(),
            }]
        );
    }

    #[test]
    fn detects_transfer_markers_at_every_chunk_boundary() {
        for (marker, expected) in [
            (&b"\x18B00"[..], TerminalPassiveEvent::ZmodemDetected),
            (&b"rz\r"[..], TerminalPassiveEvent::ZmodemDetected),
            (&b"::TRZSZ"[..], TerminalPassiveEvent::TrzszDetected),
        ] {
            for split in 0..=marker.len() {
                let mut inspector = TerminalStreamInspector::new();
                let mut events = inspector.feed(&marker[..split]);
                events.extend(inspector.feed(&marker[split..]));
                assert_eq!(events, vec![expected.clone()], "split {split}");
                assert!(inspector.feed(b"next output").is_empty());
            }
        }
    }

    #[test]
    fn command_guard_flags_prod_danger_and_multiline() {
        let guard = CommandGuard::new();
        let res = guard.check("echo hi\nrm -rf /var/www/*", EnvTag::Prod);
        assert_eq!(res.severity, GuardSeverity::Confirm);
        assert!(res.is_multiline);
        assert_eq!(res.line_count, 2);

        let dev_res = guard.check("rm -rf /tmp/*", EnvTag::Dev);
        assert_eq!(dev_res.severity, GuardSeverity::Warn);

        let safe = guard.check("ls -la /var/log", EnvTag::Prod);
        assert_eq!(safe.severity, GuardSeverity::Safe);
    }

    #[test]
    fn ghost_text_and_highlights_work() {
        let history = vec![
            ("systemctl status nginx".into(), 10),
            ("systemctl restart nginx".into(), 25),
        ];
        assert_eq!(
            suggest_ghost_text("systemctl ", &history).as_deref(),
            Some("restart nginx")
        );

        let rules = vec![HighlightRule {
            id: "1".into(),
            name: "Errors".into(),
            pattern: "ERROR".into(),
            fg_hex: "#ef4444".into(),
            bg_hex: None,
            bold: true,
        }];
        let spans = highlight_spans("2026 error: disk full", &rules);
        assert_eq!(spans, vec![(5, 10, "#ef4444".into())]);
    }
}
