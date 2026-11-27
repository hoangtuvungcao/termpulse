use crate::state::state;
use core_transport::host_keys;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct HostKeyPromptDto {
    pub request_id: String,
    pub hostname: String,
    pub port: u16,
    pub algorithm: String,
    pub fingerprint: String,
    pub public_key: String,
    pub previous_fingerprints: Vec<String>,
    pub changed: bool,
    pub certificate_authority: bool,
    pub server_key_fingerprint: String,
    pub certificate_principals: Vec<String>,
    pub certificate_valid_until: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HostKeyRecordDto {
    pub record_id: String,
    pub hostname: String,
    pub port: u16,
    pub algorithm: String,
    pub fingerprint: String,
    pub public_key: String,
    pub certificate_authority: bool,
    pub revoked: bool,
}

fn with_scoped_path<T>(
    operation: impl FnOnce(&Path) -> Result<T, core_transport::TransportError>,
) -> Result<T, String> {
    // Keep path and unlock state stable for the entire mutation, using the
    // same path→store lock order as vault_init_path. A concurrent switch must
    // never combine the old Vault's unlocked state with the new Vault's path.
    let path = state()
        .vault_path
        .lock()
        .map_err(|_| "Vault path lock error".to_string())?;
    let vault = state()
        .vault
        .lock()
        .map_err(|_| "Vault lock error".to_string())?;
    if !vault.as_ref().is_some_and(|store| store.is_unlocked()) {
        return Err("Hãy mở khóa Vault để quản lý và xác minh host key".into());
    }
    let path = path
        .as_ref()
        .ok_or_else(|| "Vault chưa được mở".to_string())?;
    let mut scoped_path = path.as_os_str().to_os_string();
    scoped_path.push(".ssh_known_hosts");
    operation(&PathBuf::from(scoped_path)).map_err(|e| e.to_string())
}

pub fn list_host_key_prompts() -> Result<Vec<HostKeyPromptDto>, String> {
    with_scoped_path(host_keys::list_pending).map(|requests| {
        requests
            .into_iter()
            .map(|request| HostKeyPromptDto {
                request_id: request.request_id,
                hostname: request.hostname,
                port: request.port,
                algorithm: request.algorithm,
                fingerprint: request.fingerprint,
                public_key: request.public_key,
                previous_fingerprints: request.previous_fingerprints,
                changed: request.changed,
                certificate_authority: request.certificate_authority,
                server_key_fingerprint: request.server_key_fingerprint,
                certificate_principals: request.certificate_principals,
                certificate_valid_until: request.certificate_valid_until,
            })
            .collect()
    })
}

pub fn decide_host_key(
    request_id: String,
    decision: String,
    expected_fingerprint: String,
) -> Result<(), String> {
    with_scoped_path(|path| host_keys::decide(path, &request_id, &decision, &expected_fingerprint))
}

pub fn list_host_keys() -> Result<Vec<HostKeyRecordDto>, String> {
    with_scoped_path(host_keys::list_records).map(|records| {
        records
            .into_iter()
            .map(|record| HostKeyRecordDto {
                record_id: record.record_id,
                hostname: record.hostname,
                port: record.port,
                algorithm: record.algorithm,
                fingerprint: record.fingerprint,
                public_key: record.public_key,
                certificate_authority: record.certificate_authority,
                revoked: record.revoked,
            })
            .collect()
    })
}

pub fn remove_host_key(record_id: String, expected_fingerprint: String) -> Result<(), String> {
    with_scoped_path(|path| host_keys::remove_record(path, &record_id, &expected_fingerprint))
}

pub fn import_host_key(
    hostname: String,
    port: u16,
    public_key: String,
    certificate_authority: bool,
    replace_existing: bool,
    expected_fingerprint: String,
) -> Result<(), String> {
    with_scoped_path(|path| {
        host_keys::import_public_key(
            path,
            &hostname,
            port,
            &public_key,
            certificate_authority,
            replace_existing,
            &expected_fingerprint,
        )
    })
}
