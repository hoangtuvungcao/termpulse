use crate::api::dto::{
    CredentialDto, EffectiveHostDto, GroupDto, HighlightDto, HostDto, IdentityDto, ProxyDto,
    SnippetDto, TunnelDto,
};
use crate::state::with_vault;
use core_model::{
    resolve_effective_host_config, Credential, Group, HighlightRule, Host, Identity, ProxyConfig,
    Snippet, TunnelRule,
};

pub fn list_groups() -> Result<Vec<GroupDto>, String> {
    with_vault(|s| {
        Ok(s.list_groups()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_group(group: GroupDto) -> Result<(), String> {
    with_vault(|s| s.upsert_group(&Group::from(group)).map_err(|e| e.to_string()))
}

pub fn delete_group(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_group(&id).map_err(|e| e.to_string()))
}

pub fn list_credentials() -> Result<Vec<CredentialDto>, String> {
    with_vault(|s| {
        Ok(s.list_credentials()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_credential(cred: CredentialDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_credential(&Credential::from(cred))
            .map_err(|e| e.to_string())
    })
}

pub fn delete_credential(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_credential(&id).map_err(|e| e.to_string()))
}

pub fn list_identities() -> Result<Vec<IdentityDto>, String> {
    with_vault(|s| {
        Ok(s.list_identities()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_identity(identity: IdentityDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_identity(&Identity::from(identity))
            .map_err(|e| e.to_string())
    })
}

pub fn delete_identity(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_identity(&id).map_err(|e| e.to_string()))
}

pub fn list_proxies() -> Result<Vec<ProxyDto>, String> {
    with_vault(|s| {
        Ok(s.list_proxies()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_proxy(proxy: ProxyDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_proxy(&ProxyConfig::from(proxy))
            .map_err(|e| e.to_string())
    })
}

pub fn delete_proxy(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_proxy(&id).map_err(|e| e.to_string()))
}

pub fn list_hosts() -> Result<Vec<HostDto>, String> {
    with_vault(|s| {
        Ok(s.list_hosts()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_host(host: HostDto) -> Result<(), String> {
    with_vault(|s| s.upsert_host(&Host::from(host)).map_err(|e| e.to_string()))
}

pub fn delete_host(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_host(&id).map_err(|e| e.to_string()))
}

pub fn resolve_host_effective(host_id: String, global_follow_sftp: bool) -> Result<EffectiveHostDto, String> {
    with_vault(|s| {
        let host = s
            .get_host(&host_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Không tìm thấy Host".to_string())?;
        let groups = s.list_groups().map_err(|e| e.to_string())?;
        let idents = s.list_identities().map_err(|e| e.to_string())?;
        let creds = s.list_credentials().map_err(|e| e.to_string())?;
        let hosts = s.list_hosts().map_err(|e| e.to_string())?;
        let proxies = s.list_proxies().map_err(|e| e.to_string())?;
        core_model::validate_proxy_reference(&host, &groups, &proxies)?;
        Ok(resolve_effective_host_config(
            &host,
            &groups,
            &idents,
            &creds,
            &hosts,
            &proxies,
            global_follow_sftp,
        )
        .into())
    })
}

pub fn list_tunnels() -> Result<Vec<TunnelDto>, String> {
    with_vault(|s| {
        Ok(s.list_tunnels()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_tunnel(tunnel: TunnelDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_tunnel(&TunnelRule::from(tunnel))
            .map_err(|e| e.to_string())
    })
}

pub fn delete_tunnel(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_tunnel(&id).map_err(|e| e.to_string()))
}

pub fn list_snippets() -> Result<Vec<SnippetDto>, String> {
    with_vault(|s| {
        Ok(s.list_snippets()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_snippet(snippet: SnippetDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_snippet(&Snippet::from(snippet))
            .map_err(|e| e.to_string())
    })
}

pub fn delete_snippet(id: String) -> Result<(), String> {
    with_vault(|s| s.delete_snippet(&id).map_err(|e| e.to_string()))
}

pub fn list_highlights() -> Result<Vec<HighlightDto>, String> {
    with_vault(|s| {
        Ok(s.list_highlights()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

pub fn upsert_highlight(rule: HighlightDto) -> Result<(), String> {
    with_vault(|s| {
        s.upsert_highlight(&HighlightRule::from(rule))
            .map_err(|e| e.to_string())
    })
}
