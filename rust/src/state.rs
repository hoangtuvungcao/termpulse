use core_model::EnvTag;
use core_transport::{ActiveTunnel, SessionInput, SshClientHandle, TransferControl};
use core_vault::VaultStore;
use once_cell::sync::OnceCell;
use russh_sftp::client::SftpSession;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, Mutex as AsyncMutex};

pub struct ActiveSession {
    pub id: String,
    pub host_id: Option<String>,
    pub title: String,
    pub env_tag: EnvTag,
    pub cwd: String,
    pub input_tx: mpsc::Sender<SessionInput>,
    pub ssh: Option<Arc<SshClientHandle>>,
    pub sftp: Arc<AsyncMutex<Option<Arc<SftpSession>>>>,
    pub sftp_unavailable_reason: Option<String>,
    pub prev_cpu: Option<(u64, u64)>,
}

pub struct AppState {
    pub rt: Runtime,
    pub vault_path: Mutex<Option<PathBuf>>,
    pub vault: Mutex<Option<VaultStore>>,
    pub sessions: Arc<AsyncMutex<HashMap<String, ActiveSession>>>,
    pub tunnels: Arc<AsyncMutex<HashMap<String, ActiveTunnel>>>,
    pub transfers: Arc<AsyncMutex<HashMap<String, Arc<TransferControl>>>>,
}

static STATE: OnceCell<AppState> = OnceCell::new();

pub fn state() -> &'static AppState {
    STATE.get_or_init(|| {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("termpulse-tokio")
            .build()
            .expect("Failed to initialize tokio runtime");
        AppState {
            rt,
            vault_path: Mutex::new(None),
            vault: Mutex::new(None),
            sessions: Arc::new(AsyncMutex::new(HashMap::new())),
            tunnels: Arc::new(AsyncMutex::new(HashMap::new())),
            transfers: Arc::new(AsyncMutex::new(HashMap::new())),
        }
    })
}

pub fn with_vault<F, R>(f: F) -> Result<R, String>
where
    F: FnOnce(&mut VaultStore) -> Result<R, String>,
{
    let mut guard = state()
        .vault
        .lock()
        .map_err(|_| "Vault lock poisoned".to_string())?;
    let store = guard
        .as_mut()
        .ok_or_else(|| "Vault chưa được mở hoặc chưa khởi tạo đường dẫn".to_string())?;
    f(store)
}

