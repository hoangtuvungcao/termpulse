use bitflags::bitflags;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

bitflags! {
    /// Marks which host settings were explicitly overridden rather than inherited from a parent Group.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
    pub struct OverrideFlags: u32 {
        const IDENTITY = 1 << 0;
        const JUMP_HOST = 1 << 1;
        const PROXY = 1 << 2;
        const FOLLOW_SFTP = 1 << 3;
        const ENV = 1 << 4;
        const THEME = 1 << 5;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProtocolKind {
    #[default]
    Ssh,
    Mosh,
    EternalTerminal,
    LocalShell,
    Telnet,
    Serial,
    Sftp,
    Rdp,
    Vnc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum EnvTag {
    Prod,
    Staging,
    #[default]
    Dev,
    Homelab,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum CredentialKind {
    #[default]
    Password,
    SshKey,
    Agent,
    Fido2,
    Certificate,
    Kerberos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum IdentityMode {
    ById,
    ByName,
    #[default]
    Inherit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum InheritMode {
    #[default]
    Inherit,
    Direct,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProxyKind {
    Socks4,
    #[default]
    Socks5,
    HttpConnect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TunnelKind {
    #[default]
    Local,
    Remote,
    DynamicSocks,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Group {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub color_hex: Option<String>,
    pub icon: Option<String>,
    pub default_identity_id: Option<String>,
    pub default_jump_host_id: Option<String>,
    pub default_proxy_id: Option<String>,
    pub default_theme: Option<String>,
    pub env: BTreeMap<String, String>,
    pub sort_order: i32,
}

impl Default for Group {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            parent_id: None,
            name: String::new(),
            color_hex: None,
            icon: None,
            default_identity_id: None,
            default_jump_host_id: None,
            default_proxy_id: None,
            default_theme: None,
            env: BTreeMap::new(),
            sort_order: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Credential {
    pub id: String,
    pub name: String,
    pub kind: CredentialKind,
    /// Plaintext secret in-memory only when unlocked; stored encrypted at rest in Vault.
    pub secret: Option<String>,
    pub passphrase: Option<String>,
    pub public_key: Option<String>,
    pub key_fingerprint: Option<String>,
    pub storage_backend: String,
}

impl Default for Credential {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: String::new(),
            kind: CredentialKind::Password,
            secret: None,
            passphrase: None,
            public_key: None,
            key_fingerprint: None,
            storage_backend: "vault".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identity {
    pub id: String,
    pub name: String,
    pub username: String,
    pub credential_id: Option<String>,
}

impl Default for Identity {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: String::new(),
            username: "root".to_string(),
            credential_id: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct ProxyConfig {
    pub id: String,
    pub name: String,
    pub kind: ProxyKind,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub username: Option<String>,
    pub credential_id: Option<String>,
    #[serde(default)]
    pub tls: Option<bool>,
    #[serde(default)]
    pub tls_server_name: Option<String>,
    #[serde(default)]
    pub tls_ca_pem: Option<String>,
    #[serde(default)]
    pub auth_method: Option<String>,
    #[serde(default)]
    pub auth_domain: Option<String>,
    #[serde(default)]
    pub auth_spn: Option<String>,
    #[serde(default)]
    pub auth_kdc_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct PreConnectConfig {
    pub wol_mac: Option<String>,
    pub wol_broadcast: Option<String>,
    pub wol_delay_ms: u64,
    pub knock_ports: Vec<u16>,
    pub knock_delay_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Host {
    pub id: String,
    pub group_id: Option<String>,
    pub label: String,
    pub protocol: ProtocolKind,
    pub hostname: String,
    pub port: u16,
    pub identity_mode: IdentityMode,
    pub identity_id: Option<String>,
    pub identity_name_ref: Option<String>,
    pub jump_host_mode: InheritMode,
    pub jump_host_id: Option<String>,
    pub proxy_mode: InheritMode,
    pub proxy_id: Option<String>,
    pub color_hex: Option<String>,
    pub icon: Option<String>,
    pub env_tag: EnvTag,
    pub tags: Vec<String>,
    pub notes: String,
    pub startup_dir: Option<String>,
    pub startup_cmd: Option<String>,
    pub env: BTreeMap<String, String>,
    /// None = inherit global default (true), Some(false) = disabled for this host.
    pub follow_terminal_sftp: Option<bool>,
    pub preconnect: PreConnectConfig,
    pub serial_baudrate: Option<u32>,
    #[serde(default)]
    pub serial_data_bits: Option<u8>,
    #[serde(default)]
    pub serial_parity: Option<String>,
    #[serde(default)]
    pub serial_stop_bits: Option<u8>,
    #[serde(default)]
    pub serial_flow_control: Option<String>,
    /// Non-secret remote desktop options (dimensions, domain and certificate trust).
    #[serde(default)]
    pub remote_desktop_json: Option<String>,
    pub is_favorite: bool,
    pub last_connected_at: Option<i64>,
}

impl Default for Host {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            group_id: None,
            label: String::new(),
            protocol: ProtocolKind::Ssh,
            hostname: String::new(),
            port: 22,
            identity_mode: IdentityMode::Inherit,
            identity_id: None,
            identity_name_ref: None,
            jump_host_mode: InheritMode::Inherit,
            jump_host_id: None,
            proxy_mode: InheritMode::Inherit,
            proxy_id: None,
            color_hex: None,
            icon: None,
            env_tag: EnvTag::Dev,
            tags: Vec::new(),
            notes: String::new(),
            startup_dir: None,
            startup_cmd: None,
            env: BTreeMap::new(),
            follow_terminal_sftp: None,
            preconnect: PreConnectConfig::default(),
            serial_baudrate: None,
            serial_data_bits: None,
            serial_parity: None,
            serial_stop_bits: None,
            serial_flow_control: None,
            remote_desktop_json: None,
            is_favorite: false,
            last_connected_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TunnelRule {
    pub id: String,
    pub name: String,
    pub host_id: String,
    pub kind: TunnelKind,
    pub bind_addr: String,
    pub bind_port: u16,
    pub target_host: Option<String>,
    pub target_port: Option<u16>,
    pub auto_start: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Snippet {
    pub id: String,
    pub scope: String, // "global" | "group" | "host"
    pub scope_id: Option<String>,
    pub title: String,
    pub command_tpl: String,
    pub pin_button_bar: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HighlightRule {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub fg_hex: String,
    pub bg_hex: Option<String>,
    pub bold: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EffectiveHostConfig {
    pub host: Host,
    pub identity: Option<Identity>,
    pub credential: Option<Credential>,
    pub jump_host: Option<Host>,
    pub proxy: Option<ProxyConfig>,
    #[serde(default)]
    pub proxy_credential: Option<Credential>,
    pub theme: Option<String>,
    pub env: BTreeMap<String, String>,
    pub follow_terminal_sftp: bool,
    pub overrides: OverrideFlags,
}

/// Resolves a Host's effective configuration by walking parent Groups with cycle protection.
/// Legacy or externally modified vaults must not silently bypass a selected proxy.
pub fn validate_proxy_reference(host: &Host, groups: &[Group], proxies: &[ProxyConfig]) -> Result<(), String> {
    if host.proxy_mode == InheritMode::None { return Ok(()); }
    let mut selected = None;
    if host.proxy_mode == InheritMode::Inherit {
        let mut current = host.group_id.as_deref();
        let mut visited = HashSet::new();
        while let Some(id) = current {
            if !visited.insert(id) { break; }
            let Some(group) = groups.iter().find(|group| group.id == id) else { break; };
            if let Some(id) = group.default_proxy_id.as_deref() { selected = Some(id); break; }
            current = group.parent_id.as_deref();
        }
    }
    let selected = selected.or(host.proxy_id.as_deref());
    if let Some(id) = selected {
        if !proxies.iter().any(|proxy| proxy.id == id) {
            return Err(format!("Host {} tham chiếu Proxy không tồn tại ({id}); hãy chọn lại Proxy hoặc tắt rõ ràng. Kết nối trực tiếp đã bị chặn.", host.label));
        }
    }
    Ok(())
}

pub fn resolve_effective_host_config(
    host: &Host,
    groups: &[Group],
    identities: &[Identity],
    credentials: &[Credential],
    hosts: &[Host],
    proxies: &[ProxyConfig],
    global_follow_sftp: bool,
) -> EffectiveHostConfig {
    let mut chain: Vec<&Group> = Vec::new();
    let mut visited = HashSet::new();
    let mut current_gid = host.group_id.as_deref();

    while let Some(gid) = current_gid {
        if !visited.insert(gid) {
            break;
        }
        if let Some(g) = groups.iter().find(|g| g.id == gid) {
            chain.push(g);
            current_gid = g.parent_id.as_deref();
        } else {
            break;
        }
    }

    let mut overrides = OverrideFlags::empty();

    // 1. Resolve Identity (ById | ByName | Inherit)
    let identity_id_opt = match host.identity_mode {
        IdentityMode::ById => {
            if host.identity_id.is_some() {
                overrides.insert(OverrideFlags::IDENTITY);
            }
            host.identity_id.clone()
        }
        IdentityMode::ByName => {
            overrides.insert(OverrideFlags::IDENTITY);
            host.identity_name_ref.as_ref().and_then(|name| {
                identities
                    .iter()
                    .find(|i| i.name.eq_ignore_ascii_case(name))
                    .map(|i| i.id.clone())
            })
        }
        IdentityMode::Inherit => chain
            .iter()
            .find_map(|g| g.default_identity_id.clone())
            .or_else(|| host.identity_id.clone()),
    };

    let identity = identity_id_opt
        .as_deref()
        .and_then(|id| identities.iter().find(|i| i.id == id))
        .cloned();

    let credential = identity
        .as_ref()
        .and_then(|i| i.credential_id.as_deref())
        .and_then(|cid| credentials.iter().find(|c| c.id == cid))
        .cloned();

    // 2. Resolve Jump Host
    let jump_host_id = match host.jump_host_mode {
        InheritMode::None => {
            if chain.iter().any(|g| g.default_jump_host_id.is_some()) {
                overrides.insert(OverrideFlags::JUMP_HOST);
            }
            None
        }
        InheritMode::Direct => {
            if host.jump_host_id.is_some() {
                overrides.insert(OverrideFlags::JUMP_HOST);
            }
            host.jump_host_id.clone()
        }
        InheritMode::Inherit => chain
            .iter()
            .find_map(|g| g.default_jump_host_id.clone())
            .or_else(|| host.jump_host_id.clone()),
    };

    let jump_host = jump_host_id
        .as_deref()
        .filter(|jid| *jid != host.id)
        .and_then(|jid| hosts.iter().find(|h| h.id == jid))
        .cloned();

    // 3. Resolve Proxy
    let proxy_id = match host.proxy_mode {
        InheritMode::None => {
            if chain.iter().any(|g| g.default_proxy_id.is_some()) {
                overrides.insert(OverrideFlags::PROXY);
            }
            None
        }
        InheritMode::Direct => {
            if host.proxy_id.is_some() {
                overrides.insert(OverrideFlags::PROXY);
            }
            host.proxy_id.clone()
        }
        InheritMode::Inherit => chain
            .iter()
            .find_map(|g| g.default_proxy_id.clone())
            .or_else(|| host.proxy_id.clone()),
    };

    let proxy = proxy_id
        .as_deref()
        .and_then(|pid| proxies.iter().find(|p| p.id == pid))
        .cloned();
    let proxy_credential = proxy.as_ref()
        .and_then(|proxy| proxy.credential_id.as_deref())
        .and_then(|credential_id| credentials.iter().find(|credential| credential.id == credential_id))
        .cloned();

    // 4. Merge Env (root -> leaf -> host)
    let mut env = BTreeMap::new();
    for g in chain.iter().rev() {
        for (k, v) in &g.env {
            env.insert(k.clone(), v.clone());
        }
    }
    if !host.env.is_empty() {
        overrides.insert(OverrideFlags::ENV);
        for (k, v) in &host.env {
            env.insert(k.clone(), v.clone());
        }
    }

    // 5. Theme & Follow-Terminal SFTP
    let theme = chain.iter().find_map(|g| g.default_theme.clone());
    let follow_terminal_sftp = match host.follow_terminal_sftp {
        Some(v) => {
            if v != global_follow_sftp {
                overrides.insert(OverrideFlags::FOLLOW_SFTP);
            }
            v
        }
        None => global_follow_sftp,
    };

    EffectiveHostConfig {
        host: host.clone(),
        identity,
        credential,
        jump_host,
        proxy,
        proxy_credential,
        theme,
        env,
        follow_terminal_sftp,
        overrides,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_selected_proxy_cannot_silently_resolve_to_a_direct_connection() {
        let group = Group {id:"team".into(), default_proxy_id:Some("missing".into()), ..Default::default()};
        let mut host = Host {group_id:Some(group.id.clone()), ..Default::default()};
        assert!(validate_proxy_reference(&host, &[group.clone()], &[]).is_err());
        host.proxy_mode = InheritMode::None;
        assert!(validate_proxy_reference(&host, &[group.clone()], &[]).is_ok());
        host.proxy_mode = InheritMode::Direct;
        host.proxy_id = Some("missing".into());
        assert!(validate_proxy_reference(&host, &[], &[]).is_err());
        let proxy = ProxyConfig {id:"missing".into(), ..Default::default()};
        assert!(validate_proxy_reference(&host, &[group], &[proxy]).is_ok());
    }

    #[test]
    fn resolves_multilevel_inheritance_and_overrides() {
        let cred_root = Credential {
            id: "c_root".into(),
            name: "Root Key".into(),
            kind: CredentialKind::SshKey,
            secret: Some("PRIVATE".into()),
            ..Default::default()
        };
        let cred_team = Credential {
            id: "c_team".into(),
            name: "Personal Ops".into(),
            kind: CredentialKind::Password,
            secret: Some("s3cr3t".into()),
            ..Default::default()
        };
        let id_root = Identity {
            id: "id_root".into(),
            name: "OpsRoot".into(),
            username: "ubuntu".into(),
            credential_id: Some("c_root".into()),
        };
        let id_personal = Identity {
            id: "id_personal".into(),
            name: "MyPersonalOps".into(),
            username: "vantrong".into(),
            credential_id: Some("c_team".into()),
        };
        let bastion = Host {
            id: "h_bastion".into(),
            label: "Bastion".into(),
            hostname: "jump.example.com".into(),
            ..Default::default()
        };
        let proxy = ProxyConfig {
            id: "p_corp".into(),
            name: "Corp SOCKS5".into(),
            kind: ProxyKind::Socks5,
            host: "127.0.0.1".into(),
            port: 1080,
            username: Some("corp-user".into()),
            credential_id: Some("c_team".into()),
            ..Default::default()
        };

        let mut root_env = BTreeMap::new();
        root_env.insert("LC_ALL".into(), "C.UTF-8".into());
        root_env.insert("STAGE".into(), "root".into());

        let g_root = Group {
            id: "g_root".into(),
            name: "Cloud".into(),
            default_identity_id: Some("id_root".into()),
            default_jump_host_id: Some("h_bastion".into()),
            default_proxy_id: Some("p_corp".into()),
            default_theme: Some("emerald".into()),
            env: root_env,
            ..Default::default()
        };

        let mut prod_env = BTreeMap::new();
        prod_env.insert("STAGE".into(), "prod".into());
        let g_prod = Group {
            id: "g_prod".into(),
            parent_id: Some("g_root".into()),
            name: "Production".into(),
            env: prod_env,
            ..Default::default()
        };

        // Inherited host
        let h_inherited = Host {
            id: "h1".into(),
            group_id: Some("g_prod".into()),
            label: "web-01".into(),
            hostname: "10.0.1.10".into(),
            env_tag: EnvTag::Prod,
            ..Default::default()
        };
        let eff1 = resolve_effective_host_config(
            &h_inherited,
            &[g_root.clone(), g_prod.clone()],
            &[id_root.clone(), id_personal.clone()],
            &[cred_root.clone(), cred_team.clone()],
            std::slice::from_ref(&bastion),
            std::slice::from_ref(&proxy),
            true,
        );
        assert_eq!(eff1.identity.as_ref().unwrap().username, "ubuntu");
        assert_eq!(eff1.jump_host.as_ref().unwrap().hostname, "jump.example.com");
        assert_eq!(eff1.proxy.as_ref().unwrap().port, 1080);
        assert_eq!(eff1.credential.as_ref().unwrap().id, "c_root");
        assert_eq!(eff1.proxy_credential.as_ref().unwrap().id, "c_team");
        assert_eq!(eff1.env.get("STAGE").unwrap(), "prod");
        assert!(eff1.follow_terminal_sftp);
        assert!(eff1.overrides.is_empty());

        // Host with ByName identity + jump disabled + follow SFTP disabled
        let h_override = Host {
            id: "h2".into(),
            group_id: Some("g_prod".into()),
            label: "direct-02".into(),
            hostname: "10.0.1.20".into(),
            identity_mode: IdentityMode::ByName,
            identity_name_ref: Some("mypersonalops".into()),
            jump_host_mode: InheritMode::None,
            follow_terminal_sftp: Some(false),
            ..Default::default()
        };
        let eff2 = resolve_effective_host_config(
            &h_override,
            &[g_root, g_prod],
            &[id_root, id_personal],
            &[cred_root, cred_team],
            &[bastion],
            &[proxy],
            true,
        );
        assert_eq!(eff2.identity.as_ref().unwrap().username, "vantrong");
        assert_eq!(eff2.credential.as_ref().unwrap().secret.as_deref(), Some("s3cr3t"));
        assert!(eff2.jump_host.is_none());
        assert!(!eff2.follow_terminal_sftp);
        assert!(eff2.overrides.contains(OverrideFlags::IDENTITY));
        assert!(eff2.overrides.contains(OverrideFlags::JUMP_HOST));
        assert!(eff2.overrides.contains(OverrideFlags::FOLLOW_SFTP));
    }

    #[test]
    fn handles_cyclic_groups_safely() {
        let g1 = Group {
            id: "g1".into(),
            parent_id: Some("g2".into()),
            name: "G1".into(),
            ..Default::default()
        };
        let g2 = Group {
            id: "g2".into(),
            parent_id: Some("g1".into()),
            name: "G2".into(),
            ..Default::default()
        };
        let host = Host {
            id: "h1".into(),
            group_id: Some("g1".into()),
            label: "node".into(),
            hostname: "127.0.0.1".into(),
            ..Default::default()
        };
        let eff = resolve_effective_host_config(&host, &[g1, g2], &[], &[], &[], &[], true);
        assert!(eff.identity.is_none());
    }
}
