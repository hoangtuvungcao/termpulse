use crate::api::dto::{ImportResultDto, VaultStatusDto};
use crate::state::{state, with_vault};
use core_import::{
    explain_ssh_directive, export_ssh_config, import_csv, import_putty_reg, import_ssh_config,
};
use core_vault::VaultStore;
use std::path::PathBuf;

pub fn vault_init_path(db_path: String) -> Result<VaultStatusDto, String> {
    let path = PathBuf::from(&db_path);
    let store = VaultStore::open(&path).map_err(|e| e.to_string())?;
    let initialized = store.is_initialized().map_err(|e| e.to_string())?;
    let unlocked = store.is_unlocked();

    let mut path_guard = state().vault_path.lock().map_err(|_| "Lock error".to_string())?;
    let mut vault_guard = state().vault.lock().map_err(|_| "Lock error".to_string())?;
    core_transport::host_keys::cancel_pending().map_err(|e| e.to_string())?;
    super::remote_desktop_api::close_all_remote_desktop_sessions()?;
    *path_guard = Some(path);
    *vault_guard = Some(store);

    Ok(VaultStatusDto {
        initialized,
        unlocked,
        db_path,
    })
}

pub fn vault_status() -> Result<VaultStatusDto, String> {
    let path_str = state()
        .vault_path
        .lock()
        .map_err(|_| "Lock error".to_string())?
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();

    let guard = state().vault.lock().map_err(|_| "Lock error".to_string())?;
    if let Some(store) = guard.as_ref() {
        Ok(VaultStatusDto {
            initialized: store.is_initialized().map_err(|e| e.to_string())?,
            unlocked: store.is_unlocked(),
            db_path: path_str,
        })
    } else {
        Ok(VaultStatusDto {
            initialized: false,
            unlocked: false,
            db_path: path_str,
        })
    }
}

pub fn vault_unlock(master_password: String) -> Result<VaultStatusDto, String> {
    if master_password.trim().is_empty() {
        return Err("Mật khẩu chính không được để trống".into());
    }
    let path_str = state()
        .vault_path
        .lock()
        .map_err(|_| "Lock error".to_string())?
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();

    with_vault(|store| {
        store.unlock(&master_password).map_err(|e| e.to_string())?;
        Ok(VaultStatusDto {
            initialized: true,
            unlocked: true,
            db_path: path_str,
        })
    })
}

pub fn vault_lock() -> Result<(), String> {
    with_vault(|store| {
        core_transport::host_keys::cancel_pending().map_err(|e| e.to_string())?;
        super::remote_desktop_api::close_all_remote_desktop_sessions()?;
        store.lock();
        Ok(())
    })
}

pub fn vault_export_json(include_secrets: bool) -> Result<String, String> {
    with_vault(|store| store.export_json(include_secrets).map_err(|e| e.to_string()))
}

pub fn vault_import_json(json_str: String) -> Result<usize, String> {
    with_vault(|store| store.import_json(&json_str).map_err(|e| e.to_string()))
}

pub fn import_ssh_config_text(content: String) -> Result<ImportResultDto, String> {
    let bundle = import_ssh_config(&content);
    with_vault(|store| {
        for ident in &bundle.identities {
            store.upsert_identity(ident).map_err(|e| e.to_string())?;
        }
        for host in &bundle.hosts {
            store.upsert_host(host).map_err(|e| e.to_string())?;
        }
        Ok(ImportResultDto {
            hosts_imported: bundle.hosts.len(),
            identities_imported: bundle.identities.len(),
            warnings: bundle.warnings,
        })
    })
}

pub fn export_ssh_config_text() -> Result<String, String> {
    with_vault(|store| {
        let hosts = store.list_hosts().map_err(|e| e.to_string())?;
        let idents = store.list_identities().map_err(|e| e.to_string())?;
        Ok(export_ssh_config(&hosts, &idents))
    })
}

pub fn import_csv_text(content: String) -> Result<ImportResultDto, String> {
    let bundle = import_csv(&content)?;
    with_vault(|store| {
        for ident in &bundle.identities {
            store.upsert_identity(ident).map_err(|e| e.to_string())?;
        }
        for host in &bundle.hosts {
            store.upsert_host(host).map_err(|e| e.to_string())?;
        }
        Ok(ImportResultDto {
            hosts_imported: bundle.hosts.len(),
            identities_imported: bundle.identities.len(),
            warnings: bundle.warnings,
        })
    })
}

pub fn import_putty_reg_text(content: String) -> Result<ImportResultDto, String> {
    let bundle = import_putty_reg(&content);
    with_vault(|store| {
        for ident in &bundle.identities {
            store.upsert_identity(ident).map_err(|e| e.to_string())?;
        }
        for host in &bundle.hosts {
            store.upsert_host(host).map_err(|e| e.to_string())?;
        }
        Ok(ImportResultDto {
            hosts_imported: bundle.hosts.len(),
            identities_imported: bundle.identities.len(),
            warnings: bundle.warnings,
        })
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn explain_directive(directive: String) -> Option<String> {
    explain_ssh_directive(&directive).map(|s| s.to_string())
}
