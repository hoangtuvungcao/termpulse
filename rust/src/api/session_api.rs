use crate::api::dto::{ActiveSessionInfoDto, GuardResultDto, TerminalEventDto};
use crate::frb_generated::StreamSink;
use crate::state::{state, with_vault, ActiveSession};
use core_model::{
    resolve_effective_host_config, Credential, CredentialKind, EffectiveHostConfig, EnvTag, Host,
    Identity, IdentityMode,
};
use core_terminal::{CommandGuard, TerminalPassiveEvent, TerminalStreamInspector};
use core_transport::{
    connect_ssh_client, connect_telnet, open_sftp_session, spawn_local_shell, spawn_ssh_shell,
    spawn_ssh_shell_with_env, validate_proxy_credentials, SessionInput, SessionOutput,
};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex as AsyncMutex};

pub(crate) fn ssh_known_hosts_path() -> Result<std::path::PathBuf, String> {
    let path = state().vault_path.lock().map_err(|_| "Vault path lock error".to_string())?;
    let path = path.as_ref().ok_or_else(|| "Hãy mở Vault trước khi kết nối SSH để lưu và xác minh host key.".to_string())?;
    let mut known_hosts_path = path.as_os_str().to_os_string();
    known_hosts_path.push(".ssh_known_hosts");
    Ok(std::path::PathBuf::from(known_hosts_path))
}

fn parse_quick_ssh_target(target: &str) -> Result<(String, String, u16), String> {
    let invalid = || "Địa chỉ SSH không hợp lệ. Dùng user@host:port hoặc user@[IPv6]:port".to_string();
    let target = target.trim();
    if target.is_empty() || target.chars().any(char::is_whitespace) {
        return Err(invalid());
    }
    let (user, host_port) = match target.split_once('@') {
        Some((user, host)) if !user.is_empty() && !host.contains('@') => (user, host),
        Some(_) => return Err(invalid()),
        None => ("root", target),
    };
    let (hostname, port_text) = if let Some(bracketed) = host_port.strip_prefix('[') {
        let (host, rest) = bracketed.split_once(']').ok_or_else(invalid)?;
        host.parse::<std::net::Ipv6Addr>().map_err(|_| invalid())?;
        let port_text = if rest.is_empty() {
            None
        } else {
            Some(rest.strip_prefix(':').ok_or_else(invalid)?)
        };
        (host, port_text)
    } else if host_port.matches(':').count() > 1 {
        host_port.parse::<std::net::Ipv6Addr>().map_err(|_| invalid())?;
        (host_port, None)
    } else if let Some((host, port)) = host_port.split_once(':') {
        (host, Some(port))
    } else {
        (host_port, None)
    };
    if hostname.is_empty() || hostname.contains(['/', '\\', '[', ']', '?', '#']) {
        return Err(invalid());
    }
    let port = match port_text {
        Some(text) => text.parse::<u16>().ok().filter(|port| *port > 0).ok_or_else(invalid)?,
        None => 22,
    };
    Ok((user.to_string(), hostname.to_string(), port))
}

fn ssh_startup_command(startup_dir: Option<&str>, startup_cmd: Option<&str>) -> Option<String> {
    let quote = |text: &str| format!("'{}'", text.replace('\'', "'\\''"));
    let change_dir = startup_dir.filter(|dir| !dir.trim().is_empty()).map(|dir| {
        if dir == "~" || dir == "$HOME" {
            "cd".to_string()
        } else if let Some(relative) = dir.strip_prefix("~/") {
            format!("cd -- \"$HOME\"/{}", quote(relative))
        } else {
            format!("cd -- {}", quote(dir))
        }
    });
    match (change_dir, startup_cmd.filter(|cmd| !cmd.trim().is_empty())) {
        (Some(dir), Some(cmd)) => Some(format!("{dir} && {cmd}")),
        (Some(dir), None) => Some(dir),
        (None, Some(cmd)) => Some(cmd.to_string()),
        (None, None) => None,
    }
}

fn resolve_from_vault(host_id: &str) -> Result<(EffectiveHostConfig, Option<EffectiveHostConfig>), String> {
    with_vault(|s| {
        let host = s
            .get_host(host_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Không tìm thấy Host".to_string())?;
        let groups = s.list_groups().map_err(|e| e.to_string())?;
        let idents = s.list_identities().map_err(|e| e.to_string())?;
        let creds = s.list_credentials().map_err(|e| e.to_string())?;
        let hosts = s.list_hosts().map_err(|e| e.to_string())?;
        let proxies = s.list_proxies().map_err(|e| e.to_string())?;
        core_model::validate_proxy_reference(&host, &groups, &proxies)?;
        let eff = resolve_effective_host_config(&host, &groups, &idents, &creds, &hosts, &proxies, true);
        if let Some(jump) = eff.jump_host.as_ref() { core_model::validate_proxy_reference(jump, &groups, &proxies)?; }
        let jump_eff = eff.jump_host.as_ref().map(|jh| {
            resolve_effective_host_config(jh, &groups, &idents, &creds, &hosts, &proxies, true)
        });
        validate_proxy_credentials(eff.proxy.as_ref(), &creds).map_err(|error| error.to_string())?;
        if let Some(jump) = jump_eff.as_ref() {
            validate_proxy_credentials(jump.proxy.as_ref(), &creds).map_err(|error| error.to_string())?;
        }
        Ok((eff, jump_eff))
    })
}

/// Batches output every ~12ms / 64KB and runs passive OSC inspection without mutating PTY bytes.
pub(crate) fn spawn_output_pump(
    session_id: String,
    mut rx: mpsc::Receiver<SessionOutput>,
    sink: StreamSink<TerminalEventDto>,
) {
    state().rt.spawn(async move {
        let mut inspector = TerminalStreamInspector::new();
        let mut batch: Vec<u8> = Vec::with_capacity(16 * 1024);
        let mut interval = tokio::time::interval(Duration::from_millis(12));

        'pump: loop {
            tokio::select! {
                _ = interval.tick() => {
                    if !batch.is_empty() {
                        let chunk = std::mem::take(&mut batch);
                        if sink.add(TerminalEventDto::output_bytes(chunk)).is_err() {
                            break 'pump;
                        }
                    }
                }
                msg = rx.recv() => {
                    match msg {
                        Some(SessionOutput::Data(bytes)) => {
                            let events = inspector.feed(&bytes);
                            for ev in events {
                                match ev {
                                    TerminalPassiveEvent::CwdChanged(cwd) => {
                                        if let Some(s) = state().sessions.lock().await.get_mut(&session_id) {
                                            s.cwd = cwd.clone();
                                        }
                                        if sink.add(TerminalEventDto::cwd_changed(cwd)).is_err() {
                                            break 'pump;
                                        }
                                    }
                                    TerminalPassiveEvent::TitleChanged(t) => {
                                        if sink.add(TerminalEventDto::title_changed(t)).is_err() {
                                            break 'pump;
                                        }
                                    }
                                    TerminalPassiveEvent::AgentNotification { title, body } => {
                                        if sink.add(TerminalEventDto::agent_notification(title, body)).is_err() {
                                            break 'pump;
                                        }
                                    }
                                    TerminalPassiveEvent::ZmodemDetected => {
                                        if sink.add(TerminalEventDto::zmodem_detected()).is_err() {
                                            break 'pump;
                                        }
                                    }
                                    TerminalPassiveEvent::TrzszDetected => {
                                        if sink.add(TerminalEventDto::trzsz_detected()).is_err() {
                                            break 'pump;
                                        }
                                    }
                                }
                            }
                            batch.extend_from_slice(&bytes);
                            if batch.len() >= 64 * 1024 {
                                let chunk = std::mem::take(&mut batch);
                                if sink.add(TerminalEventDto::output_bytes(chunk)).is_err() {
                                    break 'pump;
                                }
                            }
                        }
                        Some(SessionOutput::Closed(reason)) => {
                            if !batch.is_empty() {
                                let chunk = std::mem::take(&mut batch);
                                let _ = sink.add(TerminalEventDto::output_bytes(chunk));
                            }
                            let _ = sink.add(TerminalEventDto::closed(reason));
                            state().sessions.lock().await.remove(&session_id);
                            break;
                        }
                        None => {
                            if !batch.is_empty() {
                                let chunk = std::mem::take(&mut batch);
                                let _ = sink.add(TerminalEventDto::output_bytes(chunk));
                            }
                            let _ = sink.add(TerminalEventDto::closed(None));
                            state().sessions.lock().await.remove(&session_id);
                            break;
                        }
                    }
                }
            }
        }
        // Closing a tab can cancel its Dart stream before connection setup returns.
        // Stop the underlying PTY/socket as soon as delivery reports that cancellation.
        let session = state().sessions.lock().await.remove(&session_id);
        if let Some(session) = session {
            let _ = session.input_tx.send(SessionInput::Close).await;
        }
    });
}

pub(crate) fn announce_session(session_id: &str, sink: &StreamSink<TerminalEventDto>) -> Result<(), String> {
    if sink.add(TerminalEventDto::session_opened(session_id.to_string())).is_err() {
        close_session(session_id.to_string())?;
        return Err("Yêu cầu mở phiên đã bị huỷ".into());
    }
    Ok(())
}

// FRB discards the setup Future for StreamSink APIs. Report setup failures
// through the stream rather than returning an error on that Future.
pub fn connect_ssh_host(
    host_id: String,
    cols: u16,
    rows: u16,
    sink: StreamSink<TerminalEventDto>,
) {
    if let Err(error) = connect_ssh_host_inner(host_id, cols, rows, sink.clone()) {
        let _ = sink.add_error(error);
    }
}

fn connect_ssh_host_inner(
    host_id: String,
    cols: u16,
    rows: u16,
    sink: StreamSink<TerminalEventDto>,
) -> Result<String, String> {
    let (eff, jump_eff) = resolve_from_vault(&host_id)?;
    let known_hosts_path = ssh_known_hosts_path()?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let title = eff.host.label.clone();
    let env_tag = eff.host.env_tag;
    let startup_dir = eff.host.startup_dir.clone().unwrap_or_else(|| "~".into());
    let startup_cmd = ssh_startup_command(
        eff.host.startup_dir.as_deref(),
        eff.host.startup_cmd.as_deref(),
    );

    let (ssh, in_tx, out_rx, sftp_opt, sftp_err) = state()
        .rt
        .block_on(async {
            let ssh = Arc::new(
                connect_ssh_client(&eff, jump_eff.as_ref(), &known_hosts_path)
                    .await
                    .map_err(|e| e.to_string())?,
            );
            let (in_tx, out_rx) = spawn_ssh_shell_with_env(&ssh, cols, rows, startup_cmd, &eff.env)
                .await
                .map_err(|e| e.to_string())?;
            let (sftp_opt, sftp_err) = match open_sftp_session(&ssh).await {
                Ok(s) => (Some(Arc::new(s)), None),
                Err(e) => (None, Some(e.to_string())),
            };
            Ok::<_, String>((ssh, in_tx, out_rx, sftp_opt, sftp_err))
        })?;

    if let Some(ref reason) = sftp_err {
        let _ = sink.add(TerminalEventDto::sftp_unavailable(reason.clone()));
    }

    let sess = ActiveSession {
        id: session_id.clone(),
        host_id: Some(host_id.clone()),
        title,
        env_tag,
        cwd: startup_dir,
        input_tx: in_tx,
        ssh: Some(ssh),
        sftp: Arc::new(AsyncMutex::new(sftp_opt)),
        sftp_unavailable_reason: sftp_err,
        prev_cpu: None,
    };
    state().rt.block_on(async {
        state().sessions.lock().await.insert(session_id.clone(), sess);
    });
    announce_session(&session_id, &sink)?;
    let _ = with_vault(|store| store.mark_host_connected(&host_id).map_err(|error| error.to_string()));
    spawn_output_pump(session_id.clone(), out_rx, sink);
    Ok(session_id)
}

/// Quick-connect `user@host:port` without requiring a saved entry first.
pub fn connect_quick_ssh(
    target: String,
    password: Option<String>,
    private_key_pem: Option<String>,
    cols: u16,
    rows: u16,
    sink: StreamSink<TerminalEventDto>,
) {
    if let Err(error) = connect_quick_ssh_inner(target, password, private_key_pem, cols, rows, sink.clone()) {
        let _ = sink.add_error(error);
    }
}

fn connect_quick_ssh_inner(
    target: String,
    password: Option<String>,
    private_key_pem: Option<String>,
    cols: u16,
    rows: u16,
    sink: StreamSink<TerminalEventDto>,
) -> Result<String, String> {
    let (user, hostname, port) = parse_quick_ssh_target(&target)?;
    let known_hosts_path = ssh_known_hosts_path()?;

    let cred = if let Some(pem) = private_key_pem.filter(|s| !s.trim().is_empty()) {
        Some(Credential {
            id: "quick_cred".into(),
            name: "Quick Key".into(),
            kind: CredentialKind::SshKey,
            secret: Some(pem),
            ..Default::default()
        })
    } else {
        password.map(|pw| Credential {
            id: "quick_cred".into(),
            name: "Quick Password".into(),
            kind: CredentialKind::Password,
            secret: Some(pw),
            ..Default::default()
        })
    };

    let host = Host {
        id: "quick".into(),
        label: format!("{user}@{hostname}"),
        hostname: hostname.clone(),
        port,
        identity_mode: IdentityMode::ById,
        identity_id: Some("quick_id".into()),
        ..Default::default()
    };
    let ident = Identity {
        id: "quick_id".into(),
        name: "Quick".into(),
        username: user.clone(),
        credential_id: cred.as_ref().map(|c| c.id.clone()),
    };
    let eff = EffectiveHostConfig {
        host,
        identity: Some(ident),
        credential: cred,
        jump_host: None,
        proxy: None,
        proxy_credential: None,
        theme: None,
        env: Default::default(),
        follow_terminal_sftp: true,
        overrides: Default::default(),
    };

    let session_id = uuid::Uuid::new_v4().to_string();
    let (ssh, in_tx, out_rx, sftp_opt, sftp_err) = state()
        .rt
        .block_on(async {
            let ssh = Arc::new(
                connect_ssh_client(&eff, None, &known_hosts_path)
                    .await
                    .map_err(|e| e.to_string())?,
            );
            let (in_tx, out_rx) = spawn_ssh_shell(&ssh, cols, rows, None)
                .await
                .map_err(|e| e.to_string())?;
            let (sftp_opt, sftp_err) = match open_sftp_session(&ssh).await {
                Ok(s) => (Some(Arc::new(s)), None),
                Err(e) => (None, Some(e.to_string())),
            };
            Ok::<_, String>((ssh, in_tx, out_rx, sftp_opt, sftp_err))
        })?;

    if let Some(ref reason) = sftp_err {
        let _ = sink.add(TerminalEventDto::sftp_unavailable(reason.clone()));
    }

    let sess = ActiveSession {
        id: session_id.clone(),
        host_id: None,
        title: format!("{user}@{hostname}:{port}"),
        env_tag: EnvTag::Dev,
        cwd: "~".into(),
        input_tx: in_tx,
        ssh: Some(ssh),
        sftp: Arc::new(AsyncMutex::new(sftp_opt)),
        sftp_unavailable_reason: sftp_err,
        prev_cpu: None,
    };
    state().rt.block_on(async {
        state().sessions.lock().await.insert(session_id.clone(), sess);
    });
    announce_session(&session_id, &sink)?;
    spawn_output_pump(session_id.clone(), out_rx, sink);
    Ok(session_id)
}

pub fn connect_local_shell(
    cols: u16,
    rows: u16,
    startup_dir: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) {
    if let Err(error) = connect_local_shell_inner(cols, rows, startup_dir, sink.clone()) {
        let _ = sink.add_error(error);
    }
}

fn connect_local_shell_inner(
    cols: u16,
    rows: u16,
    startup_dir: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) -> Result<String, String> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let cwd = startup_dir.as_deref()
        .filter(|dir| !dir.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .map(|path| std::fs::canonicalize(&path).unwrap_or(path).display().to_string())
        .unwrap_or_else(|| "~".into());
    let (in_tx, out_rx) = state()
        .rt
        .block_on(async { spawn_local_shell(cols, rows, startup_dir).map_err(|e| e.to_string()) })?;

    let sess = ActiveSession {
        id: session_id.clone(),
        host_id: None,
        title: "Local Shell".into(),
        env_tag: EnvTag::Dev,
        cwd,
        input_tx: in_tx,
        ssh: None,
        sftp: Arc::new(AsyncMutex::new(None)),
        sftp_unavailable_reason: Some("Phiên Local Shell không dùng SFTP".into()),
        prev_cpu: None,
    };
    state().rt.block_on(async {
        state().sessions.lock().await.insert(session_id.clone(), sess);
    });
    announce_session(&session_id, &sink)?;
    spawn_output_pump(session_id.clone(), out_rx, sink);
    Ok(session_id)
}

pub fn connect_telnet_host(
    hostname: String,
    port: u16,
    label: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) {
    if let Err(error) = connect_telnet_host_inner(hostname, port, label, sink.clone()) {
        let _ = sink.add_error(error);
    }
}

fn connect_telnet_host_inner(
    hostname: String,
    port: u16,
    label: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) -> Result<String, String> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let (in_tx, out_rx) = state()
        .rt
        .block_on(async { connect_telnet(&hostname, port).await.map_err(|e| e.to_string()) })?;

    let sess = ActiveSession {
        id: session_id.clone(),
        host_id: None,
        title: label.unwrap_or_else(|| format!("Telnet {hostname}:{port}")),
        env_tag: EnvTag::Dev,
        cwd: "/".into(),
        input_tx: in_tx,
        ssh: None,
        sftp: Arc::new(AsyncMutex::new(None)),
        sftp_unavailable_reason: Some("Telnet không hỗ trợ SFTP".into()),
        prev_cpu: None,
    };
    state().rt.block_on(async {
        state().sessions.lock().await.insert(session_id.clone(), sess);
    });
    announce_session(&session_id, &sink)?;
    spawn_output_pump(session_id.clone(), out_rx, sink);
    Ok(session_id)
}

pub fn send_session_input(session_id: String, data: Vec<u8>) -> Result<(), String> {
    state().rt.block_on(async {
        let tx = {
            let guard = state().sessions.lock().await;
            let s = guard
                .get(&session_id)
                .ok_or_else(|| "Phiên không tồn tại".to_string())?;
            if data.ends_with(b"\n") || data.ends_with(b"\r") {
                if let Ok(text) = std::str::from_utf8(&data) {
                    let clean = text.trim();
                    if !clean.is_empty() && !clean.contains('\n') {
                        let host_id = s.host_id.clone();
                        let _ = with_vault(|v| {
                            v.record_command_history(host_id.as_deref(), clean)
                                .map_err(|e| e.to_string())
                        });
                    }
                }
            }
            s.input_tx.clone()
        };
        tx.send(SessionInput::Bytes(data))
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn broadcast_session_input(session_ids: Vec<String>, data: Vec<u8>) -> Result<usize, String> {
    state().rt.block_on(async {
        let txs: Vec<mpsc::Sender<SessionInput>> = {
            let guard = state().sessions.lock().await;
            session_ids
                .iter()
                .filter_map(|id| guard.get(id).map(|s| s.input_tx.clone()))
                .collect()
        };
        let mut sent = 0usize;
        for tx in txs {
            if tx.send(SessionInput::Bytes(data.clone())).await.is_ok() {
                sent += 1;
            }
        }
        Ok(sent)
    })
}

pub fn resize_terminal(session_id: String, cols: u16, rows: u16) -> Result<(), String> {
    state().rt.block_on(async {
        let tx = {
            let guard = state().sessions.lock().await;
            guard.get(&session_id).map(|s| s.input_tx.clone())
        };
        if let Some(tx) = tx {
            let _ = tx.send(SessionInput::Resize { cols, rows }).await;
        }
        Ok(())
    })
}

pub fn close_session(session_id: String) -> Result<(), String> {
    state().rt.block_on(async {
        let session = state().sessions.lock().await.remove(&session_id);
        if let Some(s) = session {
            let _ = s.input_tx.send(SessionInput::Close).await;
        }
        Ok(())
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn check_command_guard(input: String, env_tag: String) -> GuardResultDto {
    let guard = CommandGuard::new();
    let tag = match env_tag.to_ascii_lowercase().as_str() {
        "prod" => EnvTag::Prod,
        "staging" => EnvTag::Staging,
        "homelab" => EnvTag::Homelab,
        _ => EnvTag::Dev,
    };
    guard.check(&input, tag).into()
}

pub fn list_active_sessions() -> Result<Vec<ActiveSessionInfoDto>, String> {
    state().rt.block_on(async {
        let guard = state().sessions.lock().await;
        let mut out = Vec::with_capacity(guard.len());
        for s in guard.values() {
            let has_sftp = s.sftp.lock().await.is_some();
            out.push(ActiveSessionInfoDto {
                session_id: s.id.clone(),
                host_id: s.host_id.clone(),
                title: s.title.clone(),
                env_tag: match s.env_tag {
                    EnvTag::Prod => "prod",
                    EnvTag::Staging => "staging",
                    EnvTag::Dev => "dev",
                    EnvTag::Homelab => "homelab",
                }
                .to_string(),
                cwd: s.cwd.clone(),
                has_sftp,
                sftp_unavailable_reason: s.sftp_unavailable_reason.clone(),
            });
        }
        Ok(out)
    })
}

#[cfg(test)]
mod tests {
    use super::{parse_quick_ssh_target, ssh_startup_command};

    #[test]
    fn ssh_startup_directory_is_quoted_before_running_command() {
        assert_eq!(ssh_startup_command(None, None), None);
        assert_eq!(ssh_startup_command(Some("~/app files"), Some("pwd")),
            Some("cd -- \"$HOME\"/'app files' && pwd".into()));
        assert_eq!(ssh_startup_command(Some("/app's files; echo unsafe"), None),
            Some("cd -- '/app'\\''s files; echo unsafe'".into()));
        assert_eq!(ssh_startup_command(Some("~"), None), Some("cd".into()));
    }

    #[test]
    fn quick_ssh_target_accepts_hostnames_and_ipv6() {
        for (input, user, host, port) in [
            (" server.local ", "root", "server.local", 22),
            ("alice@server.local:2222", "alice", "server.local", 2222),
            ("alice@[2001:db8::1]:2222", "alice", "2001:db8::1", 2222),
            ("[::1]", "root", "::1", 22),
            ("alice@2001:db8::1", "alice", "2001:db8::1", 22),
        ] {
            assert_eq!(
                parse_quick_ssh_target(input).unwrap(),
                (user.to_string(), host.to_string(), port)
            );
        }
    }

    #[test]
    fn quick_ssh_target_rejects_invalid_ports_and_addresses() {
        for input in ["", "@host", "alice@", "a@b@host", "host:abc", "host:",
            "host:0", "host:65536", "ssh://host", "host path", "[::1", "[bad]:22",
            "[::1]unexpected", "[::1]:", "[::1]:0"] {
            assert!(parse_quick_ssh_target(input).is_err(), "accepted {input}");
        }
    }
}
