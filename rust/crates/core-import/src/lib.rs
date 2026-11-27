use core_model::{EnvTag, Host, Identity, IdentityMode, InheritMode, ProtocolKind};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedBundle {
    pub hosts: Vec<Host>,
    pub identities: Vec<Identity>,
    pub warnings: Vec<String>,
}

/// Parses OpenSSH `~/.ssh/config` content into TermPulse Hosts & Identities.
pub fn import_ssh_config(content: &str) -> ImportedBundle {
    let mut hosts = Vec::new();
    let mut identities = Vec::new();
    let mut warnings = Vec::new();

    #[derive(Default)]
    struct Block {
        alias: String,
        hostname: Option<String>,
        user: Option<String>,
        port: Option<u16>,
        identity_file: Option<String>,
        proxy_jump: Option<String>,
        startup_cmd: Option<String>,
    }

    let mut current: Option<Block> = None;
    let mut pending_jumps: Vec<(usize, String)> = Vec::new();

    let flush = |b: Block,
                 hosts: &mut Vec<Host>,
                 identities: &mut Vec<Identity>,
                 pending_jumps: &mut Vec<(usize, String)>| {
        if b.alias.is_empty() || b.alias.contains('*') || b.alias.contains('?') {
            return;
        }
        let mut identity_id = None;
        if let Some(user) = b.user {
            let id_obj = Identity {
                id: uuid::Uuid::new_v4().to_string(),
                name: format!("{}@{}", user, b.alias),
                username: user,
                credential_id: None,
            };
            identity_id = Some(id_obj.id.clone());
            identities.push(id_obj);
        }

        let mut notes = String::new();
        if let Some(key_path) = b.identity_file {
            notes.push_str(&format!("IdentityFile: {key_path}\n"));
        }

        let host = Host {
            label: b.alias.clone(),
            protocol: ProtocolKind::Ssh,
            hostname: b.hostname.unwrap_or_else(|| b.alias.clone()),
            port: b.port.unwrap_or(22),
            identity_mode: if identity_id.is_some() {
                IdentityMode::ById
            } else {
                IdentityMode::Inherit
            },
            identity_id,
            notes,
            startup_cmd: b.startup_cmd,
            ..Default::default()
        };
        let idx = hosts.len();
        hosts.push(host);
        if let Some(pj) = b.proxy_jump {
            pending_jumps.push((idx, pj));
        }
    };

    for raw_line in content.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(2, |c: char| c.is_whitespace() || c == '=');
        let key = parts.next().unwrap_or("").trim().to_ascii_lowercase();
        let val = parts.next().unwrap_or("").trim().trim_matches('"').to_string();

        if key == "host" {
            if let Some(prev) = current.take() {
                flush(prev, &mut hosts, &mut identities, &mut pending_jumps);
            }
            let first_alias = val.split_whitespace().next().unwrap_or("").to_string();
            if first_alias.contains('*') || first_alias.contains('?') {
                warnings.push(format!("Bỏ qua wildcard block `Host {val}`"));
            }
            current = Some(Block {
                alias: first_alias,
                ..Default::default()
            });
        } else if let Some(ref mut b) = current {
            match key.as_str() {
                "hostname" => b.hostname = Some(val),
                "user" => b.user = Some(val),
                "port" => b.port = val.parse::<u16>().ok(),
                "identityfile" => b.identity_file = Some(val),
                "proxyjump" => b.proxy_jump = Some(val),
                "remotecommand" => b.startup_cmd = Some(val),
                _ => {}
            }
        }
    }
    if let Some(prev) = current.take() {
        flush(prev, &mut hosts, &mut identities, &mut pending_jumps);
    }

    // Wire ProxyJump references if target alias was also imported
    let label_to_id: HashMap<String, String> = hosts
        .iter()
        .map(|h| (h.label.clone(), h.id.clone()))
        .collect();
    for (idx, jump_alias) in pending_jumps {
        if let Some(jump_id) = label_to_id.get(&jump_alias) {
            hosts[idx].jump_host_mode = InheritMode::Direct;
            hosts[idx].jump_host_id = Some(jump_id.clone());
        } else {
            warnings.push(format!(
                "Host `{}` tham chiếu ProxyJump `{jump_alias}` chưa có trong file.",
                hosts[idx].label
            ));
        }
    }

    ImportedBundle {
        hosts,
        identities,
        warnings,
    }
}

pub fn export_ssh_config(hosts: &[Host], identities: &[Identity]) -> String {
    let id_map: HashMap<&str, &Identity> = identities.iter().map(|i| (i.id.as_str(), i)).collect();
    let host_map: HashMap<&str, &Host> = hosts.iter().map(|h| (h.id.as_str(), h)).collect();
    let mut out = String::from("# Exported by TermPulse (OpenSSH config format)\n\n");
    for h in hosts.iter().filter(|h| h.protocol == ProtocolKind::Ssh) {
        let alias = h.label.replace(' ', "-");
        out.push_str(&format!("Host {alias}\n"));
        out.push_str(&format!("    HostName {}\n", h.hostname));
        out.push_str(&format!("    Port {}\n", h.port));
        if let Some(id_ref) = &h.identity_id {
            if let Some(ident) = id_map.get(id_ref.as_str()) {
                out.push_str(&format!("    User {}\n", ident.username));
            }
        }
        if let Some(jid) = &h.jump_host_id {
            if let Some(jh) = host_map.get(jid.as_str()) {
                out.push_str(&format!("    ProxyJump {}\n", jh.label.replace(' ', "-")));
            }
        }
        out.push('\n');
    }
    out
}

#[derive(Debug, Deserialize, Serialize)]
struct CsvHostRow {
    label: String,
    hostname: String,
    port: Option<u16>,
    username: Option<String>,
    env: Option<String>,
    tags: Option<String>,
}

pub fn import_csv(content: &str) -> Result<ImportedBundle, String> {
    let mut rdr = csv::ReaderBuilder::new()
        .flexible(true)
        .trim(csv::Trim::All)
        .from_reader(content.as_bytes());
    let mut hosts = Vec::new();
    let mut identities = Vec::new();
    let warnings = Vec::new();

    for rec in rdr.deserialize::<CsvHostRow>() {
        let row = rec.map_err(|e| format!("Lỗi đọc CSV: {e}"))?;
        let mut identity_id = None;
        if let Some(u) = row.username.filter(|s| !s.is_empty()) {
            let ident = Identity {
                id: uuid::Uuid::new_v4().to_string(),
                name: format!("{u}@{}", row.label),
                username: u,
                credential_id: None,
            };
            identity_id = Some(ident.id.clone());
            identities.push(ident);
        }
        let env_tag = match row.env.as_deref().map(|s| s.to_ascii_lowercase()).as_deref() {
            Some("prod") | Some("production") => EnvTag::Prod,
            Some("staging") => EnvTag::Staging,
            Some("homelab") => EnvTag::Homelab,
            _ => EnvTag::Dev,
        };
        let tags = row
            .tags
            .unwrap_or_default()
            .split([';', '|'])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        hosts.push(Host {
            label: row.label,
            hostname: row.hostname,
            port: row.port.unwrap_or(22),
            identity_mode: if identity_id.is_some() {
                IdentityMode::ById
            } else {
                IdentityMode::Inherit
            },
            identity_id,
            env_tag,
            tags,
            ..Default::default()
        });
    }

    Ok(ImportedBundle {
        hosts,
        identities,
        warnings,
    })
}

pub fn import_putty_reg(content: &str) -> ImportedBundle {
    let mut hosts = Vec::new();
    let mut identities = Vec::new();
    let warnings = Vec::new();

    let mut cur_name: Option<String> = None;
    let mut cur_host = String::new();
    let mut cur_port: u16 = 22;
    let mut cur_user = String::new();

    let flush = |name: Option<String>,
                 host: &mut String,
                 port: &mut u16,
                 user: &mut String,
                 hosts: &mut Vec<Host>,
                 identities: &mut Vec<Identity>| {
        if let Some(n) = name {
            if !host.is_empty() {
                let mut identity_id = None;
                if !user.is_empty() {
                    let ident = Identity {
                        id: uuid::Uuid::new_v4().to_string(),
                        name: format!("{user}@{n}"),
                        username: user.clone(),
                        credential_id: None,
                    };
                    identity_id = Some(ident.id.clone());
                    identities.push(ident);
                }
                hosts.push(Host {
                    label: n.replace("%20", " "),
                    hostname: host.clone(),
                    port: *port,
                    identity_mode: if identity_id.is_some() {
                        IdentityMode::ById
                    } else {
                        IdentityMode::Inherit
                    },
                    identity_id,
                    ..Default::default()
                });
            }
        }
        host.clear();
        *port = 22;
        user.clear();
    };

    for raw in content.lines() {
        let line = raw.trim();
        if line.starts_with('[') && line.ends_with(']') {
            flush(
                cur_name.take(),
                &mut cur_host,
                &mut cur_port,
                &mut cur_user,
                &mut hosts,
                &mut identities,
            );
            if let Some(idx) = line.rfind("\\Sessions\\") {
                let name = line[idx + "\\Sessions\\".len()..line.len() - 1].to_string();
                if name != "Default%20Settings" && !name.is_empty() {
                    cur_name = Some(name);
                }
            }
        } else if cur_name.is_some() {
            if let Some(v) = line.strip_prefix("\"HostName\"=") {
                cur_host = v.trim_matches('"').to_string();
            } else if let Some(v) = line.strip_prefix("\"UserName\"=") {
                cur_user = v.trim_matches('"').to_string();
            } else if let Some(v) = line.strip_prefix("\"PortNumber\"=dword:") {
                if let Ok(p) = u16::from_str_radix(v.trim(), 16) {
                    cur_port = p;
                }
            }
        }
    }
    flush(
        cur_name.take(),
        &mut cur_host,
        &mut cur_port,
        &mut cur_user,
        &mut hosts,
        &mut identities,
    );

    ImportedBundle {
        hosts,
        identities,
        warnings,
    }
}

/// Built-in contextual help dictionary for `~/.ssh/config` directives (Core Shell style).
pub fn explain_ssh_directive(directive: &str) -> Option<&'static str> {
    match directive.to_ascii_lowercase().as_str() {
        "hostname" => Some("Địa chỉ IP hoặc tên miền thực tế của máy chủ đích."),
        "user" => Some("Tên tài khoản dùng để đăng nhập SSH."),
        "port" => Some("Cổng TCP dịch vụ SSH (mặc định 22)."),
        "identityfile" => Some("Đường dẫn tới file Private Key (ví dụ ~/.ssh/id_ed25519)."),
        "proxyjump" => Some("Đi xuyên qua một hoặc nhiều Bastion/Jump Host trước khi tới máy đích."),
        "forwardagent" => Some("Chuyển tiếp SSH Agent cục bộ để dùng key từ máy bạn trên server trung gian."),
        "serveraliveinterval" => Some("Chu kỳ (giây) gửi gói keep-alive tránh bị tường lửa ngắt kết nối nhàn rỗi."),
        "localforward" => Some("Mở cổng cục bộ chuyển tiếp qua đường hầm SSH tới dịch vụ từ xa (-L)."),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_and_exports_ssh_config_with_proxyjump() {
        let cfg = r#"
Host *
    ServerAliveInterval 30

Host bastion
    HostName 203.0.113.10
    User ops
    Port 2222

Host prod-db
    HostName 10.0.5.9
    User postgres
    ProxyJump bastion
"#;
        let bundle = import_ssh_config(cfg);
        assert_eq!(bundle.hosts.len(), 2);
        assert_eq!(bundle.identities.len(), 2);
        assert_eq!(bundle.hosts[0].port, 2222);
        assert_eq!(
            bundle.hosts[1].jump_host_id.as_deref(),
            Some(bundle.hosts[0].id.as_str())
        );

        let exported = export_ssh_config(&bundle.hosts, &bundle.identities);
        assert!(exported.contains("ProxyJump bastion"));
        assert!(exported.contains("Port 2222"));
    }

    #[test]
    fn imports_csv_and_putty_reg() {
        let csv_in = "label,hostname,port,username,env,tags\napi-01,10.0.0.5,22,deploy,prod,web;eu\n";
        let res = import_csv(csv_in).unwrap();
        assert_eq!(res.hosts.len(), 1);
        assert_eq!(res.hosts[0].env_tag, EnvTag::Prod);
        assert_eq!(res.hosts[0].tags, vec!["web", "eu"]);

        let reg = r#"
[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\My%20Server]
"HostName"="192.168.1.50"
"PortNumber"=dword:000008ae
"UserName"="admin"
"#;
        let p_res = import_putty_reg(reg);
        assert_eq!(p_res.hosts.len(), 1);
        assert_eq!(p_res.hosts[0].label, "My Server");
        assert_eq!(p_res.hosts[0].port, 2222);
    }
}

