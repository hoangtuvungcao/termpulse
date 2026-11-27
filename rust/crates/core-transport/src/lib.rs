use core_model::{
    Credential, CredentialKind, EffectiveHostConfig, ProxyConfig, ProxyKind, TunnelKind, TunnelRule,
};
#[cfg(test)]
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use russh::client::{self, Handle};
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{ChannelMsg, Pty};
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{mpsc, watch, Mutex};

pub mod host_keys;
mod http_proxy;

pub mod serial;
pub use serial::{connect_serial, list_serial_ports, serial_supported, SerialConfig, SerialPortInfo};

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("Kết nối thất bại: {0}")]
    Connect(String),
    #[error("SSH_CONNECTION: {0}")]
    SshConnection(String),
    #[error("SSH_CONNECT_TIMEOUT: {0}s")]
    SshConnectTimeout(u64),
    #[error("SSH_HANDSHAKE: {0}")]
    SshHandshake(String),
    #[error("SSH_HANDSHAKE_TIMEOUT: {0}")]
    SshHandshakeTimeout(&'static str),
    #[error("SSH_AUTHENTICATION_REJECTED: Server rejected the supplied SSH authentication")]
    AuthFailed,
    #[error("SSH_AUTHENTICATION_REQUIRED: Server requires SSH credentials")]
    AuthRequired,
    #[error("SSH_AUTHENTICATION_ADDITIONAL: Server requires further authentication")]
    AuthAdditionalRequired,
    #[error("SSH_AUTHENTICATION_TIMEOUT: {target}, {}s", timeout.as_secs())]
    AuthTimeout { target: &'static str, timeout: Duration },
    #[error("SSH_AUTHENTICATION_INTERRUPTED: {0}")]
    AuthInterrupted(String),
    #[error("SSH_PRIVATE_KEY: {0}")]
    SshPrivateKey(String),
    #[error("SFTP không khả dụng trên server. Hãy yêu cầu quản trị viên bật SFTP subsystem: {0}")]
    SftpUnavailable(String),
    #[error("Lỗi SFTP: {0}")]
    Sftp(String),
    #[error("Lỗi IO: {0}")]
    Io(#[from] std::io::Error),
    #[error("Lỗi phiên: {0}")]
    Session(String),
    #[error("Không xác minh được danh tính máy chủ SSH: {0}")]
    HostKey(String),
    #[error("Lỗi SSH: {0}")]
    Ssh(#[from] russh::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SftpEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub permissions: u32,
    pub modified: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostMetrics {
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunnelStatus {
    pub tunnel_id: String,
    pub running: bool,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub active_conns: u64,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub enum SessionInput {
    Bytes(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Close,
}

#[derive(Debug, Clone)]
pub enum SessionOutput {
    Data(Vec<u8>),
    Closed(Option<String>),
}

#[derive(Clone)]
pub struct ForwardedTarget {
    host: String,
    port: u16,
    stopped: watch::Receiver<bool>,
    bytes_in: Arc<AtomicU64>,
    bytes_out: Arc<AtomicU64>,
    active_conns: Arc<AtomicU64>,
    last_error: Arc<Mutex<Option<String>>>,
}

pub type ForwardedMap = Arc<Mutex<HashMap<(String, u32), ForwardedTarget>>>;

pub struct SshClientHandler {
    accepted_fingerprint: Arc<Mutex<Option<String>>>,
    forwarded_map: ForwardedMap,
    hostname: String,
    port: u16,
    known_hosts_path: PathBuf,
    trust_epoch: u64,
}

impl client::Handler for SshClientHandler {
    type Error = TransportError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let fingerprint = host_keys::verify_server_key_at_epoch(
            &self.known_hosts_path, &self.hostname, self.port, server_public_key, self.trust_epoch,
        ).await?;
        *self.accepted_fingerprint.lock().await = Some(fingerprint);
        Ok(true)
    }

    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: russh::client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let target = self.forwarded_map.lock().await
            .get(&(connected_address.to_string(), connected_port)).cloned();
        if let Some(mut target) = target.filter(|target| !*target.stopped.borrow()) {
            reply.accept().await;
            tokio::spawn(async move {
                target.active_conns.fetch_add(1, Ordering::Relaxed);
                tokio::select! {
                    _ = target.stopped.changed() => {},
                    result = async {
                    let mut local = TcpStream::connect((target.host.as_str(), target.port)).await?;
                    let mut stream = channel.into_stream();
                    let (incoming, outgoing) = tokio::io::copy_bidirectional(&mut stream, &mut local).await?;
                    target.bytes_in.fetch_add(incoming, Ordering::Relaxed);
                    target.bytes_out.fetch_add(outgoing, Ordering::Relaxed);
                    Ok::<_, std::io::Error>(())
                    } => {
                        if let Err(error) = result {
                            *target.last_error.lock().await = Some(error.to_string());
                        }
                    }
                }
                target.active_conns.fetch_sub(1, Ordering::Relaxed);
            });
        } else {
            reply.reject(russh::ChannelOpenFailure::AdministrativelyProhibited).await;
        }
        Ok(())
    }
}

pub struct SshClientHandle {
    pub handle: Arc<Mutex<Handle<SshClientHandler>>>,
    pub forwarded_map: ForwardedMap,
    pub server_fingerprint: Option<String>,
}

async fn connect_tcp_with_proxy(
    hostname: &str,
    port: u16,
    proxy: Option<&ProxyConfig>,
    proxy_credential: Option<&Credential>,
) -> Result<http_proxy::ProxyStream, TransportError> {
    if hostname.is_empty() || port == 0 || hostname.chars().any(|ch| ch.is_control() || ch.is_whitespace()) {
        return Err(TransportError::Connect("Tên máy chủ hoặc cổng không hợp lệ".into()));
    }
    let authentication = proxy.map(|proxy| proxy_authentication(proxy, proxy_credential)).transpose()?;
    if proxy.is_some_and(|proxy| proxy.host.trim().is_empty() || proxy.port == 0) {
        return Err(TransportError::Connect("Địa chỉ hoặc cổng proxy không hợp lệ".into()));
    }
    let timeout = if proxy.is_some_and(|p| p.auth_method.as_deref() == Some("kerberos")) { 90 } else { 15 };
    tokio::time::timeout(Duration::from_secs(timeout), async {
        match proxy {
        None => TcpStream::connect((hostname, port))
            .await
            .map(|s| Box::new(s) as http_proxy::ProxyStream)
            .map_err(|e| TransportError::Connect(format!("{hostname}:{port} — {e}"))),
        Some(p) => match p.kind {
            ProxyKind::Socks5 => {
                if let Some(ProxyAuthentication::Password { username, password }) = authentication.as_ref() {
                    return connect_socks5_authenticated(p, hostname, port, username, password).await.map(|s| Box::new(s) as http_proxy::ProxyStream);
                }
                let s = tokio_socks::tcp::Socks5Stream::connect(
                    (p.host.as_str(), p.port), (hostname, port),
                ).await
                .map_err(|e| TransportError::Connect(format!("SOCKS5 {}:{} — {e}", p.host, p.port)))?;
                Ok(Box::new(s.into_inner()) as http_proxy::ProxyStream)
            }
            ProxyKind::Socks4 => {
                if let Some(ProxyAuthentication::UserId(username)) = authentication.as_ref() {
                    return connect_socks4_with_userid(p, hostname, port, username).await.map(|s| Box::new(s) as http_proxy::ProxyStream);
                }
                let s = tokio_socks::tcp::Socks4Stream::connect(
                    (p.host.as_str(), p.port), (hostname, port),
                ).await
                .map_err(|e| TransportError::Connect(format!("SOCKS4 {}:{} — {e}", p.host, p.port)))?;
                Ok(Box::new(s.into_inner()) as http_proxy::ProxyStream)
            }
            ProxyKind::HttpConnect => {
                http_proxy::connect(p, hostname, port, authentication.as_ref().unwrap_or(&ProxyAuthentication::None)).await
            }
        },
        }
    }).await.map_err(|_| TransportError::SshConnectTimeout(timeout))?
        .map_err(|error| match error {
            TransportError::Connect(detail) => TransportError::SshConnection(detail),
            other => other,
        })
}

async fn connect_socks4_with_userid(
    proxy: &ProxyConfig,
    hostname: &str,
    port: u16,
    username: &str,
) -> Result<TcpStream, TransportError> {
    let failure = |message: &str| TransportError::Connect(format!("SOCKS4: {message}"));
    let mut request = vec![4, 1];
    request.extend_from_slice(&port.to_be_bytes());
    let domain = match hostname.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(address)) => {
            request.extend_from_slice(&address.octets());
            false
        }
        Ok(std::net::IpAddr::V6(_)) => return Err(failure("giao thức không hỗ trợ IPv6; hãy chọn SOCKS5 hoặc HTTP CONNECT")),
        Err(_) => {
            if hostname.len() > 255 { return Err(failure("tên máy chủ dài quá 255 byte")); }
            request.extend_from_slice(&[0, 0, 0, 1]);
            true
        }
    };
    request.extend_from_slice(username.as_bytes());
    request.push(0);
    if domain {
        request.extend_from_slice(hostname.as_bytes());
        request.push(0);
    }
    let mut stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    stream.write_all(&request).await?;
    let mut response = [0; 8];
    stream.read_exact(&mut response).await?;
    if response[0] != 0 || response[1] != 90 {
        return Err(failure(&format!("proxy từ chối CONNECT/USERID (mã {})", response[1])));
    }
    Ok(stream)
}

async fn connect_socks5_authenticated(
    proxy: &ProxyConfig,
    hostname: &str,
    port: u16,
    username: &str,
    password: &str,
) -> Result<TcpStream, TransportError> {
    let failure = |message: &str| TransportError::Connect(format!("SOCKS5: {message}"));
    let mut stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    // Offer only username/password authentication. Do not silently downgrade a
    // configured authenticated proxy to the no-auth method.
    stream.write_all(&[5, 1, 2]).await?;
    let mut response = [0; 2];
    stream.read_exact(&mut response).await?;
    if response != [5, 2] {
        return Err(failure("proxy không chấp nhận xác thực tên đăng nhập/mật khẩu"));
    }
    let mut authentication = vec![1, username.len() as u8];
    authentication.extend_from_slice(username.as_bytes());
    authentication.push(password.len() as u8);
    authentication.extend_from_slice(password.as_bytes());
    stream.write_all(&authentication).await?;
    stream.read_exact(&mut response).await?;
    if response != [1, 0] {
        return Err(failure("xác thực proxy bị từ chối"));
    }
    let mut request = vec![5, 1, 0];
    match hostname.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(address)) => {
            request.push(1);
            request.extend_from_slice(&address.octets());
        }
        Ok(std::net::IpAddr::V6(address)) => {
            request.push(4);
            request.extend_from_slice(&address.octets());
        }
        Err(_) => {
            if hostname.len() > 255 { return Err(failure("tên máy chủ dài quá 255 byte")); }
            request.extend_from_slice(&[3, hostname.len() as u8]);
            request.extend_from_slice(hostname.as_bytes());
        }
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await?;
    let mut header = [0; 4];
    stream.read_exact(&mut header).await?;
    if header[0] != 5 || header[2] != 0 {
        return Err(failure("phản hồi CONNECT không hợp lệ"));
    }
    if header[1] != 0 {
        return Err(failure(&format!("proxy từ chối CONNECT (mã {})", header[1])));
    }
    let address_length = match header[3] {
        1 => 4,
        4 => 16,
        3 => stream.read_u8().await? as usize,
        _ => return Err(failure("loại địa chỉ phản hồi không hợp lệ")),
    };
    let mut bound_address_and_port = vec![0; address_length + 2];
    stream.read_exact(&mut bound_address_and_port).await?;
    Ok(stream)
}

enum ProxyAuthentication<'a> {
    None,
    UserId(&'a str),
    Password { username: &'a str, password: &'a str },
}

fn proxy_authentication<'a>(
    proxy: &'a ProxyConfig,
    credential: Option<&'a Credential>,
) -> Result<ProxyAuthentication<'a>, TransportError> {
    let error = |message: &str| TransportError::Connect(message.to_string());
    let method = http_proxy::auth_method(proxy)?;
    let username = proxy.username.as_deref();
    if username.is_some_and(|username| username.trim().is_empty() || username.chars().any(char::is_control)) {
        return Err(error("Tên đăng nhập proxy không hợp lệ"));
    }
    if proxy.kind == ProxyKind::Socks4 {
        if proxy.credential_id.is_some() {
            return Err(error("SOCKS4 chỉ hỗ trợ USERID, không hỗ trợ mật khẩu. Hãy bỏ Credential hoặc chọn SOCKS5/HTTP CONNECT."));
        }
        if username.is_some_and(|username| username.len() > 255) {
            return Err(error("SOCKS4 yêu cầu USERID dài từ 1 đến 255 byte"));
        }
        return Ok(username.map(ProxyAuthentication::UserId).unwrap_or(ProxyAuthentication::None));
    }
    if proxy.kind == ProxyKind::HttpConnect && method == "none" {
        if proxy.username.is_some() || proxy.credential_id.is_some() {
            return Err(error("Proxy chọn Không xác thực nhưng vẫn chứa username/Credential; hãy bỏ chúng hoặc chọn phương thức xác thực"));
        }
        return Ok(ProxyAuthentication::None);
    }
    let Some(credential_id) = proxy.credential_id.as_deref() else {
        return if username.is_some() || (proxy.kind == ProxyKind::HttpConnect && method != "none") {
            Err(error("Proxy có tên đăng nhập nhưng chưa chọn Credential mật khẩu"))
        } else {
            Ok(ProxyAuthentication::None)
        };
    };
    let credential = credential.filter(|credential| credential.id == credential_id)
        .ok_or_else(|| error("Không tìm thấy thông tin xác thực đã chọn cho proxy. Hãy chọn lại Credential của proxy."))?;
    let username = username.ok_or_else(|| error("Proxy có Credential nhưng chưa có tên đăng nhập. Hãy bổ sung username của proxy."))?;
    if credential.kind != CredentialKind::Password {
        return Err(error("Proxy cần Credential loại mật khẩu; SSH key và token không được dùng thay mật khẩu proxy"));
    }
    let password = credential.secret.as_deref()
        .ok_or_else(|| error("Credential của proxy chưa có mật khẩu hoặc chưa được mở khóa"))?;
    if proxy.kind == ProxyKind::HttpConnect && method == "basic" && username.contains(':') {
        return Err(error("Tên đăng nhập HTTP CONNECT không được chứa dấu hai chấm"));
    }
    if proxy.kind == ProxyKind::Socks5
        && (username.len() > 255 || password.is_empty() || password.len() > 255)
    {
        return Err(error("SOCKS5 yêu cầu tên đăng nhập và mật khẩu có độ dài từ 1 đến 255 byte"));
    }
    Ok(ProxyAuthentication::Password { username, password })
}

/// Validate references and protocol-specific authentication before networking.
pub fn validate_proxy_credentials(
    proxy: Option<&ProxyConfig>,
    credentials: &[Credential],
) -> Result<(), TransportError> {
    if let Some(proxy) = proxy {
        let credential = proxy.credential_id.as_deref()
            .and_then(|id| credentials.iter().find(|credential| credential.id == id));
        proxy_authentication(proxy, credential)?;
    }
    Ok(())
}

async fn authenticate_ssh(
    handle: &mut Handle<SshClientHandler>,
    username: &str,
    credential: Option<&Credential>,
) -> Result<(), TransportError> {
    let Some(cred) = credential else {
        let res = handle
            .authenticate_none(username)
            .await
            .map_err(|e| TransportError::AuthInterrupted(e.to_string()))?;
        return check_ssh_auth_result(res, russh::MethodKind::None);
    };

    match cred.kind {
        CredentialKind::Password => {
            let pw = cred.secret.as_deref().unwrap_or("");
            let res = handle
                .authenticate_password(username, pw)
                .await
                .map_err(|e| TransportError::AuthInterrupted(e.to_string()))?;
            check_ssh_auth_result(res, russh::MethodKind::Password)
        }
        CredentialKind::SshKey => {
            let key_pem = cred
                .secret
                .as_deref()
                .ok_or_else(|| TransportError::SshPrivateKey("Missing private key".into()))?;
            let key_pair = decode_secret_key(key_pem, cred.passphrase.as_deref())
                .map_err(|e| TransportError::SshPrivateKey(e.to_string()))?;
            let hash_alg = handle
                .best_supported_rsa_hash()
                .await
                .map_err(|e| TransportError::AuthInterrupted(e.to_string()))?
                .flatten();
            let res = handle
                .authenticate_publickey(
                    username,
                    PrivateKeyWithHashAlg::new(Arc::new(key_pair), hash_alg),
                )
                .await
                .map_err(|e| TransportError::AuthInterrupted(e.to_string()))?;
            check_ssh_auth_result(res, russh::MethodKind::PublicKey)
        }
        _ => {
            let res = handle
                .authenticate_none(username)
                .await
                .map_err(|e| TransportError::AuthInterrupted(e.to_string()))?;
            check_ssh_auth_result(res, russh::MethodKind::None)
        }
    }
}

fn check_ssh_auth_result(
    result: client::AuthResult,
    method: russh::MethodKind,
) -> Result<(), TransportError> {
    match result {
        client::AuthResult::Success => Ok(()),
        client::AuthResult::Failure { partial_success: true, .. } => {
            Err(TransportError::AuthAdditionalRequired)
        }
        // russh also returns an empty Failure when its reply channel closes.
        // Without a server response we cannot claim that credentials were bad.
        client::AuthResult::Failure { remaining_methods, .. } if remaining_methods.is_empty() => {
            Err(TransportError::AuthInterrupted("No authentication result received before the SSH connection closed".into()))
        }
        client::AuthResult::Failure { .. } if method == russh::MethodKind::None => {
            Err(TransportError::AuthRequired)
        }
        // The remaining method list is not proof that the attempted method
        // was unsupported: servers may remove a method after a bad password.
        client::AuthResult::Failure { .. } => Err(TransportError::AuthFailed),
    }
}

async fn authenticate_ssh_with_timeout(
    handle: &mut Handle<SshClientHandler>,
    username: &str,
    credential: Option<&Credential>,
    target: &'static str,
    timeout: Duration,
) -> Result<(), TransportError> {
    tokio::time::timeout(timeout, authenticate_ssh(handle, username, credential))
        .await.map_err(|_| TransportError::AuthTimeout { target, timeout })?
}

pub async fn connect_ssh_client(
    eff: &EffectiveHostConfig,
    jump_eff: Option<&EffectiveHostConfig>,
    known_hosts_path: &Path,
) -> Result<SshClientHandle, TransportError> {
    connect_ssh_client_with_auth_timeout(eff, jump_eff, known_hosts_path, Duration::from_secs(15)).await
}

async fn connect_ssh_client_with_auth_timeout(
    eff: &EffectiveHostConfig,
    jump_eff: Option<&EffectiveHostConfig>,
    known_hosts_path: &Path,
    auth_timeout: Duration,
) -> Result<SshClientHandle, TransportError> {
    // Capture before TCP/proxy/jump establishment, not only when a host key is
    // finally received. Vault lock also invalidates a still-negotiating socket.
    let trust_epoch = host_keys::current_epoch();
    let mut cfg = client::Config {
        nodelay: true,
        keepalive_interval: Some(Duration::from_secs(25)),
        keepalive_max: 3,
        ..Default::default()
    };
    cfg.window_size = 2 * 1024 * 1024;
    cfg.preferred.host_key_certificates = cfg.preferred.key.clone();
    let cfg = Arc::new(cfg);

    let fp = Arc::new(Mutex::new(None));
    let fwd_map = Arc::new(Mutex::new(HashMap::new()));
    let handler = SshClientHandler {
        accepted_fingerprint: fp.clone(),
        forwarded_map: fwd_map.clone(),
        hostname: eff.host.hostname.clone(),
        port: eff.host.port,
        known_hosts_path: known_hosts_path.to_path_buf(),
        trust_epoch,
    };

    let mut handle = if let Some(jump) = jump_eff {
        let jump_tcp =
            connect_tcp_with_proxy(&jump.host.hostname, jump.host.port, jump.proxy.as_ref(), jump.proxy_credential.as_ref()).await?;
        let jump_fp = Arc::new(Mutex::new(None));
        let jump_handler = SshClientHandler {
            accepted_fingerprint: jump_fp,
            forwarded_map: Arc::new(Mutex::new(HashMap::new())),
            hostname: jump.host.hostname.clone(),
            port: jump.host.port,
            known_hosts_path: known_hosts_path.to_path_buf(),
            trust_epoch,
        };
        let mut jump_handle = tokio::time::timeout(host_keys::HANDSHAKE_TIMEOUT, client::connect_stream(cfg.clone(), jump_tcp, jump_handler))
            .await.map_err(|_| TransportError::SshHandshakeTimeout("JumpHost"))?
            .map_err(|e| TransportError::SshHandshake(format!("JumpHost: {e}")))?;
        host_keys::ensure_epoch(trust_epoch)?;
        let jump_user = jump
            .identity
            .as_ref()
            .map(|i| i.username.as_str())
            .unwrap_or("root");
        authenticate_ssh_with_timeout(&mut jump_handle, jump_user, jump.credential.as_ref(), "JumpHost", auth_timeout).await?;
        let tunnel_ch = tokio::time::timeout(Duration::from_secs(15), jump_handle
            .channel_open_direct_tcpip(&eff.host.hostname, eff.host.port as u32, "127.0.0.1", 0))
            .await.map_err(|_| TransportError::Connect("Mở kênh JumpHost hết thời gian (15 giây)".into()))?
            .map_err(|e| TransportError::Connect(format!("JumpHost direct-tcpip: {e}")))?;
        tokio::time::timeout(host_keys::HANDSHAKE_TIMEOUT, client::connect_stream(cfg, tunnel_ch.into_stream(), handler))
            .await.map_err(|_| TransportError::SshHandshakeTimeout("Target via JumpHost"))?
            .map_err(|e| TransportError::SshHandshake(format!("Target via JumpHost: {e}")))?
    } else {
        let tcp =
            connect_tcp_with_proxy(&eff.host.hostname, eff.host.port, eff.proxy.as_ref(), eff.proxy_credential.as_ref()).await?;
        tokio::time::timeout(host_keys::HANDSHAKE_TIMEOUT, client::connect_stream(cfg, tcp, handler))
            .await.map_err(|_| TransportError::SshHandshakeTimeout("SSH"))?
            .map_err(|e| TransportError::SshHandshake(e.to_string()))?
    };

    host_keys::ensure_epoch(trust_epoch)?;
    let user = eff
        .identity
        .as_ref()
        .map(|i| i.username.as_str())
        .unwrap_or("root");
    authenticate_ssh_with_timeout(&mut handle, user, eff.credential.as_ref(), "SSH", auth_timeout).await?;
    host_keys::ensure_epoch(trust_epoch)?;
    let fingerprint = fp.lock().await.clone();

    Ok(SshClientHandle {
        handle: Arc::new(Mutex::new(handle)),
        forwarded_map: fwd_map,
        server_fingerprint: fingerprint,
    })
}

async fn wait_for_ssh_request(
    channel: &mut russh::Channel<client::Msg>,
    request: &str,
    early_output: &mut Vec<u8>,
) -> Result<(), TransportError> {
    let accepted = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Success) => return Ok(()),
                Some(ChannelMsg::Failure) => return Err(TransportError::Session(format!(
                    "Server từ chối yêu cầu {request}"
                ))),
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                    if early_output.len() + data.len() > 64 * 1024 {
                        return Err(TransportError::Session(format!(
                            "Server gửi quá nhiều dữ liệu khi thiết lập {request}"
                        )));
                    }
                    early_output.extend_from_slice(&data);
                }
                Some(ChannelMsg::Close) | Some(ChannelMsg::Eof)
                | Some(ChannelMsg::ExitStatus { .. }) | Some(ChannelMsg::ExitSignal { .. }) | None => {
                    return Err(TransportError::Session(format!(
                        "Kênh SSH đóng trước khi chấp nhận yêu cầu {request}"
                    )));
                }
                _ => {}
            }
        }
    }).await.unwrap_or_else(|_| Err(TransportError::Session(format!(
        "Server không phản hồi yêu cầu {request} trong 5 giây"
    ))));
    if accepted.is_err() {
        let _ = channel.close().await;
    }
    accepted
}

/// Opens an interactive PTY shell over an authenticated `SshClientHandle`.
pub async fn spawn_ssh_shell(
    ssh: &SshClientHandle,
    cols: u16,
    rows: u16,
    startup_cmd: Option<String>,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    spawn_ssh_shell_with_env(ssh, cols, rows, startup_cmd, &BTreeMap::new()).await
}

pub async fn spawn_ssh_shell_with_env(
    ssh: &SshClientHandle,
    cols: u16,
    rows: u16,
    startup_cmd: Option<String>,
    env: &BTreeMap<String, String>,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    for (name, value) in env {
        let mut chars = name.chars();
        if !chars.next().is_some_and(|character| character.is_ascii_alphabetic() || character == '_')
            || !chars.all(|character| character.is_ascii_alphanumeric() || character == '_')
            || value.contains('\0')
        {
            return Err(TransportError::Session(format!("Biến môi trường không hợp lệ: {name:?}")));
        }
    }
    let mut channel = {
        let guard = ssh.handle.lock().await;
        guard
            .channel_open_session()
            .await
            .map_err(|e| TransportError::Session(e.to_string()))?
    };

    let mut early_output = Vec::new();
    for (name, value) in env {
        channel.set_env(true, name, value).await
            .map_err(|error| TransportError::Session(format!("Không gửi được biến môi trường {name}: {error}")))?;
        let accepted = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match channel.wait().await {
                    Some(ChannelMsg::Success) => return Ok(()),
                    Some(ChannelMsg::Failure) => return Err(TransportError::Session(format!(
                        "Server từ chối biến môi trường {name}. Hãy kiểm tra cấu hình AcceptEnv của SSH server."
                    ))),
                    Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                        if early_output.len() + data.len() > 64 * 1024 {
                            return Err(TransportError::Session("Server gửi quá nhiều dữ liệu khi thiết lập môi trường".into()));
                        }
                        early_output.extend_from_slice(&data);
                    }
                    Some(ChannelMsg::Close) | Some(ChannelMsg::Eof) | None => return Err(
                        TransportError::Session(format!("Kênh SSH đóng khi thiết lập biến môi trường {name}"))
                    ),
                    _ => {}
                }
            }
        }).await.unwrap_or_else(|_| Err(TransportError::Session(format!(
            "Server không phản hồi yêu cầu biến môi trường {name} trong 5 giây. Hãy kiểm tra AcceptEnv."
        ))));
        if let Err(error) = accepted {
            let _ = channel.close().await;
            return Err(error);
        }
    }

    channel
        .request_pty(
            true,
            "xterm-256color",
            cols as u32,
            rows as u32,
            0,
            0,
            &[(Pty::ECHO, 1)],
        )
        .await
        .map_err(|e| TransportError::Session(e.to_string()))?;
    wait_for_ssh_request(&mut channel, "PTY", &mut early_output).await?;

    channel
        .request_shell(true)
        .await
        .map_err(|e| TransportError::Session(e.to_string()))?;
    wait_for_ssh_request(&mut channel, "shell", &mut early_output).await?;

    if let Some(cmd) = startup_cmd.filter(|s| !s.trim().is_empty()) {
        let line = format!("{cmd}\n");
        if let Err(error) = channel.data(line.as_bytes()).await {
            let _ = channel.close().await;
            return Err(TransportError::Session(format!("Không gửi được lệnh khởi động SSH: {error}")));
        }
    }

    let (in_tx, mut in_rx) = mpsc::channel::<SessionInput>(256);
    let (out_tx, out_rx) = mpsc::channel::<SessionOutput>(256);
    if !early_output.is_empty() {
        let _ = out_tx.try_send(SessionOutput::Data(early_output));
    }

    let (mut read_half, write_half) = channel.split();

    tokio::spawn(async move {
        let out_tx_in = out_tx.clone();
        let read_task = tokio::spawn(async move {
            while let Some(msg) = read_half.wait().await {
                match msg {
                    ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                        if out_tx.send(SessionOutput::Data(data.to_vec())).await.is_err() {
                            break;
                        }
                    }
                    ChannelMsg::Eof | ChannelMsg::Close => {
                        let _ = out_tx.send(SessionOutput::Closed(None)).await;
                        break;
                    }
                    _ => {}
                }
            }
            let _ = out_tx.send(SessionOutput::Closed(None)).await;
        });

        while let Some(ev) = in_rx.recv().await {
            match ev {
                SessionInput::Bytes(bytes) => {
                    if let Err(e) = write_half.data(&bytes[..]).await {
                        let _ = out_tx_in.send(SessionOutput::Closed(Some(e.to_string()))).await;
                        break;
                    }
                }
                SessionInput::Resize { cols, rows } => {
                    let _ = write_half
                        .window_change(cols as u32, rows as u32, 0, 0)
                        .await;
                }
                SessionInput::Close => {
                    let _ = write_half.eof().await;
                    let _ = write_half.close().await;
                    break;
                }
            }
        }
        read_task.abort();
    });

    Ok((in_tx, out_rx))
}

/// Executes a short command on an isolated exec channel and returns stdout.
pub async fn exec_ssh_command(
    ssh: &SshClientHandle,
    command: &str,
    timeout: Duration,
) -> Result<String, TransportError> {
    let expires_at = tokio::time::Instant::now() + timeout;
    let mut channel = tokio::time::timeout_at(expires_at, async {
        let guard = ssh.handle.lock().await;
        guard
            .channel_open_session()
            .await
            .map_err(|e| TransportError::Session(e.to_string()))
    }).await.map_err(|_| TransportError::Session("Command timed out".into()))??;

    let result = tokio::time::timeout_at(expires_at, async {
        channel.exec(true, command.as_bytes()).await
            .map_err(|e| TransportError::Session(e.to_string()))?;
        let mut accepted = false;
        let mut out = Vec::new();
        let mut stderr = Vec::new();
        let mut exit_status = None;
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Success) => accepted = true,
                Some(ChannelMsg::Failure) => return Err(TransportError::Session(
                    "Server từ chối thực thi lệnh SSH".into()
                )),
                Some(ChannelMsg::Data { data }) => {
                    if out.len() + data.len() > 1024 * 1024 {
                        return Err(TransportError::Session("Kết quả lệnh SSH vượt giới hạn 1 MiB".into()));
                    }
                    out.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    let remaining = (8 * 1024usize).saturating_sub(stderr.len());
                    stderr.extend_from_slice(&data[..data.len().min(remaining)]);
                }
                Some(ChannelMsg::ExitStatus { exit_status: status }) => exit_status = Some(status),
                Some(ChannelMsg::ExitSignal { signal_name, .. }) => return Err(TransportError::Session(
                    format!("Lệnh SSH bị dừng bởi tín hiệu {signal_name:?}")
                )),
                // EOF ends stdout, but a server may send exit-status afterwards.
                Some(ChannelMsg::Close) | None => break,
                _ => {}
            }
        }
        if !accepted {
            return Err(TransportError::Session("Kênh SSH đóng trước khi chấp nhận thực thi lệnh".into()));
        }
        if let Some(status) = exit_status.filter(|status| *status != 0) {
            let diagnostic = String::from_utf8_lossy(&stderr);
            let diagnostic = diagnostic.trim();
            return Err(TransportError::Session(if diagnostic.is_empty() {
                format!("Lệnh SSH kết thúc với mã lỗi {status}")
            } else {
                format!("Lệnh SSH kết thúc với mã lỗi {status}: {diagnostic}")
            }));
        }
        // Some SSH servers omit the optional exit-status request.
        Ok(String::from_utf8_lossy(&out).to_string())
    }).await.unwrap_or_else(|_| Err(TransportError::Session("Command timed out".into())));
    let _ = channel.close().await;
    result
}

// --- SFTP Client ---
pub async fn open_sftp_session(ssh: &SshClientHandle) -> Result<SftpSession, TransportError> {
    let channel = {
        let guard = ssh.handle.lock().await;
        guard
            .channel_open_session()
            .await
            .map_err(|e| TransportError::SftpUnavailable(e.to_string()))?
    };
    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|e| TransportError::SftpUnavailable(e.to_string()))?;
    SftpSession::new(channel.into_stream())
        .await
        .map_err(|e| TransportError::SftpUnavailable(e.to_string()))
}

pub async fn sftp_list_dir(sftp: &SftpSession, path: &str) -> Result<(String, Vec<SftpEntry>), TransportError> {
    let resolved = sftp
        .canonicalize(path)
        .await
        .unwrap_or_else(|_| path.to_string());
    let dir = sftp
        .read_dir(&resolved)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))?;

    let mut entries = Vec::new();
    for entry in dir {
        let name = entry.file_name();
        if name == "." || name == ".." {
            continue;
        }
        let meta = entry.metadata();
        let is_dir = meta.is_dir();
        let is_symlink = meta.is_symlink();
        let full = if resolved == "/" {
            format!("/{name}")
        } else {
            format!("{}/{name}", resolved.trim_end_matches('/'))
        };
        entries.push(SftpEntry {
            name,
            path: full,
            is_dir,
            is_symlink,
            size: meta.size.unwrap_or(0),
            permissions: meta.permissions.unwrap_or(0),
            modified: meta.mtime.unwrap_or(0) as u64,
        });
    }
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
    Ok((resolved, entries))
}

pub async fn sftp_read_bytes(sftp: &SftpSession, path: &str, max_bytes: usize) -> Result<Vec<u8>, TransportError> {
    let mut file = sftp
        .open_with_flags(path, OpenFlags::READ)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 32 * 1024];
    loop {
        let n = file.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        if buf.len() + n > max_bytes {
            return Err(TransportError::Sftp(format!(
                "File vượt quá giới hạn xem nhanh ({max_bytes} bytes)"
            )));
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    Ok(buf)
}

pub async fn sftp_write_bytes(sftp: &SftpSession, path: &str, data: &[u8]) -> Result<(), TransportError> {
    let mut file = sftp
        .open_with_flags(
            path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))?;
    file.write_all(data).await?;
    file.flush().await?;
    file.shutdown().await?;
    Ok(())
}

pub async fn sftp_mkdir(sftp: &SftpSession, path: &str) -> Result<(), TransportError> {
    sftp.create_dir(path)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))
}

pub async fn sftp_rename(sftp: &SftpSession, old_path: &str, new_path: &str) -> Result<(), TransportError> {
    sftp.rename(old_path, new_path)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))
}

pub async fn sftp_delete(sftp: &SftpSession, path: &str, is_dir: bool) -> Result<(), TransportError> {
    if is_dir {
        sftp.remove_dir(path)
            .await
            .map_err(|e| TransportError::Sftp(e.to_string()))
    } else {
        sftp.remove_file(path)
            .await
            .map_err(|e| TransportError::Sftp(e.to_string()))
    }
}

pub async fn sftp_chmod(sftp: &SftpSession, path: &str, mode: u32) -> Result<(), TransportError> {
    let attributes = russh_sftp::protocol::FileAttributes {
        permissions: Some(mode),
        ..Default::default()
    };
    sftp.set_metadata(path, attributes)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))
}

#[derive(Default)]
pub struct TransferControl {
    pub paused: AtomicBool,
    pub cancelled: AtomicBool,
}

impl TransferControl {
    async fn wait_until_ready(&self, cancelled_message: &'static str) -> Result<(), TransportError> {
        while self.paused.load(Ordering::Relaxed) {
            if self.cancelled.load(Ordering::Relaxed) {
                return Err(TransportError::Sftp(cancelled_message.into()));
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if self.cancelled.load(Ordering::Relaxed) {
            return Err(TransportError::Sftp(cancelled_message.into()));
        }
        Ok(())
    }
}

pub async fn sftp_upload_file<F>(
    sftp: &SftpSession,
    local_path: &str,
    remote_path: &str,
    ctrl: Arc<TransferControl>,
    mut on_progress: F,
) -> Result<u64, TransportError>
where
    F: FnMut(u64, u64),
{
    ctrl.wait_until_ready("Đã huỷ truyền file").await?;
    let mut local = tokio::fs::File::open(local_path).await?;
    let total = local.metadata().await?.len();
    // The transfer may have been paused/cancelled during local preflight.
    // Check again before sending a destructive remote CREATE/TRUNCATE.
    ctrl.wait_until_ready("Đã huỷ truyền file").await?;
    let mut remote = sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))?;

    let mut sent = 0u64;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        ctrl.wait_until_ready("Đã huỷ truyền file").await?;
        let n = local.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        ctrl.wait_until_ready("Đã huỷ truyền file").await?;
        remote.write_all(&buf[..n]).await?;
        sent += n as u64;
        on_progress(sent, total);
    }
    remote.flush().await?;
    remote.shutdown().await?;
    Ok(sent)
}

pub async fn sftp_download_file<F>(
    sftp: &SftpSession,
    remote_path: &str,
    local_path: &str,
    ctrl: Arc<TransferControl>,
    mut on_progress: F,
) -> Result<u64, TransportError>
where
    F: FnMut(u64, u64),
{
    ctrl.wait_until_ready("Đã huỷ tải file").await?;
    let total = sftp
        .metadata(remote_path)
        .await
        .ok()
        .and_then(|m| m.size)
        .unwrap_or(0);
    let mut remote = sftp
        .open_with_flags(remote_path, OpenFlags::READ)
        .await
        .map_err(|e| TransportError::Sftp(e.to_string()))?;
    // Remote metadata/open may await the server. Do not erase a local file
    // after the user has paused or cancelled that in-flight preflight.
    ctrl.wait_until_ready("Đã huỷ tải file").await?;
    let mut local = tokio::fs::File::create(local_path).await?;

    let mut received = 0u64;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        ctrl.wait_until_ready("Đã huỷ tải file").await?;
        let n = remote.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        ctrl.wait_until_ready("Đã huỷ tải file").await?;
        local.write_all(&buf[..n]).await?;
        received += n as u64;
        on_progress(received, total);
    }
    local.flush().await?;
    Ok(received)
}

// --- Agentless /proc Health Monitor ---
pub const PROC_PROBE_SCRIPT: &str = r#"sh -c '
awk "/^cpu /{t=\$2+\$3+\$4+\$5+\$6+\$7+\$8; i=\$5; printf \"CPU=%d,%d\n\", t, i}" /proc/stat
awk "/MemTotal:/{t=\$2} /MemAvailable:/{a=\$2} END{printf \"MEM=%d,%d\n\", (t-a)/1024, t/1024}" /proc/meminfo
df -kP / | awk "NR==2{printf \"DISK=%.2f,%.2f\n\", \$3/1048576, \$2/1048576}"
awk "NR>2 && \$1!~/lo:/{rx+=\$2; tx+=\$10} END{printf \"NET=%d,%d\n\", rx, tx}" /proc/net/dev
cut -d" " -f1-3 /proc/loadavg | awk "{printf \"LOAD=%s\n\", \$0}"
cut -d. -f1 /proc/uptime | awk "{printf \"UP=%s\n\", \$0}"
'"#;

pub fn parse_proc_probe_output(
    raw: &str,
    prev_cpu: Option<(u64, u64)>,
) -> (HostMetrics, (u64, u64)) {
    let mut cpu_total = 0u64;
    let mut cpu_idle = 0u64;
    let mut mem_used = 0u64;
    let mut mem_total = 0u64;
    let mut disk_used = 0.0f32;
    let mut disk_total = 0.0f32;
    let mut net_rx = 0u64;
    let mut net_tx = 0u64;
    let mut load_avg = String::new();
    let mut uptime_secs = 0u64;

    for line in raw.lines() {
        let l = line.trim();
        if let Some(v) = l.strip_prefix("CPU=") {
            let mut p = v.split(',');
            cpu_total = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            cpu_idle = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        } else if let Some(v) = l.strip_prefix("MEM=") {
            let mut p = v.split(',');
            mem_used = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            mem_total = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        } else if let Some(v) = l.strip_prefix("DISK=") {
            let mut p = v.split(',');
            disk_used = p.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
            disk_total = p.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
        } else if let Some(v) = l.strip_prefix("NET=") {
            let mut p = v.split(',');
            net_rx = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            net_tx = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        } else if let Some(v) = l.strip_prefix("LOAD=") {
            load_avg = v.to_string();
        } else if let Some(v) = l.strip_prefix("UP=") {
            uptime_secs = v.parse().unwrap_or(0);
        }
    }

    let cpu_percent = if let Some((pt, pi)) = prev_cpu {
        let dt = cpu_total.saturating_sub(pt);
        let di = cpu_idle.saturating_sub(pi);
        if dt > 0 {
            ((dt.saturating_sub(di)) as f32 / dt as f32) * 100.0
        } else {
            0.0
        }
    } else if cpu_total > 0 {
        ((cpu_total.saturating_sub(cpu_idle)) as f32 / cpu_total as f32) * 100.0
    } else {
        0.0
    };

    (
        HostMetrics {
            cpu_percent,
            mem_used_mb: mem_used,
            mem_total_mb: mem_total,
            disk_used_gb: disk_used,
            disk_total_gb: disk_total,
            net_rx_bytes: net_rx,
            net_tx_bytes: net_tx,
            load_avg,
            uptime_secs,
        },
        (cpu_total, cpu_idle),
    )
}

// --- Independent Tunnel Manager (-L / -R / -D) ---
pub struct ActiveTunnel {
    pub rule: TunnelRule,
    pub running: Arc<AtomicBool>,
    pub bytes_in: Arc<AtomicU64>,
    pub bytes_out: Arc<AtomicU64>,
    pub active_conns: Arc<AtomicU64>,
    pub last_error: Arc<Mutex<Option<String>>>,
    stopped: watch::Sender<bool>,
    _task: tokio::task::JoinHandle<()>,
}

impl ActiveTunnel {
    pub async fn status(&self) -> TunnelStatus {
        TunnelStatus {
            tunnel_id: self.rule.id.clone(),
            running: self.running.load(Ordering::Relaxed),
            bytes_in: self.bytes_in.load(Ordering::Relaxed),
            bytes_out: self.bytes_out.load(Ordering::Relaxed),
            active_conns: self.active_conns.load(Ordering::Relaxed),
            last_error: self.last_error.lock().await.clone(),
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::Relaxed);
        self.stopped.send_replace(true);
    }

    pub async fn stop_and_wait(&mut self) {
        self.stop();
        if tokio::time::timeout(Duration::from_secs(6), &mut self._task).await.is_err() {
            self._task.abort();
        }
    }
}

impl Drop for ActiveTunnel {
    fn drop(&mut self) {
        self.stop();
    }
}

pub async fn start_ssh_tunnel(
    mut rule: TunnelRule,
    ssh: Arc<SshClientHandle>,
) -> Result<ActiveTunnel, TransportError> {
    let running = Arc::new(AtomicBool::new(true));
    let bytes_in = Arc::new(AtomicU64::new(0));
    let bytes_out = Arc::new(AtomicU64::new(0));
    let active_conns = Arc::new(AtomicU64::new(0));
    let last_error = Arc::new(Mutex::new(None));
    let (stopped, mut stop_rx) = watch::channel(false);

    let r_flag = running.clone();
    let b_in = bytes_in.clone();
    let b_out = bytes_out.clone();
    let conns = active_conns.clone();
    let err_arc = last_error.clone();
    let rule_clone = rule.clone();

    let task = match rule.kind {
        TunnelKind::Local => {
            let listener = TcpListener::bind((rule.bind_addr.as_str(), rule.bind_port)).await?;
            rule.bind_port = listener.local_addr()?.port();
            tokio::spawn(async move {
                let target_host = rule_clone.target_host.unwrap_or_else(|| "127.0.0.1".into());
                let target_port = rule_clone.target_port.unwrap_or(80) as u32;
                while r_flag.load(Ordering::Relaxed) {
                    let accepted = tokio::select! {
                        _ = stop_rx.changed() => break,
                        accepted = listener.accept() => accepted,
                    };
                    let Ok((mut tcp, peer)) = accepted else {
                        break;
                    };
                    let ssh_c = ssh.clone();
                    let th = target_host.clone();
                    let bi = b_in.clone();
                    let bo = b_out.clone();
                    let ac = conns.clone();
                    let er = err_arc.clone();
                    let mut connection_stop = stop_rx.clone();
                    tokio::spawn(async move {
                        ac.fetch_add(1, Ordering::Relaxed);
                        tokio::select! {
                            _ = connection_stop.changed() => {},
                            _ = async {
                        let ch_res = {
                            let guard = ssh_c.handle.lock().await;
                            guard
                                .channel_open_direct_tcpip(
                                    &th,
                                    target_port,
                                    peer.ip().to_string(),
                                    peer.port() as u32,
                                )
                                .await
                        };
                        match ch_res {
                            Ok(ch) => {
                                let mut stream = ch.into_stream();
                                if let Ok((n_up, n_down)) =
                                    tokio::io::copy_bidirectional(&mut tcp, &mut stream).await
                                {
                                    bo.fetch_add(n_up, Ordering::Relaxed);
                                    bi.fetch_add(n_down, Ordering::Relaxed);
                                }
                            }
                            Err(e) => {
                                *er.lock().await = Some(e.to_string());
                            }
                        }
                            } => {},
                        }
                        ac.fetch_sub(1, Ordering::Relaxed);
                    });
                }
                r_flag.store(false, Ordering::Relaxed);
            })
        }
        TunnelKind::DynamicSocks => {
            let listener = TcpListener::bind((rule.bind_addr.as_str(), rule.bind_port)).await?;
            rule.bind_port = listener.local_addr()?.port();
            tokio::spawn(async move {
                while r_flag.load(Ordering::Relaxed) {
                    let accepted = tokio::select! {
                        _ = stop_rx.changed() => break,
                        accepted = listener.accept() => accepted,
                    };
                    let Ok((mut tcp, peer)) = accepted else {
                        break;
                    };
                    let ssh_c = ssh.clone();
                    let bi = b_in.clone();
                    let bo = b_out.clone();
                    let ac = conns.clone();
                    let er = err_arc.clone();
                    let mut connection_stop = stop_rx.clone();
                    tokio::spawn(async move {
                        ac.fetch_add(1, Ordering::Relaxed);
                        tokio::select! {
                            _ = connection_stop.changed() => {},
                            result = handle_socks5_conn(&mut tcp, peer, &ssh_c, &bi, &bo) => {
                                if let Err(error) = result {
                                    *er.lock().await = Some(error.to_string());
                                }
                            }
                        }
                        ac.fetch_sub(1, Ordering::Relaxed);
                    });
                }
                r_flag.store(false, Ordering::Relaxed);
            })
        }
        TunnelKind::Remote => {
            let bind_addr = rule.bind_addr.clone();
            let bind_port = rule.bind_port as u32;
            let t_host = rule.target_host.clone().unwrap_or_else(|| "127.0.0.1".into());
            let t_port = rule.target_port.unwrap_or(80);
            {
                let mut map = ssh.forwarded_map.lock().await;
                if map.contains_key(&(bind_addr.clone(), bind_port)) {
                    return Err(TransportError::Session("Cổng chuyển tiếp từ xa đang được sử dụng".into()));
                }
                map.insert((bind_addr.clone(), bind_port), ForwardedTarget {
                    host: t_host,
                    port: t_port,
                    stopped: stop_rx.clone(),
                    bytes_in: b_in,
                    bytes_out: b_out,
                    active_conns: conns,
                    last_error: err_arc.clone(),
                });
            }
            let actual_port = {
                let guard = ssh.handle.lock().await;
                let result = guard
                    .tcpip_forward(&bind_addr, bind_port)
                    .await;
                match result {
                    Ok(port) => port,
                    Err(error) => {
                        ssh.forwarded_map.lock().await.remove(&(bind_addr.clone(), bind_port));
                        return Err(TransportError::Session(format!("Remote forward failed: {error}")));
                    }
                }
            };
            let actual_port = if actual_port > 0 { actual_port } else { bind_port };
            rule.bind_port = actual_port as u16;
            if actual_port != bind_port && actual_port > 0 {
                let mut map = ssh.forwarded_map.lock().await;
                if let Some(v) = map.remove(&(bind_addr.clone(), bind_port)) {
                    map.insert((bind_addr.clone(), actual_port), v);
                }
            }
            tokio::spawn(async move {
                let _ = stop_rx.changed().await;
                ssh.forwarded_map.lock().await.remove(&(bind_addr.clone(), actual_port));
                let result = {
                    let guard = ssh.handle.lock().await;
                    tokio::time::timeout(Duration::from_secs(5), guard.cancel_tcpip_forward(&bind_addr, actual_port)).await
                };
                if let Ok(Err(error)) = result {
                    *err_arc.lock().await = Some(error.to_string());
                }
                r_flag.store(false, Ordering::Relaxed);
            })
        }
    };

    Ok(ActiveTunnel {
        rule,
        running,
        bytes_in,
        bytes_out,
        active_conns,
        last_error,
        stopped,
        _task: task,
    })
}

async fn handle_socks5_conn(
    tcp: &mut TcpStream,
    peer: SocketAddr,
    ssh: &SshClientHandle,
    bi: &AtomicU64,
    bo: &AtomicU64,
) -> std::io::Result<()> {
    let mut head = [0u8; 2];
    tcp.read_exact(&mut head).await?;
    if head[0] != 5 {
        return Ok(());
    }
    let mut methods = vec![0u8; head[1] as usize];
    tcp.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        tcp.write_all(&[5, 255]).await?;
        return Ok(());
    }
    tcp.write_all(&[5, 0]).await?; // No-auth

    let mut req = [0u8; 4];
    tcp.read_exact(&mut req).await?;
    if req[0] != 5 || req[2] != 0 || req[1] != 1 {
        // CONNECT only
        tcp.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Ok(());
    }
    let target_host = match req[3] {
        1 => {
            let mut ip = [0u8; 4];
            tcp.read_exact(&mut ip).await?;
            std::net::Ipv4Addr::from(ip).to_string()
        }
        3 => {
            let mut len = [0u8; 1];
            tcp.read_exact(&mut len).await?;
            let mut dom = vec![0u8; len[0] as usize];
            tcp.read_exact(&mut dom).await?;
            String::from_utf8_lossy(&dom).to_string()
        }
        4 => {
            let mut ip = [0u8; 16];
            tcp.read_exact(&mut ip).await?;
            std::net::Ipv6Addr::from(ip).to_string()
        }
        _ => {
            tcp.write_all(&[5, 8, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(());
        }
    };
    let mut port_b = [0u8; 2];
    tcp.read_exact(&mut port_b).await?;
    let target_port = u16::from_be_bytes(port_b) as u32;

    let ch = {
        let guard = ssh.handle.lock().await;
        guard
            .channel_open_direct_tcpip(&target_host, target_port, peer.ip().to_string(), peer.port() as u32)
            .await
    };
    match ch {
        Ok(c) => {
            tcp.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            let mut stream = c.into_stream();
            if let Ok((up, down)) = tokio::io::copy_bidirectional(tcp, &mut stream).await {
                bo.fetch_add(up, Ordering::Relaxed);
                bi.fetch_add(down, Ordering::Relaxed);
            }
        }
        Err(_) => {
            tcp.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        }
    }
    Ok(())
}

// --- Telnet Client ---
const TELNET_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

async fn await_telnet_connect<F>(
    hostname: &str,
    port: u16,
    timeout: Duration,
    connect: F,
) -> Result<TcpStream, TransportError>
where
    F: std::future::Future<Output = std::io::Result<TcpStream>>,
{
    tokio::time::timeout(timeout, connect)
        .await
        .map_err(|_| {
            TransportError::Connect(format!(
                "Telnet {hostname}:{port} timed out after {} ms",
                timeout.as_millis()
            ))
        })?
        .map_err(|e| TransportError::Connect(format!("Telnet {hostname}:{port} — {e}")))
}

pub async fn connect_telnet(
    hostname: &str,
    port: u16,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    let stream = await_telnet_connect(
        hostname,
        port,
        TELNET_CONNECT_TIMEOUT,
        TcpStream::connect((hostname, port)),
    )
    .await?;
    let (mut reader, mut writer) = stream.into_split();
    let (in_tx, mut in_rx) = mpsc::channel::<SessionInput>(128);
    let (out_tx, out_rx) = mpsc::channel::<SessionOutput>(128);
    let (reply_tx, mut reply_rx) = mpsc::channel::<Vec<u8>>(32);

    tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        let out_tx_w = out_tx.clone();
        let r_task = tokio::spawn(async move {
            let mut decoder = TelnetDecoder::default();
            loop {
                match reader.read(&mut buf).await {
                    Ok(0) => {
                        let _ = out_tx.send(SessionOutput::Closed(None)).await;
                        break;
                    }
                    Ok(n) => {
                        let (cleaned, replies) = decoder.feed(&buf[..n]);
                        if !replies.is_empty() && reply_tx.send(replies).await.is_err() {
                            break;
                        }
                        if !cleaned.is_empty() && out_tx.send(SessionOutput::Data(cleaned)).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = out_tx.send(SessionOutput::Closed(Some(e.to_string()))).await;
                        break;
                    }
                }
            }
        });
        loop {
            let bytes = tokio::select! {
                Some(reply) = reply_rx.recv() => reply,
                input = in_rx.recv() => match input {
                    Some(SessionInput::Bytes(bytes)) => escape_telnet_data(&bytes),
                    Some(SessionInput::Resize { .. }) => continue,
                    Some(SessionInput::Close) | None => break,
                },
            };
            if let Err(e) = writer.write_all(&bytes).await {
                let _ = out_tx_w.send(SessionOutput::Closed(Some(e.to_string()))).await;
                break;
            }
        }
        r_task.abort();
    });

    Ok((in_tx, out_rx))
}

#[derive(Default, Clone, Copy)]
enum TelnetDecodeState {
    #[default]
    Data,
    Iac,
    Option(u8),
    Subnegotiation,
    SubnegotiationIac,
}

struct TelnetDecoder {
    state: TelnetDecodeState,
    local_options: [bool; 256],
    remote_options: [bool; 256],
}

impl Default for TelnetDecoder {
    fn default() -> Self {
        Self {
            state: TelnetDecodeState::Data,
            local_options: [false; 256],
            remote_options: [false; 256],
        }
    }
}

impl TelnetDecoder {
    fn feed(&mut self, data: &[u8]) -> (Vec<u8>, Vec<u8>) {
        const IAC: u8 = 255;
        const WILL: u8 = 251;
        const WONT: u8 = 252;
        const DO: u8 = 253;
        const DONT: u8 = 254;
        let mut output = Vec::with_capacity(data.len());
        let mut replies = Vec::new();
        for &byte in data {
            match self.state {
                TelnetDecodeState::Data => {
                    if byte == IAC {
                        self.state = TelnetDecodeState::Iac;
                    } else {
                        output.push(byte);
                    }
                }
                TelnetDecodeState::Iac => {
                    self.state = match byte {
                        IAC => {
                            output.push(IAC);
                            TelnetDecodeState::Data
                        }
                        WILL | WONT | DO | DONT => TelnetDecodeState::Option(byte),
                        250 => TelnetDecodeState::Subnegotiation,
                        _ => TelnetDecodeState::Data,
                    };
                }
                TelnetDecodeState::Option(command) => {
                    let index = byte as usize;
                    match command {
                        WILL => {
                            // Binary transmission, remote echo, and suppress-go-ahead.
                            if matches!(byte, 0 | 1 | 3) {
                                if !self.remote_options[index] {
                                    replies.extend_from_slice(&[IAC, DO, byte]);
                                    self.remote_options[index] = true;
                                }
                            } else {
                                replies.extend_from_slice(&[IAC, DONT, byte]);
                            }
                        }
                        WONT if self.remote_options[index] => {
                            self.remote_options[index] = false;
                            replies.extend_from_slice(&[IAC, DONT, byte]);
                        }
                        DO => {
                            if matches!(byte, 0 | 3) {
                                if !self.local_options[index] {
                                    replies.extend_from_slice(&[IAC, WILL, byte]);
                                    self.local_options[index] = true;
                                }
                            } else {
                                replies.extend_from_slice(&[IAC, WONT, byte]);
                            }
                        }
                        DONT if self.local_options[index] => {
                            self.local_options[index] = false;
                            replies.extend_from_slice(&[IAC, WONT, byte]);
                        }
                        _ => {}
                    }
                    self.state = TelnetDecodeState::Data;
                }
                TelnetDecodeState::Subnegotiation => {
                    if byte == IAC {
                        self.state = TelnetDecodeState::SubnegotiationIac;
                    }
                }
                TelnetDecodeState::SubnegotiationIac => {
                    self.state = if byte == 240 {
                        TelnetDecodeState::Data
                    } else {
                        TelnetDecodeState::Subnegotiation
                    };
                }
            }
        }
        (output, replies)
    }
}

fn escape_telnet_data(data: &[u8]) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(data.len());
    for &byte in data {
        encoded.push(byte);
        if byte == 255 {
            encoded.push(byte);
        }
    }
    encoded
}

// --- Local Shell (portable-pty; Android uses its system shell) ---
#[cfg(not(target_os = "ios"))]
pub fn spawn_local_shell(
    cols: u16,
    rows: u16,
    startup_dir: Option<String>,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    use portable_pty::{native_pty_system, CommandBuilder, PtySize};
    use std::io::{Read, Write};

    let startup_dir = startup_dir.filter(|dir| !dir.is_empty());
    if let Some(dir) = startup_dir.as_ref() {
        let metadata = std::fs::metadata(dir).map_err(|error| TransportError::Session(format!(
            "Thư mục khởi động không hợp lệ: {error}"
        )))?;
        if !metadata.is_dir() {
            return Err(TransportError::Session("Thư mục khởi động không phải là thư mục.".into()));
        }
    }

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| TransportError::Session(format!("openpty failed: {e}")))?;

    #[cfg(target_os = "android")]
    let shell = "/system/bin/sh".to_owned();
    #[cfg(not(target_os = "android"))]
    let shell = std::env::var("SHELL").unwrap_or_else(|_| {
        if cfg!(windows) {
            "powershell.exe".to_string()
        } else {
            "/bin/bash".to_string()
        }
    });
    let mut cmd = CommandBuilder::new(shell);
    if let Some(dir) = startup_dir {
        cmd.cwd(dir);
    }
    cmd.env("TERM", "xterm-256color");

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| TransportError::Session(format!("spawn shell failed: {e}")))?;
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| TransportError::Session(e.to_string()))?;
    let mut writer = pair
        .master
        .take_writer()
        .map_err(|e| TransportError::Session(e.to_string()))?;
    let mut killer = child.clone_killer();

    let (in_tx, mut in_rx) = mpsc::channel::<SessionInput>(256);
    let (out_tx, out_rx) = mpsc::channel::<SessionOutput>(256);

    let out_tx_r = out_tx.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = out_tx_r.blocking_send(SessionOutput::Closed(None));
                    break;
                }
                Ok(n) => {
                    if out_tx_r
                        .blocking_send(SessionOutput::Data(buf[..n].to_vec()))
                        .is_err()
                    {
                        break;
                    }
                }
                Err(e) => {
                    let _ = out_tx_r.blocking_send(SessionOutput::Closed(Some(e.to_string())));
                    break;
                }
            }
        }
        let _ = child.wait();
    });

    tokio::spawn(async move {
        let master = pair.master;
        while let Some(ev) = in_rx.recv().await {
            match ev {
                SessionInput::Bytes(b) => {
                    if writer.write_all(&b).is_err() || writer.flush().is_err() {
                        break;
                    }
                }
                SessionInput::Resize { cols, rows } => {
                    let _ = master.resize(PtySize {
                        rows,
                        cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    });
                }
                SessionInput::Close => break,
            }
        }
        // The reader keeps a cloned master descriptor, so dropping only this
        // writer/master cannot stop a shell blocked on input.
        let _ = killer.kill();
    });

    Ok((in_tx, out_rx))
}

#[cfg(target_os = "ios")]
pub fn spawn_local_shell(
    _cols: u16,
    _rows: u16,
    _startup_dir: Option<String>,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    Err(TransportError::Session(
        "Local shell không được hỗ trợ trong iOS sandbox — hãy dùng kết nối SSH/Telnet.".into(),
    ))
}

// --- Wake-on-LAN & Pre-connect ---
pub async fn send_wake_on_lan(mac: &str, broadcast_addr: &str) -> Result<(), TransportError> {
    send_wake_on_lan_to(mac, broadcast_addr, 9).await
}

async fn send_wake_on_lan_to(mac: &str, destination: &str, port: u16) -> Result<(), TransportError> {
    let parts: Vec<_> = mac.split([':', '-']).collect();
    if parts.len() != 6 || parts.iter().any(|part| part.len() != 2) {
        return Err(TransportError::Connect("Địa chỉ MAC không hợp lệ".into()));
    }
    let hex = parts.into_iter()
        .map(|part| u8::from_str_radix(part, 16)
            .map_err(|_| TransportError::Connect("Địa chỉ MAC không hợp lệ".into())))
        .collect::<Result<Vec<_>, _>>()?;
    let mut pkt = [0u8; 102];
    pkt[..6].fill(0xFF);
    for i in 1..=16 {
        pkt[i * 6..(i + 1) * 6].copy_from_slice(&hex);
    }
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.set_broadcast(true)?;
    sock.send_to(&pkt, (destination, port)).await?;
    Ok(())
}

#[cfg(test)]
mod wol_packet_tests {
    use super::*;

    #[tokio::test]
    async fn wol_actual_udp_loopback_contains_full_magic_packet() {
        let receiver = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = receiver.local_addr().unwrap().port();
        // Public Wake-on-LAN uses the exact same sender with UDP destination9.
        // This test uses an ephemeral destination and needs no network caps.
        send_wake_on_lan_to("02:AB:0c:34:56:78", "127.0.0.1", port).await.unwrap();
        let mut bytes = [0_u8; 512];
        let (length, peer) = tokio::time::timeout(Duration::from_secs(2), receiver.recv_from(&mut bytes)).await.unwrap().unwrap();
        assert!(peer.ip().is_loopback());
        assert_eq!(length, 102);
        assert_eq!(&bytes[..6], &[255; 6]);
        for repetition in bytes[6..102].chunks_exact(6) {
            assert_eq!(repetition, &[0x02, 0xab, 0x0c, 0x34, 0x56, 0x78]);
        }
    }

    #[tokio::test]
    async fn wol_rejects_invalid_mac_instead_of_skipping_bad_octets() {
        for mac in ["00:11:22:33:44:55:zz", "00:11:22:33:44", "0:1:2:3:4:5", "GG-11-22-33-44-55"] {
            assert!(send_wake_on_lan_to(mac, "127.0.0.1", 9).await.is_err(), "{mac}");
        }
    }
}

// --- Ping TCP latency helper ---
pub async fn measure_tcp_latency_ms(host: &str, port: u16) -> Result<u64, TransportError> {
    let start = Instant::now();
    let fut = TcpStream::connect((host, port));
    match tokio::time::timeout(Duration::from_secs(5), fut).await {
        Ok(Ok(_)) => Ok(start.elapsed().as_millis() as u64),
        Ok(Err(e)) => Err(TransportError::Connect(e.to_string())),
        Err(_) => Err(TransportError::Connect("Timeout".into())),
    }
}

// --- BYO-Key / Local Ollama AI Assistant (returns command draft, never auto-executes) ---
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiDraftResponse {
    pub command: String,
    pub explanation: String,
    pub sent_context_preview: String,
}

pub async fn generate_ai_command(
    endpoint_url: &str,
    api_key: Option<&str>,
    model: &str,
    prompt: &str,
    os_hint: &str,
    shell_hint: &str,
) -> Result<AiDraftResponse, TransportError> {
    let context_preview = format!("OS: {os_hint} | Shell: {shell_hint} | Prompt: {prompt}");
    let system_prompt = format!(
        "You are a concise CLI assistant for {os_hint} ({shell_hint}). Return strictly JSON: {{\"command\":\"...\",\"explanation\":\"...\"}}. Never include markdown fences."
    );

    let endpoint = reqwest::Url::parse(endpoint_url)
        .map_err(|error| TransportError::Connect(format!("AI endpoint không hợp lệ: {error}")))?;
    if !matches!(endpoint.scheme(), "http" | "https") || endpoint.host_str().is_none()
        || !endpoint.username().is_empty() || endpoint.password().is_some() {
        return Err(TransportError::Connect("AI endpoint phải là HTTP(S), không chứa username/password trong URL".into()));
    }
    let is_ollama_native = endpoint.path().trim_end_matches('/') == "/api/chat";
    // Loading a local model can take longer than generation. Keep the wait
    // bounded while allowing a genuine cold start on desktop hardware.
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(if is_ollama_native {180} else {60}))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| TransportError::Connect(e.to_string()))?;
    let body = if is_ollama_native {
        serde_json::json!({
            "model": model,
            "stream": false,
            "options": {"num_ctx": 2048, "num_predict": 512, "temperature": 0.1},
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": prompt}
            ]
        })
    } else {
        serde_json::json!({
            "model": model,
            "temperature": 0.1,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": prompt}
            ]
        })
    };

    let mut req = client.post(endpoint_url).json(&body);
    if let Some(k) = api_key.filter(|s| !s.trim().is_empty()) {
        req = req.bearer_auth(k);
    }

    let mut resp = req
        .send()
        .await
        .map_err(|e| TransportError::Connect(format!("AI request failed: {e}")))?;
    if !resp.status().is_success() {
        return Err(TransportError::Connect(format!(
            "AI endpoint HTTP {}",
            resp.status()
        )));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| TransportError::Connect(e.to_string()))? {
        if bytes.len() + chunk.len() > 1024 * 1024 {
            return Err(TransportError::Connect("AI response vượt giới hạn 1 MiB".into()));
        }
        bytes.extend_from_slice(&chunk);
    }
    let val: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|e| TransportError::Connect(e.to_string()))?;

    let raw_content = val["choices"][0]["message"]["content"]
        .as_str()
        .or_else(|| val["message"]["content"].as_str())
        .filter(|content| !content.trim().is_empty())
        .ok_or_else(|| TransportError::Session("AI không trả về nội dung lệnh hợp lệ".into()))?
        .trim();
    let raw_content = if raw_content.starts_with("```") {
        raw_content.split_once('\n')
            .and_then(|(_, content)| content.trim_end().strip_suffix("```"))
            .map(str::trim)
            .ok_or_else(|| TransportError::Session("AI trả về khối mã chưa hoàn chỉnh".into()))?
    } else {
        raw_content
    };
    if raw_content.is_empty() {
        return Err(TransportError::Session("AI không trả về nội dung lệnh hợp lệ".into()));
    }

    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw_content) {
        let command = parsed["command"].as_str()
            .filter(|command| !command.trim().is_empty())
            .ok_or_else(|| TransportError::Session("AI trả về JSON thiếu trường command hợp lệ".into()))?;
        return Ok(AiDraftResponse {
            command: command.to_string(),
            explanation: parsed["explanation"].as_str().unwrap_or("").to_string(),
            sent_context_preview: context_preview,
        });
    }
    if raw_content.starts_with('{') || raw_content.starts_with('[') {
        return Err(TransportError::Session("AI trả về JSON không hợp lệ".into()));
    }

    Ok(AiDraftResponse {
        command: raw_content.to_string(),
        explanation: String::new(),
        sent_context_preview: context_preview,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_model::{Host, Identity, IdentityMode};
    use russh::keys::{Algorithm, HashAlg, PrivateKey};
    use russh::server::{self, Auth, Msg, Server as _, Session, VerifiedPublicKey};
    use russh::{Channel, ChannelId};
    use russh_sftp::protocol::{File, FileAttributes, Handle, Name, Status, StatusCode, Version};
    use std::path::PathBuf;

    async fn mock_http_proxy(response: Vec<Vec<u8>>) -> (ProxyConfig, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(stream.read_u8().await.unwrap());
            }
            for chunk in response {
                if stream.write_all(&chunk).await.is_err() { break; }
                tokio::task::yield_now().await;
            }
            String::from_utf8(request).unwrap()
        });
        (ProxyConfig {
            id: "test-proxy".into(), name: "Local test proxy".into(),
            kind: ProxyKind::HttpConnect, host: "127.0.0.1".into(), port, credential_id: None,
            username: None,
            ..Default::default()
        }, server)
    }

    #[tokio::test]
    async fn http_connect_handles_fragmented_headers_and_preserves_coalesced_ssh_banner() {
        let (proxy, request) = mock_http_proxy(vec![
            b"HTTP/1.1 2".to_vec(), b"00 Connection established\r\nX-Test: yes\r\n".to_vec(),
            b"\r\nSSH-2.0-test\r\n".to_vec(),
        ]).await;
        let mut stream = connect_tcp_with_proxy("2001:db8::1", 2222, Some(&proxy), None).await.unwrap();
        let mut banner = Vec::new();
        stream.read_to_end(&mut banner).await.unwrap();
        assert_eq!(banner, b"SSH-2.0-test\r\n");
        assert_eq!(request.await.unwrap(), "CONNECT [2001:db8::1]:2222 HTTP/1.1\r\nHost: [2001:db8::1]:2222\r\nProxy-Connection: Keep-Alive\r\n\r\n");
    }

    #[tokio::test]
    async fn http_connect_rejects_fake_success_truncation_and_oversized_headers() {
        for response in [
            b"HTTP/1.1 407 Proxy Authentication Required\r\nX-Decoy: 200 OK\r\n\r\n".to_vec(),
            b"NOTHTTP 200 OK\r\n\r\n".to_vec(),
            b"HTTP/1.1 200 OK\r\n".to_vec(),
            [b"HTTP/1.1 200 OK\r\nX-Test: ".as_slice(), &vec![b'a'; 16 * 1024], b"\r\n\r\n"].concat(),
        ] {
            let (proxy, request) = mock_http_proxy(vec![response]).await;
            assert!(connect_tcp_with_proxy("ssh.example", 22, Some(&proxy), None).await.is_err());
            request.await.unwrap();
        }
    }

    fn proxy_test_credential() -> Credential {
        Credential {
            id: "proxy-password".into(), name: "Test proxy password".into(),
            secret: Some("test-only-proxy-password".into()), ..Default::default()
        }
    }

    #[tokio::test]
    async fn authenticated_http_proxy_sends_basic_header_and_propagates_rejection() {
        for success in [true, false] {
            let response = if success { b"HTTP/1.1 200 OK\r\n\r\nSSH-BANNER".as_slice() } else { b"HTTP/1.1 407 Authentication required\r\n\r\n".as_slice() };
            let (mut proxy, request) = mock_http_proxy(vec![response.to_vec()]).await;
            proxy.username = Some("proxy-user".into());
            proxy.credential_id = Some("proxy-password".into());
            let credential = proxy_test_credential();
            let result = connect_tcp_with_proxy("ssh.example", 22, Some(&proxy), Some(&credential)).await;
            if success {
                let mut stream = result.unwrap();
                let mut banner = Vec::new();
                stream.read_to_end(&mut banner).await.unwrap();
                assert_eq!(banner, b"SSH-BANNER");
            } else {
                let error = result.unwrap_err().to_string();
                assert!(error.contains("407"));
                assert!(!error.contains(credential.secret.as_deref().unwrap()));
            }
            let headers = request.await.unwrap();
            let authorization = headers.lines().find_map(|line| line.strip_prefix("Proxy-Authorization: Basic ")).unwrap();
            assert_eq!(BASE64.decode(authorization).unwrap(), b"proxy-user:test-only-proxy-password");
        }
    }

    #[tokio::test]
    async fn authenticated_socks5_negotiates_password_auth_and_rejects_invalid_password() {
        for success in [true, false] {
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut greeting = [0; 3];
                stream.read_exact(&mut greeting).await.unwrap();
                assert_eq!(greeting, [5, 1, 2]);
                stream.write_all(&[5, 2]).await.unwrap();
                assert_eq!(stream.read_u8().await.unwrap(), 1);
                let username_length = stream.read_u8().await.unwrap() as usize;
                let mut username = vec![0; username_length];
                stream.read_exact(&mut username).await.unwrap();
                let password_length = stream.read_u8().await.unwrap() as usize;
                let mut password = vec![0; password_length];
                stream.read_exact(&mut password).await.unwrap();
                assert_eq!(username, b"proxy-user");
                assert_eq!(password, b"test-only-proxy-password");
                stream.write_all(&[1, if success { 0 } else { 1 }]).await.unwrap();
                if !success { return; }
                let mut request_header = [0; 4];
                stream.read_exact(&mut request_header).await.unwrap();
                assert_eq!(request_header, [5, 1, 0, 3]);
                let length = stream.read_u8().await.unwrap() as usize;
                let mut target = vec![0; length];
                stream.read_exact(&mut target).await.unwrap();
                assert_eq!(target, b"ssh.example");
                assert_eq!(stream.read_u16().await.unwrap(), 2222);
                // IPv6 bound-address reply plus SSH data in the same write.
                let mut response = vec![5, 0, 0, 4];
                response.extend_from_slice(&[0; 16]);
                response.extend_from_slice(&[0, 22]);
                response.extend_from_slice(b"SSH-BANNER");
                stream.write_all(&response).await.unwrap();
            });
            let proxy = ProxyConfig {
                id: "test".into(), name: "Test SOCKS5".into(), kind: ProxyKind::Socks5,
                host: "127.0.0.1".into(), port, username: Some("proxy-user".into()), credential_id: Some("proxy-password".into()),
                ..Default::default()
            };
            let credential = proxy_test_credential();
            let result = connect_tcp_with_proxy("ssh.example", 2222, Some(&proxy), Some(&credential)).await;
            if success {
                let mut stream = result.unwrap();
                let mut banner = Vec::new();
                stream.read_to_end(&mut banner).await.unwrap();
                assert_eq!(banner, b"SSH-BANNER");
            } else {
                let error = result.unwrap_err().to_string();
                assert!(error.contains("bị từ chối"));
                assert!(!error.contains("test-only-proxy-password"));
            }
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn authenticated_socks5_refuses_no_authentication_downgrade() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut greeting = [0; 3];
            stream.read_exact(&mut greeting).await.unwrap();
            assert_eq!(greeting, [5, 1, 2]);
            stream.write_all(&[5, 0]).await.unwrap();
            let mut following = Vec::new();
            stream.read_to_end(&mut following).await.unwrap();
            assert!(following.is_empty());
        });
        let proxy = ProxyConfig {
            id: "test".into(), name: "Test SOCKS5".into(), kind: ProxyKind::Socks5,
            host: "127.0.0.1".into(), port, username: Some("proxy-user".into()), credential_id: Some("proxy-password".into()),
            ..Default::default()
        };
        let error = connect_tcp_with_proxy("ssh.example", 22, Some(&proxy), Some(&proxy_test_credential())).await.unwrap_err();
        assert!(error.to_string().contains("không chấp nhận xác thực"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn socks4_sends_userid_and_handles_proxy_rejection() {
        for (success, hostname) in [
            (true, "192.0.2.10"), (false, "192.0.2.10"),
            (true, "ssh.example"), (false, "ssh.example"),
        ] {
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut header = [0; 8];
                stream.read_exact(&mut header).await.unwrap();
                assert_eq!(&header[..4], &[4, 1, 0, 22]);
                assert_eq!(&header[4..], if hostname == "ssh.example" { &[0, 0, 0, 1] } else { &[192, 0, 2, 10] });
                let mut userid = Vec::new();
                loop {
                    let byte = stream.read_u8().await.unwrap();
                    if byte == 0 { break; }
                    userid.push(byte);
                }
                assert_eq!(userid, b"proxy-user");
                if hostname == "ssh.example" {
                    let mut domain = Vec::new();
                    loop {
                        let byte = stream.read_u8().await.unwrap();
                        if byte == 0 { break; }
                        domain.push(byte);
                    }
                    assert_eq!(domain, b"ssh.example");
                }
                stream.write_all(&[0, if success { 90 } else { 91 }, 0, 22, 192, 0, 2, 10]).await.unwrap();
            });
            let proxy = ProxyConfig {
                id: "test".into(), name: "Test SOCKS4".into(), kind: ProxyKind::Socks4,
                host: "127.0.0.1".into(), port, username: Some("proxy-user".into()), credential_id: None,
                ..Default::default()
            };
            assert_eq!(connect_tcp_with_proxy(hostname, 22, Some(&proxy), None).await.is_ok(), success);
            server.await.unwrap();
        }
    }

    #[test]
    fn proxy_authentication_rejects_incomplete_and_incompatible_credentials() {
        let proxy = ProxyConfig {
            id: "test".into(), name: "Test".into(), kind: ProxyKind::Socks5,
            host: "127.0.0.1".into(), port: 1080,
            username: Some("proxy-user".into()), credential_id: Some("proxy-password".into()),
            ..Default::default()
        };
        let credential = proxy_test_credential();
        assert!(proxy_authentication(&proxy, Some(&credential)).is_ok());
        for invalid_proxy in [
            ProxyConfig { username: None, ..proxy.clone() },
            ProxyConfig { username: Some("".into()), ..proxy.clone() },
            ProxyConfig { credential_id: None, ..proxy.clone() },
            ProxyConfig { kind: ProxyKind::Socks4, ..proxy.clone() },
            ProxyConfig { kind: ProxyKind::HttpConnect, username: Some("bad:user".into()), ..proxy.clone() },
            ProxyConfig { username: Some("a".repeat(256)), ..proxy.clone() },
        ] {
            assert!(proxy_authentication(&invalid_proxy, Some(&credential)).is_err());
        }
        for invalid_credential in [
            Credential { secret: None, ..credential.clone() },
            Credential { kind: CredentialKind::SshKey, ..credential.clone() },
            Credential { secret: Some("".into()), ..credential.clone() },
        ] {
            assert!(proxy_authentication(&proxy, Some(&invalid_credential)).is_err());
        }
    }

    async fn mock_ai_response(
        status: &str,
        response: serde_json::Value,
    ) -> (String, tokio::task::JoinHandle<(String, String, serde_json::Value)>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let status = status.to_string();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut headers = Vec::new();
            while !headers.ends_with(b"\r\n\r\n") {
                let mut byte = [0; 1];
                socket.read_exact(&mut byte).await.unwrap();
                headers.push(byte[0]);
                assert!(headers.len() <= 16 * 1024);
            }
            let headers = String::from_utf8(headers).unwrap();
            let length = headers.lines().filter_map(|line| line.split_once(':'))
                .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .unwrap().1.trim().parse::<usize>().unwrap();
            let mut body = vec![0; length];
            socket.read_exact(&mut body).await.unwrap();
            let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
            let payload = serde_json::to_vec(&response).unwrap();
            socket.write_all(format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", payload.len()).as_bytes()).await.unwrap();
            socket.write_all(&payload).await.unwrap();
            (headers.lines().next().unwrap().to_string(), headers, body)
        });
        (format!("http://{address}"), task)
    }

    #[tokio::test]
    async fn ai_http_protocol_supports_ollama_and_openai_compatible_responses() {
        for native in [false, true] {
            let content = "{\"command\":\"printf 'test'\",\"explanation\":\"Print test\"}";
            let response = if native {
                serde_json::json!({"message": {"content": content}})
            } else {
                serde_json::json!({"choices": [{"message": {"content": format!("```json\n{content}\n```")}}]})
            };
            let (url, request) = mock_ai_response("200 OK", response).await;
            let path = if native { "/api/chat" } else { "/v1/chat/completions?hint=/api/chat" };
            let draft = generate_ai_command(&format!("{url}{path}"), Some("test-only-token"), "test-model", "print test", "Linux", "bash").await.unwrap();
            assert_eq!(draft.command, "printf 'test'");
            assert_eq!(draft.explanation, "Print test");
            assert!(draft.sent_context_preview.contains("print test"));
            let (line, headers, body) = request.await.unwrap();
            assert!(line.starts_with(&format!("POST {path} ")));
            assert!(headers.to_ascii_lowercase().contains("authorization: bearer test-only-token"));
            assert_eq!(body["model"], "test-model");
            assert_eq!(body["messages"][1]["content"], "print test");
            if native {
                assert_eq!(body["stream"], false);
                assert!(body.get("temperature").is_none());
            } else {
                assert_eq!(body["temperature"], 0.1);
            }
        }
    }

    #[tokio::test]
    async fn ai_rejects_empty_and_malformed_command_responses() {
        for response in [
            serde_json::json!({"choices": []}),
            serde_json::json!({"message": {"content": ""}}),
            serde_json::json!({"message": {"content": "{}"}}),
            serde_json::json!({"message": {"content": "{broken"}}),
            serde_json::json!({"message": {"content": "```json\n{}"}}),
        ] {
            let (url, request) = mock_ai_response("200 OK", response).await;
            assert!(generate_ai_command(&format!("{url}/api/chat"), None, "test-model", "test", "Linux", "bash").await.is_err());
            let (_, headers, _) = request.await.unwrap();
            assert!(!headers.to_ascii_lowercase().contains("authorization:"));
        }
    }

    #[tokio::test]
    async fn ai_http_failures_propagate_as_errors() {
        let (url, request) = mock_ai_response("401 Unauthorized", serde_json::json!({"error": "test"})).await;
        let error = generate_ai_command(&format!("{url}/v1/chat/completions"), None, "test-model", "test", "Linux", "bash").await.err().unwrap().to_string();
        assert!(error.contains("401"));
        request.await.unwrap();
    }

    #[test]
    fn configured_proxy_auth_is_resolved_and_never_silently_ignored() {
        let proxy = ProxyConfig {
            id: "proxy".into(), name: "Authenticated proxy".into(),
            kind: ProxyKind::Socks5, host: "127.0.0.1".into(), port: 1080,
            username: None,
            credential_id: Some("credential".into()),
            ..Default::default()
        };
        assert!(validate_proxy_credentials(Some(&proxy), &[]).unwrap_err().to_string().contains("Không tìm thấy"));
        let credential = Credential {
            id: "credential".into(), secret: Some("DO_NOT_EXPOSE_TEST_SECRET".into()), ..Default::default()
        };
        let error = validate_proxy_credentials(Some(&proxy), &[credential]).unwrap_err().to_string();
        assert!(error.contains("tên đăng nhập"));
        assert!(!error.contains("DO_NOT_EXPOSE_TEST_SECRET"));
        let unauthenticated = ProxyConfig { credential_id: None, ..proxy };
        assert!(validate_proxy_credentials(Some(&unauthenticated), &[]).is_ok());
    }

    #[test]
    fn telnet_decoder_handles_fragmented_negotiation_and_escaped_iac() {
        let mut decoder = TelnetDecoder::default();
        assert_eq!(decoder.feed(b"hello\xff"), (b"hello".to_vec(), vec![]));
        assert_eq!(decoder.feed(&[251]), (vec![], vec![]));
        assert_eq!(decoder.feed(&[1, b'!']), (b"!".to_vec(), vec![255, 253, 1]));
        assert_eq!(decoder.feed(&[255, 251, 1]), (vec![], vec![]));
        assert_eq!(decoder.feed(&[255, 253, 24]), (vec![], vec![255, 252, 24]));
        assert_eq!(decoder.feed(&[255, 255, b'x']), (vec![255, b'x'], vec![]));
        assert_eq!(escape_telnet_data(&[b'x', 255, b'y']), vec![b'x', 255, 255, b'y']);
    }

    #[test]
    fn telnet_decoder_consumes_subnegotiation_across_packets() {
        let mut decoder = TelnetDecoder::default();
        assert_eq!(decoder.feed(&[255, 250, 24, 1, b'x', 255]), (vec![], vec![]));
        assert_eq!(decoder.feed(&[255, b'y', 255]), (vec![], vec![]));
        assert_eq!(decoder.feed(&[240, b'O', b'K']), (b"OK".to_vec(), vec![]));
    }

    #[tokio::test]
    async fn telnet_connect_times_out_without_waiting_for_connect_future() {
        let sleeping_connect = async {
            tokio::time::sleep(Duration::from_secs(60)).await;
            Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionRefused,
                "sleeping connect unexpectedly completed",
            ))
        };
        let error = await_telnet_connect(
            "fixture.invalid",
            23,
            Duration::from_millis(10),
            sleeping_connect,
        )
        .await
        .unwrap_err();
        assert!(matches!(error, TransportError::Connect(_)));
        assert_eq!(
            error.to_string(),
            "Kết nối thất bại: Telnet fixture.invalid:23 timed out after 10 ms"
        );
    }

    #[tokio::test]
    async fn telnet_negotiation_does_not_leak_into_terminal_output() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            stream.write_all(&[255, 251]).await.unwrap();
            tokio::task::yield_now().await;
            stream.write_all(&[1, b'L', b'o', b'g', b'i', b'n', b':']).await.unwrap();
            let mut reply = [0; 3];
            stream.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [255, 253, 1]);
            let mut input = [0; 3];
            stream.read_exact(&mut input).await.unwrap();
            assert_eq!(input, [b'x', 255, 255]);
        });
        let (input, mut output) = connect_telnet("127.0.0.1", port).await.unwrap();
        let event = tokio::time::timeout(Duration::from_secs(2), output.recv()).await.unwrap();
        assert!(matches!(event, Some(SessionOutput::Data(bytes)) if bytes == b"Login:"));
        input.send(SessionInput::Bytes(vec![b'x', 255])).await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server).await.unwrap().unwrap();
        input.send(SessionInput::Close).await.unwrap();
    }

    #[derive(Clone)]
    struct TestSshServer {
        root_dir: PathBuf,
        sftp_open_gate: Option<Arc<TestSftpOpenGate>>,
    }

    #[derive(Default)]
    struct TestSftpOpenGate {
        started: tokio::sync::Notify,
        release: tokio::sync::Notify,
    }

    impl server::Server for TestSshServer {
        type Handler = TestServerSession;
        fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
            TestServerSession {
                root_dir: self.root_dir.clone(),
                channels: Arc::new(Mutex::new(HashMap::new())),
                remote_forwards: HashMap::new(),
                environment: HashMap::new(),
                sftp_open_gate: self.sftp_open_gate.clone(),
            }
        }
    }

    struct TestServerSession {
        root_dir: PathBuf,
        channels: Arc<Mutex<HashMap<ChannelId, Channel<Msg>>>>,
        remote_forwards: HashMap<(String, u32), tokio::task::JoinHandle<()>>,
        environment: HashMap<ChannelId, BTreeMap<String, String>>,
        sftp_open_gate: Option<Arc<TestSftpOpenGate>>,
    }

    impl Drop for TestServerSession {
        fn drop(&mut self) {
            for task in self.remote_forwards.values() {
                task.abort();
            }
        }
    }

    impl server::Handler for TestServerSession {
        type Error = anyhow::Error;

        async fn tcpip_forward(
            &mut self,
            address: &str,
            port: &mut u32,
            session: &mut Session,
        ) -> Result<bool, Self::Error> {
            let listener = TcpListener::bind((address, *port as u16)).await?;
            *port = listener.local_addr()?.port() as u32;
            let forwarded_port = *port;
            let address = address.to_string();
            let handle = session.handle();
            let key = (address.clone(), *port);
            self.remote_forwards.insert(key, tokio::spawn(async move {
                while let Ok((mut tcp, peer)) = listener.accept().await {
                    let handle = handle.clone();
                    let address = address.clone();
                    tokio::spawn(async move {
                        if let Ok(channel) = handle.channel_open_forwarded_tcpip(
                            address, forwarded_port, peer.ip().to_string(), peer.port() as u32,
                        ).await {
                            let mut stream = channel.into_stream();
                            let _ = tokio::io::copy_bidirectional(&mut tcp, &mut stream).await;
                        }
                    });
                }
            }));
            Ok(true)
        }

        async fn cancel_tcpip_forward(
            &mut self,
            address: &str,
            port: u32,
            _session: &mut Session,
        ) -> Result<bool, Self::Error> {
            if let Some(task) = self.remote_forwards.remove(&(address.to_string(), port)) {
                task.abort();
                let _ = task.await;
                Ok(true)
            } else {
                Ok(false)
            }
        }

        async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
            if user == "auth_stall" {
                return std::future::pending().await;
            }
            if user == "auth_disconnect" {
                anyhow::bail!("controlled disconnect before an authentication response");
            }
            if user == "tester" && password == "pass123" {
                Ok(Auth::Accept)
            } else {
                Ok(Auth::reject())
            }
        }

        async fn auth_publickey(
            &mut self,
            user: &str,
            _key: VerifiedPublicKey<'_>,
        ) -> Result<Auth, Self::Error> {
            if user == "tester" {
                Ok(Auth::Accept)
            } else {
                Ok(Auth::reject())
            }
        }

        async fn channel_open_session(
            &mut self,
            channel: Channel<Msg>,
            reply: server::ChannelOpenHandle,
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            self.channels.lock().await.insert(channel.id(), channel);
            reply.accept().await;
            Ok(())
        }

        async fn pty_request(
            &mut self,
            channel: ChannelId,
            _term: &str,
            _col_width: u32,
            _row_height: u32,
            _pix_width: u32,
            _pix_height: u32,
            _modes: &[(Pty, u32)],
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            match self.environment.get(&channel).and_then(|env| env.get("TEST_PTY_MODE")).map(String::as_str) {
                Some("reject") => {
                    session.channel_failure(channel)?;
                    return Ok(());
                }
                Some("ignore") => return Ok(()),
                Some("close") => {
                    session.close(channel)?;
                    return Ok(());
                }
                Some("prelude") => { session.data(channel, b"PTY_PRELUDE\r\n".to_vec())?; }
                _ => {}
            }
            session.channel_success(channel)?;
            Ok(())
        }

        async fn env_request(
            &mut self,
            channel: ChannelId,
            name: &str,
            value: &str,
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            if name.starts_with("REJECT_") {
                session.channel_failure(channel)?;
            } else if name != "NO_REPLY" {
                self.environment.entry(channel).or_default().insert(name.to_string(), value.to_string());
                session.channel_success(channel)?;
            }
            Ok(())
        }

        async fn shell_request(
            &mut self,
            channel_id: ChannelId,
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            match self.environment.get(&channel_id).and_then(|env| env.get("TEST_SHELL_MODE")).map(String::as_str) {
                Some("reject") => {
                    session.channel_failure(channel_id)?;
                    return Ok(());
                }
                Some("ignore") => return Ok(()),
                Some("close") => {
                    session.close(channel_id)?;
                    return Ok(());
                }
                Some("prelude") => { session.data(channel_id, b"SHELL_PRELUDE\r\n".to_vec())?; }
                _ => {}
            }
            session.channel_success(channel_id)?;
            if let Some(mut ch) = self.channels.lock().await.remove(&channel_id) {
                let environment = self.environment.remove(&channel_id).unwrap_or_default();
                tokio::spawn(async move {
                    let greeting = if environment.is_empty() {
                        "WELCOME_TERMPULSE\r\n".to_string()
                    } else {
                        format!("WELCOME_TERMPULSE\r\nENV_JSON={}\r\n", serde_json::to_string(&environment).unwrap())
                    };
                    let _ = ch.data(greeting.as_bytes()).await;
                    while let Some(msg) = ch.wait().await {
                        if let ChannelMsg::Data { data } = msg {
                            let s = String::from_utf8_lossy(&data);
                            if s.contains("cd /var/log") {
                                let _ = ch.data(&b"\x1b]7;file://test/var/log\x07ok\r\n"[..]).await;
                            } else {
                                let _ = ch.data(&data[..]).await;
                            }
                        }
                    }
                });
            }
            Ok(())
        }

        async fn exec_request(
            &mut self,
            channel_id: ChannelId,
            data: &[u8],
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            let cmd = String::from_utf8_lossy(data).to_string();
            if cmd == "EXEC_REJECT" {
                session.channel_failure(channel_id)?;
                return Ok(());
            }
            session.channel_success(channel_id)?;
            if cmd == "EXEC_STALL" {
                return Ok(());
            }
            if cmd == "EXEC_SIGNAL" {
                session.exit_signal_request(channel_id, russh::Sig::TERM, false, "terminated", "en")?;
                session.eof(channel_id)?;
                session.close(channel_id)?;
                return Ok(());
            }
            if let Some(ch) = self.channels.lock().await.remove(&channel_id) {
                tokio::spawn(async move {
                    if cmd == "EXEC_EXIT_23" {
                        let _ = ch.extended_data(1, &b"proc unavailable\n"[..]).await;
                        let _ = ch.eof().await;
                        let _ = ch.exit_status(23).await;
                    } else if cmd == "EXEC_STDERR_OK" {
                        let _ = ch.extended_data(1, &b"optional warning\n"[..]).await;
                        let _ = ch.data(&b"stdout only\n"[..]).await;
                        let _ = ch.exit_status(0).await;
                    } else if cmd == "EXEC_LARGE" {
                        let _ = ch.data(&vec![b'x'; 1024 * 1024 + 1][..]).await;
                    } else if cmd.contains("/proc/stat") {
                        let sample = b"CPU=1000,750\nMEM=1024,4096\nDISK=12.50,50.00\nNET=5000,9000\nLOAD=0.42 0.30 0.25\nUP=3600\n";
                        let _ = ch.data(&sample[..]).await;
                    } else {
                        let _ = ch.data(&b"EXEC_OK\n"[..]).await;
                    }
                    let _ = ch.eof().await;
                    let _ = ch.close().await;
                });
            }
            Ok(())
        }

        async fn subsystem_request(
            &mut self,
            channel_id: ChannelId,
            name: &str,
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            if name == "sftp" {
                if let Some(ch) = self.channels.lock().await.remove(&channel_id) {
                    session.channel_success(channel_id)?;
                    let handler = TestSftpFs {
                        root: self.root_dir.clone(),
                        files: HashMap::new(),
                        dirs_read: HashMap::new(),
                        open_gate: self.sftp_open_gate.clone(),
                    };
                    tokio::spawn(async move {
                        russh_sftp::server::run(ch.into_stream(), handler).await;
                    });
                    return Ok(());
                }
            }
            session.channel_failure(channel_id)?;
            Ok(())
        }

        async fn channel_open_direct_tcpip(
            &mut self,
            channel: Channel<Msg>,
            host_to_connect: &str,
            port_to_connect: u32,
            _originator_address: &str,
            _originator_port: u32,
            reply: server::ChannelOpenHandle,
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            reply.accept().await;
            let addr = format!("{host_to_connect}:{port_to_connect}");
            tokio::spawn(async move {
                if let Ok(mut target) = TcpStream::connect(&addr).await {
                    let mut s = channel.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut s, &mut target).await;
                }
            });
            Ok(())
        }
    }

    struct TestSftpFs {
        root: PathBuf,
        files: HashMap<String, PathBuf>,
        dirs_read: HashMap<String, bool>,
        open_gate: Option<Arc<TestSftpOpenGate>>,
    }

    impl russh_sftp::server::Handler for TestSftpFs {
        type Error = StatusCode;
        fn unimplemented(&self) -> Self::Error {
            StatusCode::OpUnsupported
        }

        async fn init(
            &mut self,
            _version: u32,
            _ext: HashMap<String, String>,
        ) -> Result<Version, Self::Error> {
            Ok(Version::new())
        }

        async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
            let p = if path == "." || path.is_empty() {
                "/".to_string()
            } else {
                path
            };
            Ok(Name {
                id,
                files: vec![File::new(p, FileAttributes::default())],
            })
        }

        async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
            self.dirs_read.insert(path.clone(), false);
            Ok(Handle { id, handle: path.into() })
        }

        async fn readdir(&mut self, id: u32, handle: russh_sftp::protocol::SftpHandle) -> Result<Name, Self::Error> {
            let key = String::from_utf8_lossy(handle.as_bytes()).to_string();
            if *self.dirs_read.get(&key).unwrap_or(&true) {
                return Err(StatusCode::Eof);
            }
            self.dirs_read.insert(key, true);
            let mut out = Vec::new();
            if let Ok(rd) = std::fs::read_dir(&self.root) {
                for e in rd.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    let mut attrs = FileAttributes::default();
                    if let Ok(md) = e.metadata() {
                        attrs.size = Some(md.len());
                        attrs.permissions = Some(if md.is_dir() { 0o040755 } else { 0o100644 });
                    }
                    out.push(File::new(name, attrs));
                }
            }
            Ok(Name { id, files: out })
        }

        async fn open(
            &mut self,
            id: u32,
            filename: String,
            pflags: OpenFlags,
            _attrs: FileAttributes,
        ) -> Result<Handle, Self::Error> {
            if pflags.contains(OpenFlags::READ) && !pflags.contains(OpenFlags::WRITE) {
                if let Some(gate) = self.open_gate.as_ref() {
                    gate.started.notify_one();
                    gate.release.notified().await;
                }
            }
            let clean = filename.trim_start_matches('/');
            let full = self.root.join(clean);
            if pflags.contains(OpenFlags::CREATE) {
                let _ = std::fs::File::create(&full);
            }
            let h = format!("fh_{clean}");
            self.files.insert(h.clone(), full);
            Ok(Handle { id, handle: h.into() })
        }

        async fn read(
            &mut self,
            id: u32,
            handle: russh_sftp::protocol::SftpHandle,
            offset: u64,
            len: u32,
        ) -> Result<russh_sftp::protocol::Data, Self::Error> {
            let key = String::from_utf8_lossy(handle.as_bytes()).to_string();
            let p = self.files.get(&key).ok_or(StatusCode::NoSuchFile)?;
            let bytes = std::fs::read(p).map_err(|_| StatusCode::Failure)?;
            if offset as usize >= bytes.len() {
                return Err(StatusCode::Eof);
            }
            let end = (offset as usize + len as usize).min(bytes.len());
            Ok(russh_sftp::protocol::Data {
                id,
                data: bytes[offset as usize..end].to_vec(),
            })
        }

        async fn write(
            &mut self,
            id: u32,
            handle: russh_sftp::protocol::SftpHandle,
            offset: u64,
            data: Vec<u8>,
        ) -> Result<Status, Self::Error> {
            use std::io::{Seek, SeekFrom, Write};
            let key = String::from_utf8_lossy(handle.as_bytes()).to_string();
            let p = self.files.get(&key).ok_or(StatusCode::NoSuchFile)?;
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(p)
                .map_err(|_| StatusCode::Failure)?;
            f.seek(SeekFrom::Start(offset))
                .map_err(|_| StatusCode::Failure)?;
            f.write_all(&data).map_err(|_| StatusCode::Failure)?;
            Ok(Status {
                id,
                status_code: StatusCode::Ok,
                error_message: "Ok".into(),
                language_tag: "en-US".into(),
            })
        }

        #[cfg(unix)]
        async fn setstat(
            &mut self,
            id: u32,
            path: String,
            attributes: FileAttributes,
        ) -> Result<Status, Self::Error> {
            use std::os::unix::fs::PermissionsExt;
            // This wire fixture deliberately has no STAT implementation.
            // chmod must send only permissions, without resending stale file
            // size, ownership or times from a metadata request.
            if attributes.size.is_some() || attributes.uid.is_some() || attributes.gid.is_some()
                || attributes.user.is_some() || attributes.group.is_some()
                || attributes.atime.is_some() || attributes.mtime.is_some()
            {
                return Err(StatusCode::BadMessage);
            }
            let permissions = attributes.permissions.ok_or(StatusCode::BadMessage)?;
            std::fs::set_permissions(
                self.root.join(path.trim_start_matches('/')),
                std::fs::Permissions::from_mode(permissions),
            ).map_err(|_| StatusCode::Failure)?;
            Ok(Status {
                id, status_code: StatusCode::Ok,
                error_message: "Ok".into(), language_tag: "en-US".into(),
            })
        }

        async fn close(&mut self, id: u32, _handle: russh_sftp::protocol::SftpHandle) -> Result<Status, Self::Error> {
            Ok(Status {
                id,
                status_code: StatusCode::Ok,
                error_message: "Ok".into(),
                language_tag: "en-US".into(),
            })
        }
    }

    #[tokio::test]
    async fn live_ssh_requires_interactive_key_or_ca_approval_and_cancels_on_vault_lock() {
        use russh::keys::ssh_key::certificate::{Builder, CertType};
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        for use_certificate in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("known_hosts");
            let leaf = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
            let ca = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
            let expected_leaf = leaf.public_key().fingerprint(HashAlg::Sha256).to_string();
            let expected_trust = if use_certificate { ca.public_key() } else { leaf.public_key() }
                .fingerprint(HashAlg::Sha256).to_string();
            let certificates = if use_certificate {
                let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
                let mut certificate = Builder::new(vec![7; 16], leaf.public_key().key_data().clone(), now - 60, now + 3600).unwrap();
                certificate.cert_type(CertType::Host).unwrap();
                certificate.valid_principal("127.0.0.1").unwrap();
                vec![certificate.sign(&ca).unwrap()]
            } else { vec![] };
            let config = Arc::new(server::Config {
                keys: vec![leaf], certificates,
                auth_rejection_time: Duration::from_millis(10),
                ..Default::default()
            });
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let mut server = TestSshServer { root_dir: directory.path().to_path_buf(), sftp_open_gate: None };
            let fixture = tokio::spawn(async move { server.run_on_socket(config, &listener).await });
            let host = Host { hostname: "127.0.0.1".into(), port, ..Default::default() };
            let mut effective = core_model::resolve_effective_host_config(&host, &[], &[], &[], &[], &[], true);
            effective.identity = Some(Identity { username: "tester".into(), ..Default::default() });
            effective.credential = Some(Credential { secret: Some("pass123".into()), ..Default::default() });
            let connect = |effective: EffectiveHostConfig, path: PathBuf| tokio::spawn(async move {
                connect_ssh_client(&effective, None, &path).await
            });

            let rejected = connect(effective.clone(), path.clone());
            let prompt = host_keys::tests::wait_for_prompt(&path).await;
            assert_eq!(prompt.certificate_authority, use_certificate);
            assert_eq!(prompt.fingerprint, expected_trust);
            assert_eq!(prompt.server_key_fingerprint, expected_leaf);
            assert!(!path.exists());
            host_keys::decide(&path, &prompt.request_id, "reject", &prompt.fingerprint).unwrap();
            assert!(tokio::time::timeout(Duration::from_secs(5), rejected).await.unwrap().unwrap().is_err());
            assert!(!path.exists());

            let accepted = connect(effective.clone(), path.clone());
            let prompt = host_keys::tests::wait_for_prompt(&path).await;
            host_keys::decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).unwrap();
            let ssh = tokio::time::timeout(Duration::from_secs(5), accepted).await.unwrap().unwrap().unwrap();
            assert_eq!(ssh.server_fingerprint, Some(expected_leaf));
            open_sftp_session(&ssh).await.unwrap();
            let record = host_keys::list_records(&path).unwrap().remove(0);
            assert_eq!(record.certificate_authority, use_certificate);
            assert_eq!(record.fingerprint, expected_trust);
            let reconnected = connect_ssh_client(&effective, None, &path).await.unwrap();
            assert_eq!(reconnected.server_fingerprint, ssh.server_fingerprint);
            assert!(host_keys::list_pending(&path).unwrap().is_empty());

            host_keys::remove_record(&path, &record.record_id, &record.fingerprint).unwrap();
            let cancelled = connect(effective, path.clone());
            host_keys::tests::wait_for_prompt(&path).await;
            host_keys::cancel_pending().unwrap();
            assert!(tokio::time::timeout(Duration::from_secs(5), cancelled).await.unwrap().unwrap().is_err());
            assert!(host_keys::list_pending(&path).unwrap().is_empty());
            assert!(host_keys::list_records(&path).unwrap().is_empty());
            fixture.abort();
        }
    }

    async fn spawn_test_ssh_server(root_dir: PathBuf, known_hosts: &std::path::Path) -> u16 {
        spawn_test_ssh_server_with_open_gate(root_dir, known_hosts, None).await
    }

    async fn spawn_test_ssh_server_with_open_gate(
        root_dir: PathBuf,
        known_hosts: &std::path::Path,
        sftp_open_gate: Option<Arc<TestSftpOpenGate>>,
    ) -> u16 {
        let host_key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // These protocol regression tests explicitly provision their own key.
        // First-use approval itself is exercised separately through live SSH.
        host_keys::import_public_key(known_hosts, "127.0.0.1", port,
            &host_key.public_key().to_openssh().unwrap(), false, false,
            &host_key.public_key().fingerprint(HashAlg::Sha256).to_string()).unwrap();
        let config = Arc::new(server::Config {
            keys: vec![host_key],
            auth_rejection_time: Duration::from_millis(10),
            ..Default::default()
        });
        let mut srv = TestSshServer { root_dir, sftp_open_gate };
        tokio::spawn(async move {
            let _ = srv.run_on_socket(config, &listener).await;
        });
        port
    }

    async fn connect_protocol_test_ssh(directory: &std::path::Path) -> SshClientHandle {
        connect_protocol_test_ssh_with_open_gate(directory, None).await
    }

    async fn connect_protocol_test_ssh_with_open_gate(
        directory: &std::path::Path,
        gate: Option<Arc<TestSftpOpenGate>>,
    ) -> SshClientHandle {
        let known_hosts = directory.join("known_hosts");
        let port = spawn_test_ssh_server_with_open_gate(directory.to_path_buf(), &known_hosts, gate).await;
        let host = Host { hostname: "127.0.0.1".into(), port, ..Default::default() };
        let mut effective = core_model::resolve_effective_host_config(
            &host, &[], &[], &[], &[], &[], true,
        );
        effective.identity = Some(Identity { username: "tester".into(), ..Default::default() });
        effective.credential = Some(Credential { secret: Some("pass123".into()), ..Default::default() });
        connect_ssh_client(&effective, None, &known_hosts).await.unwrap()
    }

    #[tokio::test]
    async fn ssh_authentication_reports_rejection_timeout_and_disconnect_separately() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let known_hosts = directory.path().join("known_hosts");
        let port = spawn_test_ssh_server(directory.path().to_path_buf(), &known_hosts).await;
        let host = Host { hostname: "127.0.0.1".into(), port, ..Default::default() };
        let mut effective = core_model::resolve_effective_host_config(
            &host, &[], &[], &[], &[], &[], true,
        );
        effective.identity = Some(Identity { username: "tester".into(), ..Default::default() });
        effective.credential = Some(Credential { secret: Some("wrong-password-regression".into()), ..Default::default() });

        // A real SSH USERAUTH_FAILURE must finish promptly, not wait for the
        // authentication deadline or leak the supplied password in diagnostics.
        let rejected = tokio::time::timeout(Duration::from_secs(2),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.expect("Rejected credentials must not wait for the 15-second timeout")
            .err().expect("Wrong password must fail");
        assert!(matches!(rejected, TransportError::AuthFailed), "{rejected}");
        assert!(rejected.to_string().starts_with("SSH_AUTHENTICATION_REJECTED:"));
        assert!(!rejected.to_string().contains("wrong-password-regression"));

        effective.identity.as_mut().unwrap().username = "wrong-user".into();
        effective.credential.as_mut().unwrap().secret = Some("pass123".into());
        let rejected_user = tokio::time::timeout(Duration::from_secs(2),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.unwrap().err().unwrap();
        assert!(matches!(rejected_user, TransportError::AuthFailed), "{rejected_user}");

        effective.identity.as_mut().unwrap().username = "auth_stall".into();
        let timed_out = connect_ssh_client_with_auth_timeout(
            &effective, None, &known_hosts, Duration::from_millis(100),
        ).await.err().unwrap();
        assert!(matches!(timed_out, TransportError::AuthTimeout { target: "SSH", .. }), "{timed_out}");
        assert!(!timed_out.to_string().contains("REJECTED"));

        effective.identity.as_mut().unwrap().username = "auth_disconnect".into();
        let interrupted = tokio::time::timeout(Duration::from_secs(2),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.unwrap().err().unwrap();
        assert!(matches!(interrupted, TransportError::AuthInterrupted(_)), "{interrupted}");

        effective.identity.as_mut().unwrap().username = "tester".into();
        let accepted = tokio::time::timeout(Duration::from_secs(2),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.unwrap().expect("Correct credentials must still authenticate after failed attempts");
        assert!(accepted.server_fingerprint.is_some());
    }

    #[test]
    fn ssh_authentication_does_not_call_missing_or_partial_credentials_bad_passwords() {
        let methods = [russh::MethodKind::PublicKey];
        let failure = || client::AuthResult::Failure {
            remaining_methods: methods.as_slice().into(), partial_success: false,
        };
        assert!(matches!(check_ssh_auth_result(failure(), russh::MethodKind::Password),
            Err(TransportError::AuthFailed)));
        assert!(matches!(check_ssh_auth_result(failure(), russh::MethodKind::None),
            Err(TransportError::AuthRequired)));
        assert!(matches!(check_ssh_auth_result(client::AuthResult::Failure {
            remaining_methods: methods.as_slice().into(), partial_success: true,
        }, russh::MethodKind::PublicKey), Err(TransportError::AuthAdditionalRequired)));
        assert!(matches!(check_ssh_auth_result(client::AuthResult::Failure {
            remaining_methods: russh::MethodSet::empty(), partial_success: false,
        }, russh::MethodKind::Password), Err(TransportError::AuthInterrupted(_))));
    }

    #[tokio::test]
    async fn ssh_connection_and_handshake_errors_do_not_report_authentication_failure() {
        let directory = tempfile::tempdir().unwrap();
        let known_hosts = directory.path().join("known_hosts");
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = Host { hostname: "127.0.0.1".into(), port: listener.local_addr().unwrap().port(), ..Default::default() };
        let effective = core_model::resolve_effective_host_config(&host, &[], &[], &[], &[], &[], true);
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            stream.write_all(b"This is not an SSH server\r\n").await.unwrap();
        });
        let handshake = tokio::time::timeout(Duration::from_secs(20),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.expect("Invalid SSH banner did not close the handshake").err().unwrap();
        assert!(matches!(handshake, TransportError::SshHandshake(_)), "{handshake}");
        peer.await.unwrap();
        // Give the OS's refused-connect path time to complete, above the
        // production 15-second deadline. This checks category, not TCP latency.
        let network = tokio::time::timeout(Duration::from_secs(20),
            connect_ssh_client(&effective, None, &known_hosts),
        ).await.expect("Refused loopback connection did not complete").err().unwrap();
        assert!(matches!(network, TransportError::SshConnection(_)), "{network}");
    }

    #[tokio::test]
    async fn ssh_shell_waits_for_each_request_and_preserves_early_output() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let ssh = connect_protocol_test_ssh(directory.path()).await;
        for (name, request) in [("TEST_PTY_MODE", "PTY"), ("TEST_SHELL_MODE", "shell")] {
            for mode in ["reject", "close"] {
                let environment = BTreeMap::from([(name.into(), mode.into())]);
                let result = tokio::time::timeout(Duration::from_secs(2),
                    spawn_ssh_shell_with_env(&ssh, 80, 24, Some("must not run".into()), &environment),
                ).await.unwrap();
                let error = result.err().expect("Rejected SSH setup must not announce a session").to_string();
                assert!(error.contains(request), "{error}");
            }
        }
        let environment = BTreeMap::from([
            ("TEST_PTY_MODE".into(), "prelude".into()),
            ("TEST_SHELL_MODE".into(), "prelude".into()),
        ]);
        let (input, mut output) = spawn_ssh_shell_with_env(&ssh, 80, 24, None, &environment).await.unwrap();
        let mut bytes = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), async {
            while !String::from_utf8_lossy(&bytes).contains("WELCOME_TERMPULSE") {
                match output.recv().await {
                    Some(SessionOutput::Data(data)) => bytes.extend_from_slice(&data),
                    other => panic!("Shell ended before its greeting: {other:?}"),
                }
            }
        }).await.unwrap();
        assert!(bytes.starts_with(b"PTY_PRELUDE\r\nSHELL_PRELUDE\r\nWELCOME_TERMPULSE\r\n"));
        input.send(SessionInput::Close).await.unwrap();
    }

    #[tokio::test]
    async fn ssh_shell_unanswered_requests_time_out_instead_of_creating_sessions() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let ssh = connect_protocol_test_ssh(directory.path()).await;
        let pty = BTreeMap::from([("TEST_PTY_MODE".into(), "ignore".into())]);
        let shell = BTreeMap::from([("TEST_SHELL_MODE".into(), "ignore".into())]);
        let (pty_result, shell_result) = tokio::time::timeout(Duration::from_secs(7), async {
            tokio::join!(
                spawn_ssh_shell_with_env(&ssh, 80, 24, None, &pty),
                spawn_ssh_shell_with_env(&ssh, 80, 24, None, &shell),
            )
        }).await.unwrap();
        for (result, request) in [(pty_result, "PTY"), (shell_result, "shell")] {
            let error = result.err().expect("Unanswered setup request must fail").to_string();
            assert!(error.contains(request) && error.contains("5 giây"), "{error}");
        }
    }

    #[tokio::test]
    async fn ssh_exec_reports_rejection_exit_status_signal_timeout_and_output_limit() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let ssh = connect_protocol_test_ssh(directory.path()).await;
        for (command, expected) in [
            ("EXEC_REJECT", "từ chối"),
            ("EXEC_EXIT_23", "23: proc unavailable"),
            ("EXEC_SIGNAL", "TERM"),
            ("EXEC_LARGE", "1 MiB"),
        ] {
            let error = exec_ssh_command(&ssh, command, Duration::from_secs(2))
                .await.err().expect("A failed SSH command must not return successful output").to_string();
            assert!(error.contains(expected), "{command}: {error}");
        }
        let error = exec_ssh_command(&ssh, "EXEC_STALL", Duration::from_millis(100))
            .await.err().unwrap().to_string();
        assert!(error.contains("timed out"), "{error}");
        assert_eq!(exec_ssh_command(&ssh, "EXEC_STDERR_OK", Duration::from_secs(2)).await.unwrap(), "stdout only\n");
        assert_eq!(exec_ssh_command(&ssh, "EXEC_LEGACY", Duration::from_secs(2)).await.unwrap(), "EXEC_OK\n");
    }

    #[cfg(not(target_os = "ios"))]
    #[tokio::test]
    async fn local_shell_rejects_missing_and_regular_file_startup_directories() {
        let directory = tempfile::tempdir().unwrap();
        let regular_file = directory.path().join("ordinary-file.txt");
        std::fs::write(&regular_file, b"not a directory").unwrap();
        for invalid in [directory.path().join("missing-directory"), regular_file] {
            let error = spawn_local_shell(80, 24, Some(invalid.to_string_lossy().into_owned()))
                .err().expect("An invalid startup directory must not silently open HOME").to_string();
            assert!(error.contains("Thư mục khởi động"), "{error}");
        }
    }

    #[cfg(all(unix, not(target_os = "ios")))]
    #[tokio::test]
    async fn local_shell_starts_in_the_configured_directory_with_spaces() {
        let directory = tempfile::tempdir().unwrap();
        let startup = directory.path().join("folder with spaces");
        std::fs::create_dir(&startup).unwrap();
        let startup = startup.canonicalize().unwrap();
        let expected_line = format!("\n{}\n", startup.display());
        let (input, mut output) = spawn_local_shell(80, 24, Some(startup.to_string_lossy().into_owned())).unwrap();
        input.send(SessionInput::Bytes(
            b"printf '\\nTERMPULSE_CWD_BEGIN\\n'; pwd -P; printf 'TERMPULSE_CWD_END\\n'; exit\n".to_vec(),
        )).await.unwrap();
        let mut collected = String::new();
        tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(event) = output.recv().await {
                match event {
                    SessionOutput::Data(bytes) => {
                        collected.push_str(&String::from_utf8_lossy(&bytes));
                        if collected.replace('\r', "").contains(&expected_line) {
                            break;
                        }
                    }
                    SessionOutput::Closed(_) => break,
                }
            }
        }).await.unwrap();
        let _ = input.send(SessionInput::Close).await;
        assert!(collected.replace('\r', "").contains(&expected_line), "Shell did not start in its configured directory: {collected}");
    }

    #[cfg(not(target_os = "ios"))]
    #[tokio::test]
    async fn local_shell_close_stops_a_shell_waiting_for_input() {
        let (input, mut output) = spawn_local_shell(80, 24, None).unwrap();
        input.send(SessionInput::Close).await.unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                match output.recv().await {
                    Some(SessionOutput::Closed(_)) | None => break,
                    _ => {},
                }
            }
        }).await.expect("Closing a local tab must terminate its child even when the shell waits for input");
    }

    #[tokio::test]
    async fn sftp_precancelled_transfers_preserve_destinations_and_do_not_create_files() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.txt");
        std::fs::write(&source, b"new transfer contents").unwrap();
        let ssh = connect_protocol_test_ssh(directory.path()).await;
        let sftp = open_sftp_session(&ssh).await.unwrap();
        for upload in [true, false] {
            for existing in [true, false] {
                let name = format!("cancelled-{}-{existing}.txt", if upload { "upload" } else { "download" });
                let destination = directory.path().join(&name);
                if existing {
                    std::fs::write(&destination, b"existing contents must survive").unwrap();
                }
                let control = Arc::new(TransferControl::default());
                control.cancelled.store(true, Ordering::Relaxed);
                let result = if upload {
                    sftp_upload_file(&sftp, source.to_str().unwrap(), &format!("/{name}"), control,
                        |_, _| panic!("A cancelled upload must not report progress"),
                    ).await
                } else {
                    sftp_download_file(&sftp, "/source.txt", destination.to_str().unwrap(), control,
                        |_, _| panic!("A cancelled download must not report progress"),
                    ).await
                };
                assert!(result.unwrap_err().to_string().contains("huỷ"));
                if existing {
                    assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents must survive");
                } else {
                    assert!(!destination.exists(), "Created destination for cancelled transfer: {name}");
                }
            }
        }
    }

    #[tokio::test]
    async fn sftp_initially_paused_transfers_wait_before_truncation_and_can_be_cancelled() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.txt");
        std::fs::write(&source, b"new transfer contents").unwrap();
        let ssh = connect_protocol_test_ssh(directory.path()).await;
        let sftp = Arc::new(open_sftp_session(&ssh).await.unwrap());
        for upload in [true, false] {
            for existing in [true, false] {
                let name = format!("paused-{}-{existing}.txt", if upload { "upload" } else { "download" });
                let destination = directory.path().join(&name);
                if existing {
                    std::fs::write(&destination, b"existing contents must survive").unwrap();
                }
                let control = Arc::new(TransferControl::default());
                control.paused.store(true, Ordering::Relaxed);
                let task_control = control.clone();
                let task_sftp = sftp.clone();
                let local_path = if upload { source.clone() } else { destination.clone() };
                let remote_path = if upload { format!("/{name}") } else { "/source.txt".into() };
                let transfer = tokio::spawn(async move {
                    if upload {
                        sftp_upload_file(&task_sftp, local_path.to_str().unwrap(), &remote_path, task_control,
                            |_, _| panic!("A paused upload must not report progress"),
                        ).await
                    } else {
                        sftp_download_file(&task_sftp, &remote_path, local_path.to_str().unwrap(), task_control,
                            |_, _| panic!("A paused download must not report progress"),
                        ).await
                    }
                });
                tokio::time::sleep(Duration::from_millis(150)).await;
                assert!(!transfer.is_finished(), "Paused transfer completed unexpectedly");
                if existing {
                    assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents must survive");
                } else {
                    assert!(!destination.exists(), "Created destination while paused: {name}");
                }
                control.cancelled.store(true, Ordering::Relaxed);
                let result = tokio::time::timeout(Duration::from_secs(2), transfer).await.unwrap().unwrap();
                assert!(result.unwrap_err().to_string().contains("huỷ"));
                if existing {
                    assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents must survive");
                } else {
                    assert!(!destination.exists(), "Created destination after cancellation: {name}");
                }
            }
        }
    }

    #[tokio::test]
    async fn sftp_download_rechecks_pause_and_cancel_after_remote_preflight() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("source.txt"), b"download contents").unwrap();
        let gate = Arc::new(TestSftpOpenGate::default());
        let ssh = connect_protocol_test_ssh_with_open_gate(directory.path(), Some(gate.clone())).await;
        let sftp = Arc::new(open_sftp_session(&ssh).await.unwrap());
        for pause_first in [true, false] {
            for existing in [true, false] {
                let destination = directory.path().join(format!("preflight-{pause_first}-{existing}.txt"));
                if existing {
                    std::fs::write(&destination, b"existing contents must survive").unwrap();
                }
                let control = Arc::new(TransferControl::default());
                let task_control = control.clone();
                let task_sftp = sftp.clone();
                let local_path = destination.to_string_lossy().into_owned();
                let transfer = tokio::spawn(async move {
                    sftp_download_file(&task_sftp, "/source.txt", &local_path, task_control,
                        |_, _| panic!("A download cancelled during preflight must not report progress"),
                    ).await
                });
                tokio::time::timeout(Duration::from_secs(2), gate.started.notified()).await.unwrap();
                // Hold the real SFTP OPEN response until the control changes.
                if pause_first {
                    control.paused.store(true, Ordering::Relaxed);
                } else {
                    control.cancelled.store(true, Ordering::Relaxed);
                }
                gate.release.notify_one();
                if pause_first {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    assert!(!transfer.is_finished(), "Download ignored a pause during preflight");
                    if existing {
                        assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents must survive");
                    } else {
                        assert!(!destination.exists(), "Download created its destination while paused");
                    }
                    control.cancelled.store(true, Ordering::Relaxed);
                }
                let result = tokio::time::timeout(Duration::from_secs(2), transfer).await.unwrap().unwrap();
                assert!(result.unwrap_err().to_string().contains("huỷ"));
                if existing {
                    assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents must survive");
                } else {
                    assert!(!destination.exists(), "Download created its destination after cancellation");
                }
            }
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sftp_chmod_sends_permissions_only_and_preserves_directory_contents() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let target_directory = directory.path().join("directory");
        std::fs::create_dir(&target_directory).unwrap();
        let target_file = target_directory.join("retained.txt");
        std::fs::write(&target_file, b"content must survive chmod").unwrap();
        let port = spawn_test_ssh_server(directory.path().to_path_buf(), &directory.path().join("known_hosts")).await;
        let host = Host { hostname: "127.0.0.1".into(), port, ..Default::default() };
        let mut effective = core_model::resolve_effective_host_config(
            &host, &[], &[], &[], &[], &[], true,
        );
        effective.identity = Some(Identity { username: "tester".into(), ..Default::default() });
        effective.credential = Some(Credential {
            secret: Some("pass123".into()), ..Default::default()
        });
        let ssh = connect_ssh_client(&effective, None, &directory.path().join("known_hosts")).await.unwrap();
        let sftp = open_sftp_session(&ssh).await.unwrap();
        sftp_chmod(&sftp, "/directory", 0o750).await.unwrap();
        sftp_chmod(&sftp, "/directory/retained.txt", 0o640).await.unwrap();
        assert!(target_directory.is_dir());
        assert_eq!(std::fs::metadata(&target_directory).unwrap().permissions().mode() & 0o777, 0o750);
        assert_eq!(std::fs::metadata(&target_file).unwrap().permissions().mode() & 0o777, 0o640);
        assert_eq!(std::fs::read(&target_file).unwrap(), b"content must survive chmod");
    }

    #[tokio::test]
    async fn end_to_end_ssh_shell_sftp_proc_and_tunnel_lifecycle() {
        tokio::time::timeout(
            Duration::from_secs(60),
            ssh_shell_sftp_proc_and_tunnel_lifecycle(),
        ).await.expect("SSH lifecycle fixture exceeded 60 seconds; inspect its last phase");
    }

    async fn ssh_shell_sftp_proc_and_tunnel_lifecycle() {
        let _trust_test = host_keys::TEST_LOCK.lock().await;
        eprintln!("SSH lifecycle: known-host validation");
        let tmp_dir = tempfile::tempdir().unwrap();
        std::fs::write(tmp_dir.path().join("hello.txt"), b"initial_data").unwrap();
        let ssh_port = spawn_test_ssh_server(tmp_dir.path().to_path_buf(), &tmp_dir.path().join("known_hosts")).await;

        let cred = Credential {
            id: "c1".into(),
            name: "pw".into(),
            kind: CredentialKind::Password,
            secret: Some("pass123".into()),
            ..Default::default()
        };
        let ident = Identity {
            id: "i1".into(),
            name: "t".into(),
            username: "tester".into(),
            credential_id: Some("c1".into()),
        };
        let host = Host {
            id: "h1".into(),
            label: "local-test".into(),
            hostname: "127.0.0.1".into(),
            port: ssh_port,
            identity_mode: IdentityMode::ById,
            identity_id: Some("i1".into()),
            ..Default::default()
        };
        let eff = core_model::resolve_effective_host_config(
            &host,
            &[],
            &[ident],
            &[cred],
            &[],
            &[],
            true,
        );

        let known_hosts = tmp_dir.path().join("known_hosts");
        let ssh = Arc::new(connect_ssh_client(&eff, None, &known_hosts).await.unwrap());
        assert!(ssh.server_fingerprint.as_ref().unwrap().starts_with("SHA256:"));
        let pinned_host = std::fs::read_to_string(&known_hosts).unwrap();
        // Reconnecting to the same live server checks the persisted key instead
        // of adding another record. A different pinned key blocks the handshake.
        let reconnect = connect_ssh_client(&eff, None, &known_hosts).await.unwrap();
        assert_eq!(reconnect.server_fingerprint, ssh.server_fingerprint);
        assert_eq!(std::fs::read_to_string(&known_hosts).unwrap(), pinned_host);
        let changed_key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        std::fs::write(&known_hosts, format!("[127.0.0.1]:{ssh_port} {}\n", changed_key.public_key().to_openssh().unwrap())).unwrap();
        let rejection_path = known_hosts.clone();
        let reject_changed = tokio::spawn(async move {
            let prompt = host_keys::tests::wait_for_prompt(&rejection_path).await;
            assert!(prompt.changed);
            assert_eq!(prompt.hostname, "127.0.0.1");
            assert_eq!(prompt.port, ssh_port);
            host_keys::decide(&rejection_path, &prompt.request_id, "reject", &prompt.fingerprint).unwrap();
        });
        let rejected = connect_ssh_client(&eff, None, &known_hosts).await.err().unwrap();
        reject_changed.await.unwrap();
        assert!(rejected.to_string().contains("HOST KEY ĐÃ THAY ĐỔI"));
        std::fs::write(&known_hosts, pinned_host).unwrap();

        // Both authenticated proxy protocols carry a real SSH shell, with
        // proxy credentials separate from the destination SSH credentials.
        eprintln!("SSH lifecycle: authenticated proxies");
        for kind in [ProxyKind::HttpConnect, ProxyKind::Socks5] {
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let proxy_port = listener.local_addr().unwrap().port();
            let proxy_server = tokio::spawn(async move {
                let (mut client, _) = listener.accept().await.unwrap();
                if kind == ProxyKind::HttpConnect {
                    let mut request = Vec::new();
                    while !request.ends_with(b"\r\n\r\n") {
                        request.push(client.read_u8().await.unwrap());
                    }
                    let request = String::from_utf8(request).unwrap();
                    let expected = format!("Proxy-Authorization: Basic {}", BASE64.encode("proxy-user:test-only-proxy-password"));
                    assert!(request.contains(&expected));
                    client.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
                } else {
                    let mut greeting = [0; 3];
                    client.read_exact(&mut greeting).await.unwrap();
                    assert_eq!(greeting, [5, 1, 2]);
                    client.write_all(&[5, 2]).await.unwrap();
                    assert_eq!(client.read_u8().await.unwrap(), 1);
                    let user_length = client.read_u8().await.unwrap() as usize;
                    let mut user = vec![0; user_length];
                    client.read_exact(&mut user).await.unwrap();
                    let password_length = client.read_u8().await.unwrap() as usize;
                    let mut password = vec![0; password_length];
                    client.read_exact(&mut password).await.unwrap();
                    assert_eq!(user, b"proxy-user");
                    assert_eq!(password, b"test-only-proxy-password");
                    client.write_all(&[1, 0]).await.unwrap();
                    let mut request = [0; 10];
                    client.read_exact(&mut request).await.unwrap();
                    assert_eq!(&request[..8], &[5, 1, 0, 1, 127, 0, 0, 1]);
                    assert_eq!(u16::from_be_bytes([request[8], request[9]]), ssh_port);
                    client.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).await.unwrap();
                }
                let mut target = TcpStream::connect(("127.0.0.1", ssh_port)).await.unwrap();
                let _ = tokio::io::copy_bidirectional(&mut client, &mut target).await;
            });
            let mut proxied = eff.clone();
            proxied.proxy = Some(ProxyConfig {
                id: "wire-proxy".into(), name: "Wire proxy".into(), kind,
                host: "127.0.0.1".into(), port: proxy_port,
                username: Some("proxy-user".into()), credential_id: Some("proxy-password".into()),
                ..Default::default()
            });
            proxied.proxy_credential = Some(proxy_test_credential());
            let proxied_ssh = connect_ssh_client(&proxied, None, &known_hosts).await.unwrap();
            assert_eq!(proxied_ssh.server_fingerprint, ssh.server_fingerprint);
            let (input, mut output) = spawn_ssh_shell(&proxied_ssh, 80, 24, None).await.unwrap();
            let welcome = tokio::time::timeout(Duration::from_secs(2), output.recv()).await.unwrap().unwrap();
            assert!(matches!(welcome, SessionOutput::Data(bytes) if String::from_utf8_lossy(&bytes).contains("WELCOME_TERMPULSE")));
            input.send(SessionInput::Close).await.unwrap();
            proxy_server.abort();
        }

        // 1. Shell + OSC-7 CWD tracking
        eprintln!("SSH lifecycle: shell and environment");
        let (tx, mut rx) = spawn_ssh_shell(&ssh, 80, 24, None).await.unwrap();
        let first = rx.recv().await.unwrap();
        assert!(matches!(first, SessionOutput::Data(b) if String::from_utf8_lossy(&b).contains("WELCOME_TERMPULSE")));
        tx.send(SessionInput::Bytes(b"cd /var/log\n".to_vec())).await.unwrap();
        let second = rx.recv().await.unwrap();
        if let SessionOutput::Data(bytes) = second {
            let mut insp = core_terminal::TerminalStreamInspector::new();
            let evs = insp.feed(&bytes);
            assert!(evs.contains(&core_terminal::TerminalPassiveEvent::CwdChanged("/var/log".into())));
        }

        // Environment requests preserve literal values and fail visibly on server rejection.
        let environment = BTreeMap::from([
            ("TERMPULSE_ENV".into(), "spaces; '$HOME'\nUnicode: Tiếng Việt".into()),
            ("LC_TEST".into(), "C.UTF-8".into()),
        ]);
        let (env_input, mut env_output) = spawn_ssh_shell_with_env(&ssh, 80, 24, None, &environment).await.unwrap();
        let expected_environment = serde_json::to_string(&environment).unwrap();
        let mut greeting = String::new();
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(SessionOutput::Data(bytes)) = env_output.recv().await {
                greeting.push_str(&String::from_utf8_lossy(&bytes));
                if greeting.contains(&expected_environment) { break; }
            }
        }).await.unwrap();
        assert!(greeting.contains(&expected_environment));
        env_input.send(SessionInput::Close).await.unwrap();
        let rejected = BTreeMap::from([("REJECT_TEST".into(), "test-value".into())]);
        let error = spawn_ssh_shell_with_env(&ssh, 80, 24, None, &rejected).await.err().unwrap().to_string();
        assert!(error.contains("AcceptEnv"));
        assert!(!error.contains("test-value"));
        let invalid = BTreeMap::from([("BAD;NAME".into(), "value".into())]);
        assert!(spawn_ssh_shell_with_env(&ssh, 80, 24, None, &invalid).await.is_err());

        // 2. SFTP list, read, write
        eprintln!("SSH lifecycle: SFTP");
        let sftp = open_sftp_session(&ssh).await.unwrap();
        let (_cwd, list) = sftp_list_dir(&sftp, ".").await.unwrap();
        assert!(list.iter().any(|e| e.name == "hello.txt"));
        let content = sftp_read_bytes(&sftp, "/hello.txt", 1024).await.unwrap();
        assert_eq!(content, b"initial_data");
        sftp_write_bytes(&sftp, "/uploaded.txt", b"from_rust_sftp").await.unwrap();
        assert_eq!(
            std::fs::read(tmp_dir.path().join("uploaded.txt")).unwrap(),
            b"from_rust_sftp"
        );

        // 3. Agentless /proc monitor
        eprintln!("SSH lifecycle: process metrics");
        let raw_proc = exec_ssh_command(&ssh, PROC_PROBE_SCRIPT, Duration::from_secs(5))
            .await
            .unwrap();
        let (metrics, _) = parse_proc_probe_output(&raw_proc, None);
        assert_eq!(metrics.mem_total_mb, 4096);
        assert_eq!(metrics.mem_used_mb, 1024);
        assert_eq!(metrics.uptime_secs, 3600);

        // 4. Independent Local Tunnel (-L)
        eprintln!("SSH lifecycle: local tunnel");
        let echo_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let echo_port = echo_listener.local_addr().unwrap().port();
        let echo_task = tokio::spawn(async move {
            while let Ok((mut s, _)) = echo_listener.accept().await {
                tokio::spawn(async move {
                let mut b = [0u8; 64];
                loop {
                    match s.read(&mut b).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => if s.write_all(&b[..n]).await.is_err() { break; },
                    }
                }
                });
            }
        });

        let mut tunnel = start_ssh_tunnel(
            TunnelRule {
                id: "t1".into(),
                name: "Echo".into(),
                host_id: "h1".into(),
                kind: TunnelKind::Local,
                bind_addr: "127.0.0.1".into(),
                bind_port: 0,
                target_host: Some("127.0.0.1".into()),
                target_port: Some(echo_port),
                auto_start: false,
            },
            ssh.clone(),
        )
        .await
        .unwrap();

        let local_port = tunnel.rule.bind_port;
        let mut client_tcp = TcpStream::connect(("127.0.0.1", local_port)).await.unwrap();
        client_tcp.write_all(b"TUNNEL_PING").await.unwrap();
        let mut resp = [0u8; 11];
        client_tcp.read_exact(&mut resp).await.unwrap();
        assert_eq!(&resp, b"TUNNEL_PING");
        tokio::time::sleep(Duration::from_millis(40)).await;
        let st = tunnel.status().await;
        assert!(st.running);
        tunnel.stop_and_wait().await;
        let mut closed = [0; 1];
        assert_eq!(tokio::time::timeout(Duration::from_secs(2), client_tcp.read(&mut closed)).await.unwrap().unwrap(), 0);
        let rebound = TcpListener::bind(("127.0.0.1", local_port)).await.unwrap();
        drop(rebound);

        // Dynamic SOCKS refuses unsupported auth and closes live streams on stop.
        eprintln!("SSH lifecycle: dynamic SOCKS tunnel");
        let mut dynamic = start_ssh_tunnel(TunnelRule {
            id: "dynamic".into(), name: "SOCKS".into(), host_id: "h1".into(),
            kind: TunnelKind::DynamicSocks, bind_addr: "127.0.0.1".into(), bind_port: 0,
            target_host: None, target_port: None, auto_start: false,
        }, ssh.clone()).await.unwrap();
        let mut unsupported = TcpStream::connect(("127.0.0.1", dynamic.rule.bind_port)).await.unwrap();
        unsupported.write_all(&[5, 1, 2]).await.unwrap();
        let mut auth_reply = [0; 2];
        unsupported.read_exact(&mut auth_reply).await.unwrap();
        assert_eq!(auth_reply, [5, 255]);
        let mut socks = TcpStream::connect(("127.0.0.1", dynamic.rule.bind_port)).await.unwrap();
        socks.write_all(&[5, 1, 0]).await.unwrap();
        socks.read_exact(&mut auth_reply).await.unwrap();
        assert_eq!(auth_reply, [5, 0]);
        let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1];
        request.extend_from_slice(&echo_port.to_be_bytes());
        socks.write_all(&request).await.unwrap();
        let mut connected_reply = [0; 10];
        socks.read_exact(&mut connected_reply).await.unwrap();
        assert_eq!(connected_reply[1], 0);
        socks.write_all(b"SOCKS").await.unwrap();
        let mut socks_echo = [0; 5];
        socks.read_exact(&mut socks_echo).await.unwrap();
        assert_eq!(&socks_echo, b"SOCKS");
        dynamic.stop_and_wait().await;
        assert_eq!(tokio::time::timeout(Duration::from_secs(2), socks.read(&mut closed)).await.unwrap().unwrap(), 0);

        // Remote stop sends cancel-tcpip-forward, removes routing, and closes clients.
        eprintln!("SSH lifecycle: remote tunnel");
        let mut remote = start_ssh_tunnel(TunnelRule {
            id: "remote".into(), name: "Remote".into(), host_id: "h1".into(),
            kind: TunnelKind::Remote, bind_addr: "127.0.0.1".into(), bind_port: 0,
            target_host: Some("127.0.0.1".into()), target_port: Some(echo_port), auto_start: false,
        }, ssh.clone()).await.unwrap();
        let remote_port = remote.rule.bind_port;
        let mut forwarded = TcpStream::connect(("127.0.0.1", remote_port)).await.unwrap();
        forwarded.write_all(b"REMOTE").await.unwrap();
        let mut remote_echo = [0; 6];
        tokio::time::timeout(Duration::from_secs(2), forwarded.read_exact(&mut remote_echo)).await.unwrap().unwrap();
        assert_eq!(&remote_echo, b"REMOTE");
        remote.stop_and_wait().await;
        assert!(ssh.forwarded_map.lock().await.is_empty());
        assert_eq!(tokio::time::timeout(Duration::from_secs(2), forwarded.read(&mut closed)).await.unwrap().unwrap(), 0);
        let rebound = TcpListener::bind(("127.0.0.1", remote_port)).await.unwrap();
        drop(rebound);
        echo_task.abort();

        // 5. Desktop local PTY smoke test
        #[cfg(not(target_os = "ios"))]
        {
            eprintln!("SSH lifecycle: local PTY");
            let (pty_in, mut pty_out) = spawn_local_shell(80, 24, None).unwrap();
            let command = if cfg!(windows) {
                b"echo LOCAL_PTY_OK\rexit\r".as_slice()
            } else {
                b"echo LOCAL_PTY_OK\nexit\n".as_slice()
            };
            pty_in
                .send(SessionInput::Bytes(command.to_vec()))
                .await
                .unwrap();
            let mut collected = String::new();
            while let Ok(Some(SessionOutput::Data(d))) =
                tokio::time::timeout(Duration::from_secs(3), pty_out.recv()).await
            {
                collected.push_str(&String::from_utf8_lossy(&d));
                if collected.contains("LOCAL_PTY_OK") {
                    break;
                }
            }
            // Stop while the runtime is still alive. Dropping the sender at
            // test teardown can cancel the task before its ConPTY child kill.
            let _ = pty_in.send(SessionInput::Close).await;
            tokio::time::timeout(Duration::from_secs(5), async {
                while let Some(event) = pty_out.recv().await {
                    if matches!(event, SessionOutput::Closed(_)) {
                        return;
                    }
                }
                panic!("Local PTY output ended without a closed event");
            }).await.expect("Local PTY did not close before runtime teardown");
            assert!(collected.contains("LOCAL_PTY_OK"));
        }
        eprintln!("SSH lifecycle: complete");
    }
}
