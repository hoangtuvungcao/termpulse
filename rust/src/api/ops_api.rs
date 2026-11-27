use crate::api::dto::{AiDraftDto, HostMetricsDto, TunnelStatusDto};
use crate::api::session_api::ssh_known_hosts_path;
use crate::state::{state, with_vault};
use core_model::resolve_effective_host_config;
use core_terminal::suggest_ghost_text;
use core_transport::{
    connect_ssh_client, exec_ssh_command, generate_ai_command, measure_tcp_latency_ms,
    parse_proc_probe_output, send_wake_on_lan, start_ssh_tunnel, validate_proxy_credentials, PROC_PROBE_SCRIPT,
};
use std::sync::Arc;
use std::time::Duration;

pub fn start_tunnel_by_id(tunnel_id: String) -> Result<TunnelStatusDto, String> {
    let known_hosts_path = ssh_known_hosts_path()?;
    let (rule, eff, jump_eff) = with_vault(|s| {
        let rule = s
            .list_tunnels()
            .map_err(|e| e.to_string())?
            .into_iter()
            .find(|t| t.id == tunnel_id)
            .ok_or_else(|| "Không tìm thấy Tunnel".to_string())?;
        let host = s
            .get_host(&rule.host_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Không tìm thấy Host cho Tunnel".to_string())?;
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
        Ok((rule, eff, jump_eff))
    })?;

    state().rt.block_on(async {
        // Reuse an active SSH handle for the same host if available
        let existing_ssh = {
            let sessions = state().sessions.lock().await;
            sessions
                .values()
                .find(|s| s.host_id.as_deref() == Some(&rule.host_id))
                .and_then(|s| s.ssh.clone())
        };
        let ssh = match existing_ssh {
            Some(h) => h,
            None => Arc::new(
                connect_ssh_client(&eff, jump_eff.as_ref(), &known_hosts_path)
                    .await
                    .map_err(|e| e.to_string())?,
            ),
        };
        let active = start_ssh_tunnel(rule.clone(), ssh)
            .await
            .map_err(|e| e.to_string())?;
        let status = active.status().await.into();
        state().tunnels.lock().await.insert(rule.id, active);
        Ok(status)
    })
}

pub fn stop_tunnel_by_id(tunnel_id: String) -> Result<(), String> {
    state().rt.block_on(async {
        let tunnel = state().tunnels.lock().await.remove(&tunnel_id);
        if let Some(mut tunnel) = tunnel {
            tunnel.stop_and_wait().await;
        }
        Ok(())
    })
}

pub fn list_tunnel_statuses() -> Result<Vec<TunnelStatusDto>, String> {
    state().rt.block_on(async {
        let guard = state().tunnels.lock().await;
        let mut out = Vec::with_capacity(guard.len());
        for t in guard.values() {
            out.push(t.status().await.into());
        }
        Ok(out)
    })
}

pub fn poll_session_metrics(session_id: String) -> Result<HostMetricsDto, String> {
    state().rt.block_on(async {
        let (ssh, prev_cpu) = {
            let guard = state().sessions.lock().await;
            let sess = guard
                .get(&session_id)
                .ok_or_else(|| "Phiên không tồn tại".to_string())?;
            let ssh = sess
                .ssh
                .clone()
                .ok_or_else(|| "Chỉ hỗ trợ giám sát /proc trên kết nối SSH Linux".to_string())?;
            (ssh, sess.prev_cpu)
        };
        let raw = exec_ssh_command(&ssh, PROC_PROBE_SCRIPT, Duration::from_secs(5))
            .await
            .map_err(|e| e.to_string())?;
        let (metrics, next_cpu) = parse_proc_probe_output(&raw, prev_cpu);
        if let Some(sess) = state().sessions.lock().await.get_mut(&session_id) {
            sess.prev_cpu = Some(next_cpu);
        }
        Ok(metrics.into())
    })
}

pub fn suggest_command_ghost(prefix: String) -> Result<Option<String>, String> {
    with_vault(|s| {
        let hist = s.list_command_history(300).map_err(|e| e.to_string())?;
        Ok(suggest_ghost_text(&prefix, &hist))
    })
}

pub fn ai_draft_command(
    endpoint_url: String,
    api_key: Option<String>,
    model: String,
    prompt: String,
    os_hint: String,
    shell_hint: String,
) -> Result<AiDraftDto, String> {
    state().rt.block_on(async {
        generate_ai_command(
            &endpoint_url,
            api_key.as_deref(),
            &model,
            &prompt,
            &os_hint,
            &shell_hint,
        )
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
    })
}

pub fn send_wol(mac: String, broadcast_addr: String) -> Result<(), String> {
    state().rt.block_on(async {
        send_wake_on_lan(&mac, &broadcast_addr)
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn ping_tcp_ms(host: String, port: u16) -> Result<u64, String> {
    state()
        .rt
        .block_on(async { measure_tcp_latency_ms(&host, port).await.map_err(|e| e.to_string()) })
}
