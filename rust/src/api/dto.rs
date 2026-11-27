use core_model::{
    Credential, CredentialKind, EffectiveHostConfig, EnvTag, Group, HighlightRule, Host, Identity,
    IdentityMode, InheritMode, PreConnectConfig, ProtocolKind, ProxyConfig, ProxyKind, Snippet,
    TunnelKind, TunnelRule,
};
use core_terminal::{GuardCheckResult, GuardSeverity};
use core_transport::{AiDraftResponse, HostMetrics, SftpEntry, TunnelStatus};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct KeyValueDto {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone)]
pub struct VaultStatusDto {
    pub initialized: bool,
    pub unlocked: bool,
    pub db_path: String,
}

#[derive(Debug, Clone)]
pub struct GroupDto {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub color_hex: Option<String>,
    pub icon: Option<String>,
    pub default_identity_id: Option<String>,
    pub default_jump_host_id: Option<String>,
    pub default_proxy_id: Option<String>,
    pub default_theme: Option<String>,
    pub env: Vec<KeyValueDto>,
    pub sort_order: i32,
}

#[derive(Debug, Clone)]
pub struct CredentialDto {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub secret: Option<String>,
    pub passphrase: Option<String>,
    pub public_key: Option<String>,
    pub key_fingerprint: Option<String>,
    pub storage_backend: String,
}

#[derive(Debug, Clone)]
pub struct IdentityDto {
    pub id: String,
    pub name: String,
    pub username: String,
    pub credential_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ProxyDto {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub credential_id: Option<String>,
    pub tls: Option<bool>,
    pub tls_server_name: Option<String>,
    pub tls_ca_pem: Option<String>,
    pub auth_method: Option<String>,
    pub auth_domain: Option<String>,
    pub auth_spn: Option<String>,
    pub auth_kdc_url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HostDto {
    pub id: String,
    pub group_id: Option<String>,
    pub label: String,
    pub protocol: String,
    pub hostname: String,
    pub port: u16,
    pub identity_mode: String,
    pub identity_id: Option<String>,
    pub identity_name_ref: Option<String>,
    pub jump_host_mode: String,
    pub jump_host_id: Option<String>,
    pub proxy_mode: String,
    pub proxy_id: Option<String>,
    pub color_hex: Option<String>,
    pub icon: Option<String>,
    pub env_tag: String,
    pub tags: Vec<String>,
    pub notes: String,
    pub startup_dir: Option<String>,
    pub startup_cmd: Option<String>,
    pub env: Vec<KeyValueDto>,
    pub follow_terminal_sftp: Option<bool>,
    pub wol_mac: Option<String>,
    pub wol_broadcast: Option<String>,
    pub serial_baudrate: Option<u32>,
    pub serial_data_bits: Option<u8>,
    pub serial_parity: Option<String>,
    pub serial_stop_bits: Option<u8>,
    pub serial_flow_control: Option<String>,
    pub remote_desktop_json: Option<String>,
    pub is_favorite: bool,
    pub last_connected_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct EffectiveHostDto {
    pub host: HostDto,
    pub username: Option<String>,
    pub credential_kind: Option<String>,
    pub jump_host_label: Option<String>,
    pub proxy_label: Option<String>,
    pub follow_terminal_sftp: bool,
    pub override_flags: u32,
}

#[derive(Debug, Clone)]
pub struct TunnelDto {
    pub id: String,
    pub name: String,
    pub host_id: String,
    pub kind: String,
    pub bind_addr: String,
    pub bind_port: u16,
    pub target_host: Option<String>,
    pub target_port: Option<u16>,
    pub auto_start: bool,
}

#[derive(Debug, Clone)]
pub struct TunnelStatusDto {
    pub tunnel_id: String,
    pub running: bool,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub active_conns: u64,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SnippetDto {
    pub id: String,
    pub scope: String,
    pub scope_id: Option<String>,
    pub title: String,
    pub command_tpl: String,
    pub pin_button_bar: bool,
}

#[derive(Debug, Clone)]
pub struct HighlightDto {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub fg_hex: String,
    pub bg_hex: Option<String>,
    pub bold: bool,
}

#[derive(Debug, Clone)]
pub struct ActiveSessionInfoDto {
    pub session_id: String,
    pub host_id: Option<String>,
    pub title: String,
    pub env_tag: String,
    pub cwd: String,
    pub has_sftp: bool,
    pub sftp_unavailable_reason: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TerminalEventDto {
    /// "session_opened" | "output_bytes" | "cwd_changed" | "title_changed"
    /// | "agent_notification" | "zmodem" | "trzsz" | "sftp_unavailable" | "closed"
    pub kind: String,
    pub text: Option<String>,
    pub title: Option<String>,
    pub bytes: Option<Vec<u8>>,
}

impl TerminalEventDto {
    pub(crate) fn session_opened(id: String) -> Self {
        Self { kind: "session_opened".into(), text: Some(id), title: None, bytes: None }
    }
    pub(crate) fn output_bytes(data: Vec<u8>) -> Self {
        Self { kind: "output_bytes".into(), text: None, title: None, bytes: Some(data) }
    }
    pub(crate) fn cwd_changed(cwd: String) -> Self {
        Self { kind: "cwd_changed".into(), text: Some(cwd), title: None, bytes: None }
    }
    pub(crate) fn title_changed(title: String) -> Self {
        Self { kind: "title_changed".into(), text: Some(title), title: None, bytes: None }
    }
    pub(crate) fn agent_notification(title: String, body: String) -> Self {
        Self { kind: "agent_notification".into(), text: Some(body), title: Some(title), bytes: None }
    }
    pub(crate) fn zmodem_detected() -> Self {
        Self { kind: "zmodem".into(), text: None, title: None, bytes: None }
    }
    pub(crate) fn trzsz_detected() -> Self {
        Self { kind: "trzsz".into(), text: None, title: None, bytes: None }
    }
    pub(crate) fn sftp_unavailable(reason: String) -> Self {
        Self { kind: "sftp_unavailable".into(), text: Some(reason), title: None, bytes: None }
    }
    pub(crate) fn closed(reason: Option<String>) -> Self {
        Self { kind: "closed".into(), text: reason, title: None, bytes: None }
    }
}

#[derive(Debug, Clone)]
pub struct SftpEntryDto {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub permissions: u32,
    pub modified: u64,
}

#[derive(Debug, Clone)]
pub struct SftpListingDto {
    pub cwd: String,
    pub entries: Vec<SftpEntryDto>,
}

#[derive(Debug, Clone)]
pub struct TransferProgressDto {
    pub transfer_id: String,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub finished: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HostMetricsDto {
    pub cpu_percent: f32,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub disk_used_gb: f32,
    pub disk_total_gb: f32,
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
    pub load_avg: String,
    pub uptime_secs: u64,
}

#[derive(Debug, Clone)]
pub struct GuardResultDto {
    pub severity: String,
    pub matched_rule: Option<String>,
    pub reason: Option<String>,
    pub is_multiline: bool,
    pub line_count: usize,
}

#[derive(Debug, Clone)]
pub struct AiDraftDto {
    pub command: String,
    pub explanation: String,
    pub sent_context_preview: String,
}

#[derive(Debug, Clone)]
pub struct ImportResultDto {
    pub hosts_imported: usize,
    pub identities_imported: usize,
    pub warnings: Vec<String>,
}

// --- Conversions ---
pub(crate) fn parse_env_tag(s: &str) -> EnvTag {
    match s.to_ascii_lowercase().as_str() {
        "prod" | "production" => EnvTag::Prod,
        "staging" => EnvTag::Staging,
        "homelab" => EnvTag::Homelab,
        _ => EnvTag::Dev,
    }
}

pub(crate) fn env_tag_str(e: EnvTag) -> String {
    match e {
        EnvTag::Prod => "prod".into(),
        EnvTag::Staging => "staging".into(),
        EnvTag::Dev => "dev".into(),
        EnvTag::Homelab => "homelab".into(),
    }
}

pub(crate) fn parse_protocol(s: &str) -> ProtocolKind {
    match s.to_ascii_lowercase().as_str() {
        "mosh" => ProtocolKind::Mosh,
        "et" | "eternal_terminal" => ProtocolKind::EternalTerminal,
        "local" | "local_shell" => ProtocolKind::LocalShell,
        "telnet" => ProtocolKind::Telnet,
        "serial" => ProtocolKind::Serial,
        "sftp" => ProtocolKind::Sftp,
        "rdp" => ProtocolKind::Rdp,
        "vnc" => ProtocolKind::Vnc,
        _ => ProtocolKind::Ssh,
    }
}

pub(crate) fn protocol_str(p: ProtocolKind) -> String {
    match p {
        ProtocolKind::Ssh => "ssh".into(),
        ProtocolKind::Mosh => "mosh".into(),
        ProtocolKind::EternalTerminal => "et".into(),
        ProtocolKind::LocalShell => "local_shell".into(),
        ProtocolKind::Telnet => "telnet".into(),
        ProtocolKind::Serial => "serial".into(),
        ProtocolKind::Sftp => "sftp".into(),
        ProtocolKind::Rdp => "rdp".into(),
        ProtocolKind::Vnc => "vnc".into(),
    }
}

impl From<Group> for GroupDto {
    fn from(g: Group) -> Self {
        Self {
            id: g.id,
            parent_id: g.parent_id,
            name: g.name,
            color_hex: g.color_hex,
            icon: g.icon,
            default_identity_id: g.default_identity_id,
            default_jump_host_id: g.default_jump_host_id,
            default_proxy_id: g.default_proxy_id,
            default_theme: g.default_theme,
            env: g
                .env
                .into_iter()
                .map(|(key, value)| KeyValueDto { key, value })
                .collect(),
            sort_order: g.sort_order,
        }
    }
}

impl From<GroupDto> for Group {
    fn from(d: GroupDto) -> Self {
        let mut env = BTreeMap::new();
        for kv in d.env {
            env.insert(kv.key, kv.value);
        }
        Self {
            id: d.id,
            parent_id: d.parent_id,
            name: d.name,
            color_hex: d.color_hex,
            icon: d.icon,
            default_identity_id: d.default_identity_id,
            default_jump_host_id: d.default_jump_host_id,
            default_proxy_id: d.default_proxy_id,
            default_theme: d.default_theme,
            env,
            sort_order: d.sort_order,
        }
    }
}

impl From<Credential> for CredentialDto {
    fn from(c: Credential) -> Self {
        let kind = match c.kind {
            CredentialKind::Password => "password",
            CredentialKind::SshKey => "ssh_key",
            CredentialKind::Agent => "agent",
            CredentialKind::Fido2 => "fido2",
            CredentialKind::Certificate => "certificate",
            CredentialKind::Kerberos => "kerberos",
        }
        .to_string();
        Self {
            id: c.id,
            name: c.name,
            kind,
            secret: c.secret,
            passphrase: c.passphrase,
            public_key: c.public_key,
            key_fingerprint: c.key_fingerprint,
            storage_backend: c.storage_backend,
        }
    }
}

impl From<CredentialDto> for Credential {
    fn from(d: CredentialDto) -> Self {
        let kind = match d.kind.as_str() {
            "ssh_key" => CredentialKind::SshKey,
            "agent" => CredentialKind::Agent,
            "fido2" => CredentialKind::Fido2,
            "certificate" => CredentialKind::Certificate,
            "kerberos" => CredentialKind::Kerberos,
            _ => CredentialKind::Password,
        };
        Self {
            id: d.id,
            name: d.name,
            kind,
            secret: d.secret,
            passphrase: d.passphrase,
            public_key: d.public_key,
            key_fingerprint: d.key_fingerprint,
            storage_backend: d.storage_backend,
        }
    }
}

impl From<Identity> for IdentityDto {
    fn from(i: Identity) -> Self {
        Self {
            id: i.id,
            name: i.name,
            username: i.username,
            credential_id: i.credential_id,
        }
    }
}

impl From<IdentityDto> for Identity {
    fn from(d: IdentityDto) -> Self {
        Self {
            id: d.id,
            name: d.name,
            username: d.username,
            credential_id: d.credential_id,
        }
    }
}

impl From<ProxyConfig> for ProxyDto {
    fn from(p: ProxyConfig) -> Self {
        Self {
            id: p.id,
            name: p.name,
            kind: match p.kind {
                ProxyKind::Socks4 => "socks4",
                ProxyKind::Socks5 => "socks5",
                ProxyKind::HttpConnect => "http_connect",
            }
            .to_string(),
            host: p.host,
            port: p.port,
            username: p.username,
            credential_id: p.credential_id,
            tls: p.tls,
            tls_server_name: p.tls_server_name,
            tls_ca_pem: p.tls_ca_pem,
            auth_method: p.auth_method,
            auth_domain: p.auth_domain,
            auth_spn: p.auth_spn,
            auth_kdc_url: p.auth_kdc_url,
        }
    }
}

impl From<ProxyDto> for ProxyConfig {
    fn from(d: ProxyDto) -> Self {
        Self {
            id: d.id,
            name: d.name,
            kind: match d.kind.as_str() {
                "socks4" => ProxyKind::Socks4,
                "http_connect" => ProxyKind::HttpConnect,
                _ => ProxyKind::Socks5,
            },
            host: d.host,
            port: d.port,
            username: d.username,
            credential_id: d.credential_id,
            tls: d.tls,
            tls_server_name: d.tls_server_name,
            tls_ca_pem: d.tls_ca_pem,
            auth_method: d.auth_method,
            auth_domain: d.auth_domain,
            auth_spn: d.auth_spn,
            auth_kdc_url: d.auth_kdc_url,
        }
    }
}

impl From<Host> for HostDto {
    fn from(h: Host) -> Self {
        let id_mode = match h.identity_mode {
            IdentityMode::ById => "by_id",
            IdentityMode::ByName => "by_name",
            IdentityMode::Inherit => "inherit",
        }
        .to_string();
        let inherit_s = |m: InheritMode| match m {
            InheritMode::Inherit => "inherit",
            InheritMode::Direct => "direct",
            InheritMode::None => "none",
        }
        .to_string();
        Self {
            id: h.id,
            group_id: h.group_id,
            label: h.label,
            protocol: protocol_str(h.protocol),
            hostname: h.hostname,
            port: h.port,
            identity_mode: id_mode,
            identity_id: h.identity_id,
            identity_name_ref: h.identity_name_ref,
            jump_host_mode: inherit_s(h.jump_host_mode),
            jump_host_id: h.jump_host_id,
            proxy_mode: inherit_s(h.proxy_mode),
            proxy_id: h.proxy_id,
            color_hex: h.color_hex,
            icon: h.icon,
            env_tag: env_tag_str(h.env_tag),
            tags: h.tags,
            notes: h.notes,
            startup_dir: h.startup_dir,
            startup_cmd: h.startup_cmd,
            env: h
                .env
                .into_iter()
                .map(|(key, value)| KeyValueDto { key, value })
                .collect(),
            follow_terminal_sftp: h.follow_terminal_sftp,
            wol_mac: h.preconnect.wol_mac,
            wol_broadcast: h.preconnect.wol_broadcast,
            serial_baudrate: h.serial_baudrate,
            serial_data_bits: h.serial_data_bits,
            serial_parity: h.serial_parity,
            serial_stop_bits: h.serial_stop_bits,
            serial_flow_control: h.serial_flow_control,
            remote_desktop_json: h.remote_desktop_json,
            is_favorite: h.is_favorite,
            last_connected_at: h.last_connected_at,
        }
    }
}

impl From<HostDto> for Host {
    fn from(d: HostDto) -> Self {
        let parse_inherit = |s: &str| match s {
            "direct" => InheritMode::Direct,
            "none" => InheritMode::None,
            _ => InheritMode::Inherit,
        };
        let mut env = BTreeMap::new();
        for kv in d.env {
            env.insert(kv.key, kv.value);
        }
        Self {
            id: d.id,
            group_id: d.group_id,
            label: d.label,
            protocol: parse_protocol(&d.protocol),
            hostname: d.hostname,
            port: d.port,
            identity_mode: match d.identity_mode.as_str() {
                "by_id" => IdentityMode::ById,
                "by_name" => IdentityMode::ByName,
                _ => IdentityMode::Inherit,
            },
            identity_id: d.identity_id,
            identity_name_ref: d.identity_name_ref,
            jump_host_mode: parse_inherit(&d.jump_host_mode),
            jump_host_id: d.jump_host_id,
            proxy_mode: parse_inherit(&d.proxy_mode),
            proxy_id: d.proxy_id,
            color_hex: d.color_hex,
            icon: d.icon,
            env_tag: parse_env_tag(&d.env_tag),
            tags: d.tags,
            notes: d.notes,
            startup_dir: d.startup_dir,
            startup_cmd: d.startup_cmd,
            env,
            follow_terminal_sftp: d.follow_terminal_sftp,
            preconnect: PreConnectConfig {
                wol_mac: d.wol_mac,
                wol_broadcast: d.wol_broadcast,
                ..Default::default()
            },
            serial_baudrate: d.serial_baudrate,
            serial_data_bits: d.serial_data_bits,
            serial_parity: d.serial_parity,
            serial_stop_bits: d.serial_stop_bits,
            serial_flow_control: d.serial_flow_control,
            remote_desktop_json: d.remote_desktop_json,
            is_favorite: d.is_favorite,
            last_connected_at: d.last_connected_at,
        }
    }
}

impl From<EffectiveHostConfig> for EffectiveHostDto {
    fn from(e: EffectiveHostConfig) -> Self {
        let cred_kind = e.credential.map(|c| CredentialDto::from(c).kind);
        Self {
            host: e.host.into(),
            username: e.identity.map(|i| i.username),
            credential_kind: cred_kind,
            jump_host_label: e.jump_host.map(|j| j.label),
            proxy_label: e.proxy.map(|p| p.name),
            follow_terminal_sftp: e.follow_terminal_sftp,
            override_flags: e.overrides.bits(),
        }
    }
}

impl From<TunnelRule> for TunnelDto {
    fn from(t: TunnelRule) -> Self {
        Self {
            id: t.id,
            name: t.name,
            host_id: t.host_id,
            kind: match t.kind {
                TunnelKind::Local => "local",
                TunnelKind::Remote => "remote",
                TunnelKind::DynamicSocks => "dynamic_socks",
            }
            .to_string(),
            bind_addr: t.bind_addr,
            bind_port: t.bind_port,
            target_host: t.target_host,
            target_port: t.target_port,
            auto_start: t.auto_start,
        }
    }
}

impl From<TunnelDto> for TunnelRule {
    fn from(d: TunnelDto) -> Self {
        Self {
            id: d.id,
            name: d.name,
            host_id: d.host_id,
            kind: match d.kind.as_str() {
                "remote" => TunnelKind::Remote,
                "dynamic_socks" => TunnelKind::DynamicSocks,
                _ => TunnelKind::Local,
            },
            bind_addr: d.bind_addr,
            bind_port: d.bind_port,
            target_host: d.target_host,
            target_port: d.target_port,
            auto_start: d.auto_start,
        }
    }
}

impl From<TunnelStatus> for TunnelStatusDto {
    fn from(s: TunnelStatus) -> Self {
        Self {
            tunnel_id: s.tunnel_id,
            running: s.running,
            bytes_in: s.bytes_in,
            bytes_out: s.bytes_out,
            active_conns: s.active_conns,
            last_error: s.last_error,
        }
    }
}

impl From<Snippet> for SnippetDto {
    fn from(s: Snippet) -> Self {
        Self {
            id: s.id,
            scope: s.scope,
            scope_id: s.scope_id,
            title: s.title,
            command_tpl: s.command_tpl,
            pin_button_bar: s.pin_button_bar,
        }
    }
}

impl From<SnippetDto> for Snippet {
    fn from(d: SnippetDto) -> Self {
        Self {
            id: d.id,
            scope: d.scope,
            scope_id: d.scope_id,
            title: d.title,
            command_tpl: d.command_tpl,
            pin_button_bar: d.pin_button_bar,
        }
    }
}

impl From<HighlightRule> for HighlightDto {
    fn from(h: HighlightRule) -> Self {
        Self {
            id: h.id,
            name: h.name,
            pattern: h.pattern,
            fg_hex: h.fg_hex,
            bg_hex: h.bg_hex,
            bold: h.bold,
        }
    }
}

impl From<HighlightDto> for HighlightRule {
    fn from(d: HighlightDto) -> Self {
        Self {
            id: d.id,
            name: d.name,
            pattern: d.pattern,
            fg_hex: d.fg_hex,
            bg_hex: d.bg_hex,
            bold: d.bold,
        }
    }
}

impl From<SftpEntry> for SftpEntryDto {
    fn from(e: SftpEntry) -> Self {
        Self {
            name: e.name,
            path: e.path,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            size: e.size,
            permissions: e.permissions,
            modified: e.modified,
        }
    }
}

impl From<HostMetrics> for HostMetricsDto {
    fn from(m: HostMetrics) -> Self {
        Self {
            cpu_percent: m.cpu_percent,
            mem_used_mb: m.mem_used_mb,
            mem_total_mb: m.mem_total_mb,
            disk_used_gb: m.disk_used_gb,
            disk_total_gb: m.disk_total_gb,
            net_rx_bytes: m.net_rx_bytes,
            net_tx_bytes: m.net_tx_bytes,
            load_avg: m.load_avg,
            uptime_secs: m.uptime_secs,
        }
    }
}

impl From<GuardCheckResult> for GuardResultDto {
    fn from(r: GuardCheckResult) -> Self {
        Self {
            severity: match r.severity {
                GuardSeverity::Safe => "safe",
                GuardSeverity::Warn => "warn",
                GuardSeverity::Confirm => "confirm",
            }
            .to_string(),
            matched_rule: r.matched_rule,
            reason: r.reason,
            is_multiline: r.is_multiline,
            line_count: r.line_count,
        }
    }
}

impl From<AiDraftResponse> for AiDraftDto {
    fn from(a: AiDraftResponse) -> Self {
        Self {
            command: a.command,
            explanation: a.explanation,
            sent_context_preview: a.sent_context_preview,
        }
    }
}
