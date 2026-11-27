//! Embedded RDP/RFB sessions. Secrets are resolved inside the unlocked Vault.
//! The Flutter view receives bounded RGBA framebuffers and sends native input.
use crate::frb_generated::StreamSink;
use crate::state::{state, with_vault};
use core_model::{resolve_effective_host_config, CredentialKind, ProtocolKind};
use ironrdp::connector::{self, Credentials};
use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp::input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use ironrdp::pdu::gcc::KeyboardType;
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{ActiveStageBuilder, ActiveStageOutput};
use ironrdp_tokio::{FramedWrite, TokioFramed};
use once_cell::sync::Lazy;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio_rustls::rustls;
use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use vnc::{PixelFormat as VncPixelFormat, Rect, VncConnector, VncEncoding, VncEvent, X11Event};
use x509_cert::der::Decode;

const MAX_PIXELS: usize = 8_294_400;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const TEXT_LIMIT: usize = 16_384;
// Bound time spent draining pointer motion so graphics, keys and cancellation
// continue to make progress even while a mouse/touchpad produces new events.
const MAX_POINTER_COALESCE: usize = 64;

#[derive(Clone)]
pub struct RemoteDesktopConfigDto {
    pub protocol: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub domain: Option<String>,
    pub width: u16,
    pub height: u16,
    pub tls_server_name: Option<String>,
    pub tls_ca_pem: Option<String>,
    /// Explicitly confirmed SHA256 of the leaf DER certificate (hex, optional colons).
    pub tls_certificate_sha256: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RemoteDesktopEventDto {
    /// connecting, connected, frame, clipboard, heartbeat, error, or closed.
    pub kind: String,
    pub session_id: String,
    pub width: u16,
    pub height: u16,
    pub rgba: Vec<u8>,
    pub message: Option<String>,
}

#[derive(Deserialize)]
#[serde(default, deny_unknown_fields)]
#[flutter_rust_bridge::frb(ignore)]
struct SavedOptions {
    domain: Option<String>,
    width: u16,
    height: u16,
    tls_server_name: Option<String>,
    tls_ca_pem: Option<String>,
    tls_certificate_sha256: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl Default for SavedOptions {
    fn default() -> Self {
        Self {
            domain: None,
            width: 1280,
            height: 720,
            tls_server_name: None,
            tls_ca_pem: None,
            tls_certificate_sha256: None,
        }
    }
}

#[derive(Debug)]
#[flutter_rust_bridge::frb(ignore)]
enum RemoteInput {
    Pointer {
        x: u16,
        y: u16,
        buttons: u8,
        scroll_y: i16,
    },
    Key {
        key: u32,
        down: bool,
        unicode: bool,
    },
    Text(String),
    Clipboard(String),
    Close,
}

/// Only replace consecutive motion with the newest position. Button edges,
/// wheel events, keys and text must keep their exact order and coordinates.
fn coalesce_pointer_motion(
    mut input: Option<RemoteInput>,
    rx: &mut mpsc::Receiver<RemoteInput>,
    pending: &mut Option<RemoteInput>,
    current_buttons: u8,
) -> Option<RemoteInput> {
    if !matches!(
        input.as_ref(),
        Some(RemoteInput::Pointer { buttons, scroll_y: 0, .. })
            if *buttons == current_buttons
    ) {
        return input;
    }
    for _ in 0..MAX_POINTER_COALESCE {
        match rx.try_recv() {
            Ok(
                next @ RemoteInput::Pointer {
                    buttons,
                    scroll_y: 0,
                    ..
                },
            ) if buttons == current_buttons => input = Some(next),
            Ok(next) => {
                *pending = Some(next);
                break;
            }
            Err(_) => break,
        }
    }
    input
}

fn desktop_frame_clock() -> tokio::time::Interval {
    let mut interval = tokio::time::interval(Duration::from_millis(50));
    // Rendering a burst of overdue frames after a busy decode/input step only
    // sends stale work to Flutter. Resume at the next display slot instead.
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    interval
}

type Emit = Arc<dyn Fn(RemoteDesktopEventDto) -> Result<(), String> + Send + Sync>;
#[flutter_rust_bridge::frb(ignore)]
struct SessionHandle {
    input: mpsc::Sender<RemoteInput>,
    cancel: oneshot::Sender<()>,
}
static SESSIONS: Lazy<Mutex<HashMap<String, SessionHandle>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn event(
    id: &str,
    kind: &str,
    width: u16,
    height: u16,
    rgba: Vec<u8>,
    message: Option<String>,
) -> RemoteDesktopEventDto {
    RemoteDesktopEventDto {
        kind: kind.into(),
        session_id: id.into(),
        width,
        height,
        rgba,
        message,
    }
}

fn dimensions(width: u16, height: u16) -> Result<usize, String> {
    let pixels = usize::from(width) * usize::from(height);
    if width == 0 || height == 0 || width > 8192 || height > 8192 || pixels > MAX_PIXELS {
        return Err("REMOTE_DESKTOP_INVALID_SIZE: Maximum framebuffer is 8192 pixels per axis and 8,294,400 pixels total.".into());
    }
    Ok(pixels * 4)
}

fn validate(config: &RemoteDesktopConfigDto) -> Result<(), String> {
    if !matches!(config.protocol.as_str(), "rdp" | "vnc") {
        return Err("REMOTE_DESKTOP_PROTOCOL: Choose RDP or VNC.".into());
    }
    if config.hostname.trim().is_empty()
        || config.hostname.chars().any(char::is_control)
        || config.port == 0
    {
        return Err("REMOTE_DESKTOP_ADDRESS: Enter a hostname and a port from 1 to 65535.".into());
    }
    dimensions(config.width, config.height)?;
    if config.protocol == "rdp" && config.username.trim().is_empty() {
        return Err("REMOTE_DESKTOP_USERNAME: Enter the RDP account name.".into());
    }
    if let Some(pin) = config.tls_certificate_sha256.as_deref() {
        normalized_pin(pin)?;
    }
    Ok(())
}

/// Connect a saved host without moving its decrypted credential into Flutter.
pub fn connect_remote_desktop_host(host_id: String, sink: StreamSink<RemoteDesktopEventDto>) {
    let result = with_vault(|store| {
        if !store.is_unlocked() {
            return Err("REMOTE_DESKTOP_VAULT_LOCKED: Unlock the Vault before connecting.".into());
        }
        let host = store
            .get_host(&host_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "REMOTE_DESKTOP_HOST: Saved connection was not found.".to_string())?;
        if !matches!(host.protocol, ProtocolKind::Rdp | ProtocolKind::Vnc) {
            return Err("REMOTE_DESKTOP_PROTOCOL: This is not an RDP or VNC host.".into());
        }
        let options: SavedOptions = match host.remote_desktop_json.as_deref() {
            Some(json) if !json.trim().is_empty() => {
                serde_json::from_str(json).map_err(|e| format!("REMOTE_DESKTOP_CONFIG: {e}"))?
            }
            _ => SavedOptions::default(),
        };
        let effective = resolve_effective_host_config(
            &host,
            &store.list_groups().map_err(|e| e.to_string())?,
            &store.list_identities().map_err(|e| e.to_string())?,
            &store.list_credentials().map_err(|e| e.to_string())?,
            &store.list_hosts().map_err(|e| e.to_string())?,
            &store.list_proxies().map_err(|e| e.to_string())?,
            false,
        );
        if effective.jump_host.is_some() || effective.proxy.is_some() {
            return Err("REMOTE_DESKTOP_PROXY: Embedded RDP/VNC currently require a direct connection; explicitly disable inherited SSH proxy/jump settings.".into());
        }
        if effective
            .credential
            .as_ref()
            .is_some_and(|credential| credential.kind != CredentialKind::Password)
        {
            return Err("REMOTE_DESKTOP_CREDENTIAL: RDP/VNC require a Password credential.".into());
        }
        let config = RemoteDesktopConfigDto {
            protocol: if host.protocol == ProtocolKind::Rdp {
                "rdp"
            } else {
                "vnc"
            }
            .into(),
            hostname: host.hostname,
            port: host.port,
            username: effective
                .identity
                .map(|identity| identity.username)
                .unwrap_or_default(),
            password: effective
                .credential
                .and_then(|credential| credential.secret)
                .unwrap_or_default(),
            domain: options.domain,
            width: options.width,
            height: options.height,
            tls_server_name: options.tls_server_name,
            tls_ca_pem: options.tls_ca_pem,
            tls_certificate_sha256: options.tls_certificate_sha256,
        };
        // Register while the Vault remains locked against concurrent lock/switch
        // operations; those operations cancel every registered native session.
        start(config, Some(host_id), sink.clone());
        Ok(())
    });
    if let Err(error) = result {
        let _ = sink.add_error(error);
    }
}

/// Direct, non-persisted connection; prefer the saved-host API for normal use.
pub fn connect_remote_desktop(
    config: RemoteDesktopConfigDto,
    sink: StreamSink<RemoteDesktopEventDto>,
) {
    start(config, None, sink);
}

fn start(
    config: RemoteDesktopConfigDto,
    host_id: Option<String>,
    sink: StreamSink<RemoteDesktopEventDto>,
) {
    if let Err(error) = validate(&config) {
        let _ = sink.add_error(error);
        return;
    }
    let id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = mpsc::channel(256);
    let (cancel, cancelled) = oneshot::channel();
    let emit: Emit = Arc::new(move |event| {
        sink.add(event)
            .map_err(|_| "REMOTE_DESKTOP_VIEW_CLOSED".into())
    });
    match SESSIONS.lock() {
        Ok(mut sessions) => {
            sessions.insert(id.clone(), SessionHandle { input: tx, cancel });
        }
        Err(_) => {
            let _ = emit(event(
                &id,
                "error",
                0,
                0,
                vec![],
                Some("Session lock error".into()),
            ));
            return;
        }
    }
    // The first event exposes the ID to Flutter, so cancellation must already
    // be registered when that event is delivered.
    if emit(event(&id, "connecting", 0, 0, vec![], None)).is_err() {
        if let Ok(mut sessions) = SESSIONS.lock() {
            sessions.remove(&id);
        }
        return;
    }
    let original_emit = emit;
    let marked = std::sync::atomic::AtomicBool::new(false);
    let emit: Emit = Arc::new(move |event| {
        if event.kind == "connected" && !marked.swap(true, std::sync::atomic::Ordering::Relaxed) {
            if let Some(host_id) = host_id.as_deref() {
                let _ = with_vault(|store| {
                    store
                        .mark_host_connected(host_id)
                        .map_err(|e| e.to_string())
                });
            }
        }
        original_emit(event)
    });
    state().rt.spawn(async move {
        let session = async {
            if config.protocol == "rdp" {
                run_rdp(config, &id, rx, emit.clone()).await
            } else {
                run_vnc(config, &id, rx, emit.clone()).await
            }
        };
        let result = tokio::select! {
            biased;
            _ = cancelled => Ok(()),
            result = session => result,
        };
        if let Ok(mut sessions) = SESSIONS.lock() {
            sessions.remove(&id);
        }
        if let Err(error) = result {
            let _ = emit(event(&id, "error", 0, 0, vec![], Some(error)));
        }
        let _ = emit(event(&id, "closed", 0, 0, vec![], None));
    });
}

fn send(id: String, input: RemoteInput) -> Result<(), String> {
    let tx = SESSIONS
        .lock()
        .map_err(|_| "Session lock error")?
        .get(&id)
        .map(|session| session.input.clone())
        .ok_or_else(|| {
            "REMOTE_DESKTOP_CLOSED: The remote desktop session has ended.".to_string()
        })?;
    tx.try_send(input)
        .map_err(|_| "REMOTE_DESKTOP_BUSY: Input queue is full or the session has closed.".into())
}

/// Buttons use RFB ordering: 1 left, 2 middle, 4 right; scroll_y is wheel units.
pub fn send_remote_desktop_pointer(
    session_id: String,
    x: u16,
    y: u16,
    buttons: u8,
    scroll_y: i16,
) -> Result<(), String> {
    send(
        session_id,
        RemoteInput::Pointer {
            x,
            y,
            buttons,
            scroll_y,
        },
    )
}

/// unicode=false: RDP Set-1 scancode (extended bit 0x100), or VNC/X11 keysym.
/// unicode=true: Unicode scalar value, encoded as RDP UTF-16 or X11 Unicode keysym.
pub fn send_remote_desktop_key(
    session_id: String,
    key: u32,
    down: bool,
    unicode: bool,
) -> Result<(), String> {
    if unicode && char::from_u32(key).is_none() {
        return Err("REMOTE_DESKTOP_KEY: Invalid Unicode scalar.".into());
    }
    send(session_id, RemoteInput::Key { key, down, unicode })
}

/// Type reviewed text as key events; this does not change the remote clipboard.
pub fn send_remote_desktop_text(session_id: String, text: String) -> Result<(), String> {
    if text.len() > TEXT_LIMIT {
        return Err("REMOTE_DESKTOP_TEXT: Send at most 16 KiB at once.".into());
    }
    send(session_id, RemoteInput::Text(text))
}

/// RFB clipboard is Latin-1. RDP CLIPRDR is deliberately not advertised.
pub fn send_remote_desktop_clipboard(session_id: String, text: String) -> Result<(), String> {
    if text.len() > TEXT_LIMIT || text.chars().any(|c| u32::from(c) > 255) {
        return Err("REMOTE_DESKTOP_CLIPBOARD: VNC clipboard accepts up to 16 KiB of Latin-1 text; use Type text for Unicode.".into());
    }
    send(session_id, RemoteInput::Clipboard(text))
}

pub fn close_remote_desktop(session_id: String) -> Result<(), String> {
    let session = SESSIONS
        .lock()
        .map_err(|_| "Session lock error")?
        .remove(&session_id);
    if let Some(session) = session {
        let _ = session.input.try_send(RemoteInput::Close);
        let _ = session.cancel.send(());
    }
    Ok(())
}

/// Called while holding the Vault lock so saved credentials cannot remain in
/// active remote sessions after locking or switching the Vault.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn close_all_remote_desktop_sessions() -> Result<(), String> {
    let sessions: Vec<_> = SESSIONS
        .lock()
        .map_err(|_| "Session lock error")?
        .drain()
        .map(|(_, session)| session)
        .collect();
    for session in sessions {
        let _ = session.input.try_send(RemoteInput::Close);
        let _ = session.cancel.send(());
    }
    Ok(())
}

fn normalized_pin(pin: &str) -> Result<String, String> {
    let pin: String = pin
        .chars()
        .filter(|c| *c != ':' && !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect();
    if pin.len() != 64 || !pin.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("RDP_CERTIFICATE_PIN: Enter all 64 hexadecimal SHA256 digits.".into());
    }
    Ok(pin)
}

fn fingerprint(cert: &[u8]) -> String {
    format!("{:x}", Sha256::digest(cert))
}

#[derive(Debug)]
struct CertificateVerifier {
    pin: Option<String>,
    /// Probe only: no authentication is performed on this connection.
    probe: bool,
    captured: Arc<Mutex<Option<String>>>,
    algorithms: rustls::crypto::WebPkiSupportedAlgorithms,
}

impl rustls::client::danger::ServerCertVerifier for CertificateVerifier {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        let actual = fingerprint(cert.as_ref());
        if let Ok(mut captured) = self.captured.lock() {
            *captured = Some(actual.clone());
        }
        if self.probe || self.pin.as_ref() == Some(&actual) {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "RDP_CERTIFICATE_UNTRUSTED: Certificate fingerprint does not match the saved pin."
                    .into(),
            ))
        }
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, signature, &self.algorithms)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, signature, &self.algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

fn tls_config(
    config: &RemoteDesktopConfigDto,
    probe: bool,
    captured: Arc<Mutex<Option<String>>>,
) -> Result<rustls::ClientConfig, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?;
    let mut tls = if probe || config.tls_certificate_sha256.is_some() {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(CertificateVerifier {
                pin: config
                    .tls_certificate_sha256
                    .as_deref()
                    .map(normalized_pin)
                    .transpose()?,
                probe,
                captured,
                algorithms: provider.signature_verification_algorithms,
            }))
            .with_no_client_auth()
    } else {
        let mut roots = rustls::RootCertStore::empty();
        for cert in rustls_native_certs::load_native_certs().certs {
            let _ = roots.add(cert);
        }
        // rustls-native-certs probes OpenSSL/Termux paths on Android; regular
        // Android applications use these read-only system trust directories.
        #[cfg(target_os = "android")]
        for directory in [
            "/apex/com.android.conscrypt/cacerts",
            "/system/etc/security/cacerts",
        ] {
            if let Ok(entries) = std::fs::read_dir(directory) {
                for entry in entries.flatten() {
                    if let Ok(pem) = std::fs::read(entry.path()) {
                        for cert in rustls_pemfile::certs(&mut std::io::Cursor::new(pem)) {
                            if let Ok(cert) = cert {
                                let _ = roots.add(cert);
                            }
                        }
                    }
                }
            }
        }
        if let Some(pem) = config.tls_ca_pem.as_deref() {
            for cert in rustls_pemfile::certs(&mut std::io::Cursor::new(pem.as_bytes())) {
                roots
                    .add(cert.map_err(|e| format!("RDP_CERTIFICATE_CA: {e}"))?)
                    .map_err(|e| format!("RDP_CERTIFICATE_CA: {e}"))?;
            }
        }
        builder.with_root_certificates(roots).with_no_client_auth()
    };
    tls.resumption = rustls::client::Resumption::disabled();
    Ok(tls)
}

fn connector_config(config: &RemoteDesktopConfigDto) -> connector::Config {
    connector::Config {
        credentials: Credentials::UsernamePassword {
            username: config.username.clone(),
            password: config.password.clone(),
        },
        domain: config.domain.clone(),
        enable_tls: true,
        enable_credssp: true,
        keyboard_type: KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_layout: 0x0000_0409,
        keyboard_functional_keys_count: 12,
        ime_file_name: String::new(),
        dig_product_id: String::new(),
        desktop_size: connector::DesktopSize {
            width: config.width,
            height: config.height,
        },
        bitmap: None,
        client_build: 0,
        client_name: "TermPulse".into(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".into(),
        platform: MajorPlatformType::UNIX,
        enable_server_pointer: true,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        compression_type: None,
        pointer_software_rendering: true,
        multitransport_flags: None,
        // Keep font smoothing for readable small text, while asking the server
        // to avoid decorative pixels and animations on mobile/WAN connections.
        performance_flags: PerformanceFlags::default()
            | PerformanceFlags::DISABLE_WALLPAPER
            | PerformanceFlags::DISABLE_CURSOR_SHADOW,
        desktop_scale_factor: 0,
        hardware_id: None,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        alternate_shell: String::new(),
        work_dir: String::new(),
    }
}

type RdpStream = tokio_rustls::client::TlsStream<TcpStream>;

async fn begin_rdp_tls(
    config: &RemoteDesktopConfigDto,
    probe: bool,
    captured: Arc<Mutex<Option<String>>>,
) -> Result<
    (
        connector::ClientConnector,
        ironrdp_tokio::Upgraded,
        TokioFramed<RdpStream>,
        Vec<u8>,
    ),
    String,
> {
    let tcp = TcpStream::connect((config.hostname.as_str(), config.port))
        .await
        .map_err(|e| format!("REMOTE_DESKTOP_CONNECT: {e}"))?;
    tcp.set_nodelay(true).map_err(|e| e.to_string())?;
    let mut connector = connector::ClientConnector::new(
        connector_config(config),
        tcp.local_addr().map_err(|e| e.to_string())?,
    );
    let mut framed = TokioFramed::new(tcp);
    let upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
        .await
        .map_err(|e| format!("RDP_NEGOTIATION: {e}"))?;
    let name = config
        .tls_server_name
        .as_deref()
        .filter(|name| !name.is_empty())
        .unwrap_or(&config.hostname);
    let name =
        ServerName::try_from(name.to_owned()).map_err(|e| format!("RDP_SERVER_NAME: {e}"))?;
    let tls = tokio_rustls::TlsConnector::from(Arc::new(tls_config(config, probe, captured)?))
        .connect(name, framed.into_inner_no_leftover())
        .await
        .map_err(|e| {
            if e.to_string().to_ascii_lowercase().contains("cert") {
                format!("RDP_CERTIFICATE_UNTRUSTED: {e}")
            } else {
                format!("RDP_TLS: {e}")
            }
        })?;
    let der = tls
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first())
        .ok_or_else(|| {
            "RDP_CERTIFICATE_UNTRUSTED: Server did not send a certificate.".to_string()
        })?;
    let cert = x509_cert::Certificate::from_der(der.as_ref())
        .map_err(|e| format!("RDP_CERTIFICATE_UNTRUSTED: {e}"))?;
    let public_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or_else(|| "RDP_CERTIFICATE_UNTRUSTED: Invalid public key.".to_string())?
        .to_vec();
    let upgraded = ironrdp_tokio::mark_as_upgraded(upgrade, &mut connector);
    Ok((connector, upgraded, TokioFramed::new(tls), public_key))
}

/// Inspect the RDP certificate before entering CredSSP or sending credentials.
/// The caller must compare this fingerprint through a trusted channel before saving a pin.
pub fn probe_remote_desktop_certificate(
    hostname: String,
    port: u16,
    tls_server_name: Option<String>,
) -> Result<String, String> {
    let config = RemoteDesktopConfigDto {
        protocol: "rdp".into(),
        hostname,
        port,
        username: String::new(),
        password: String::new(),
        domain: None,
        width: 1280,
        height: 720,
        tls_server_name,
        tls_ca_pem: None,
        tls_certificate_sha256: None,
    };
    let captured = Arc::new(Mutex::new(None));
    state().rt.block_on(async {
        tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            begin_rdp_tls(&config, true, captured.clone()),
        )
        .await
        .map_err(|_| "REMOTE_DESKTOP_TIMEOUT: Certificate probe timed out.".to_string())??;
        let pin = captured
            .lock()
            .map_err(|_| "Certificate lock error")?
            .clone()
            .ok_or_else(|| "RDP_CERTIFICATE_UNTRUSTED: Certificate was not received.".to_string());
        pin
    })
}

async fn run_rdp(
    config: RemoteDesktopConfigDto,
    id: &str,
    mut rx: mpsc::Receiver<RemoteInput>,
    emit: Emit,
) -> Result<(), String> {
    let connect = async {
        let (connector, upgraded, mut framed, public_key) =
            begin_rdp_tls(&config, false, Arc::new(Mutex::new(None))).await?;
        let result = ironrdp_tokio::connect_finalize(
            upgraded,
            connector,
            &mut framed,
            &mut ironrdp_tokio::reqwest::ReqwestNetworkClient::new(),
            config.hostname.clone().into(),
            public_key,
            None,
        )
        .await
        .map_err(|e| format!("RDP_AUTHENTICATION: {e}"))?;
        Ok::<_, String>((result, framed))
    };
    let connect = tokio::time::timeout(HANDSHAKE_TIMEOUT, connect);
    tokio::pin!(connect);
    let mut connecting_heartbeat = tokio::time::interval(Duration::from_secs(1));
    let (result, framed) = loop {
        tokio::select! {
            result = &mut connect => break result.map_err(|_| "REMOTE_DESKTOP_TIMEOUT: RDP handshake timed out.")??,
            input = rx.recv() => if matches!(input, None | Some(RemoteInput::Close)) { return Ok(()); },
            _ = connecting_heartbeat.tick() => emit(event(id, "heartbeat", 0, 0, vec![], None))?,
        }
    };
    dimensions(result.desktop_size.width, result.desktop_size.height)?;
    let mut image = DecodedImage::new(
        PixelFormat::RgbA32,
        result.desktop_size.width,
        result.desktop_size.height,
    );
    emit(event(
        id,
        "connected",
        image.width(),
        image.height(),
        vec![],
        None,
    ))?;
    let activation_factory = result.activation_factory;
    let mut active = ActiveStageBuilder {
        static_channels: result.static_channels,
        user_channel_id: result.user_channel_id,
        io_channel_id: result.io_channel_id,
        message_channel_id: result.message_channel_id,
        share_id: result.share_id,
        compression_type: result.compression_type,
        enable_server_pointer: result.enable_server_pointer,
        pointer_software_rendering: result.pointer_software_rendering,
    }
    .build();
    let (mut reader, mut writer) = ironrdp_tokio::split_tokio_framed(framed);
    let mut database = Database::new();
    let mut buttons = 0u8;
    let mut pending_input = None;
    // Wait for graphics from the server; a freshly allocated all-zero image is
    // not a remote desktop frame and must not masquerade as a rendered screen.
    let mut dirty = false;
    let mut render = desktop_frame_clock();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(1));
    loop {
        let outputs = tokio::select! {
            pdu = reader.read_pdu() => {
                let (action, bytes) = pdu.map_err(|e| format!("RDP_CONNECTION: {e}"))?;
                active.process(&mut image, action, &bytes).map_err(|e| format!("RDP_DECODE: {e}"))?
            },
            input = async {
                if pending_input.is_some() { pending_input.take() } else { rx.recv().await }
            } => {
                let input = coalesce_pointer_motion(input, &mut rx, &mut pending_input, buttons);
                let mut operations = Vec::new();
                match input {
                    None | Some(RemoteInput::Close) => {
                        for output in active.graceful_shutdown().map_err(|e| e.to_string())? {
                            if let ActiveStageOutput::ResponseFrame(bytes) = output { let _ = writer.write_all(&bytes).await; }
                        }
                        return Ok(());
                    },
                    Some(RemoteInput::Pointer { x, y, buttons: next, scroll_y }) => {
                        let x = x.min(image.width() - 1); let y = y.min(image.height() - 1);
                        operations.push(Operation::MouseMove(MousePosition { x, y }));
                        for (mask, button) in [(1, MouseButton::Left), (2, MouseButton::Middle), (4, MouseButton::Right)] {
                            if (buttons ^ next) & mask != 0 {
                                operations.push(if next & mask != 0 { Operation::MouseButtonPressed(button) } else { Operation::MouseButtonReleased(button) });
                            }
                        }
                        buttons = next;
                        if scroll_y != 0 { operations.push(Operation::WheelRotations(WheelRotations { is_vertical: true, rotation_units: scroll_y.clamp(-255, 255) })); }
                    },
                    Some(RemoteInput::Key { key, down, unicode }) => {
                        if unicode {
                            let c = char::from_u32(key).ok_or("REMOTE_DESKTOP_KEY: Invalid Unicode scalar.")?;
                            operations.push(if down { Operation::UnicodeKeyPressed(c) } else { Operation::UnicodeKeyReleased(c) });
                        } else {
                            if key > 0x1ff { return Err("REMOTE_DESKTOP_KEY: Invalid RDP scancode.".into()); }
                            let scan = Scancode::from_u8(key & 0x100 != 0, key as u8);
                            operations.push(if down { Operation::KeyPressed(scan) } else { Operation::KeyReleased(scan) });
                        }
                    },
                    Some(RemoteInput::Text(text)) => for c in text.replace("\r\n", "\n").chars() {
                        let scan = match c { '\n' | '\r' => Some(0x1c), '\t' => Some(0x0f), _ => None };
                        if let Some(scan) = scan { operations.push(Operation::KeyPressed(Scancode::from_u8(false, scan))); operations.push(Operation::KeyReleased(Scancode::from_u8(false, scan))); }
                        else { operations.push(Operation::UnicodeKeyPressed(c)); operations.push(Operation::UnicodeKeyReleased(c)); }
                    },
                    Some(RemoteInput::Clipboard(_)) => {
                        emit(event(id, "notice", 0, 0, vec![], Some("REMOTE_DESKTOP_CLIPBOARD_UNSUPPORTED: Use Type text for RDP; clipboard redirection is not negotiated.".into())))?;
                    },
                }
                let events = database.apply(operations);
                // FastPath event count is one byte; bound each input packet.
                let mut outputs = Vec::new();
                for chunk in events.chunks(128) { outputs.extend(active.process_fastpath_input(&mut image, chunk).map_err(|e| e.to_string())?); }
                outputs
            },
            _ = render.tick() => {
                if dirty { emit_frame(&emit, id, image.width(), image.height(), image.data().to_vec())?; dirty = false; }
                continue;
            },
            _ = heartbeat.tick() => { emit(event(id, "heartbeat", 0, 0, vec![], None))?; continue; },
        };
        for output in outputs {
            match output {
                ActiveStageOutput::ResponseFrame(bytes) => writer
                    .write_all(&bytes)
                    .await
                    .map_err(|e| format!("RDP_WRITE: {e}"))?,
                ActiveStageOutput::GraphicsUpdate(_) => dirty = true,
                ActiveStageOutput::Terminate(reason) => {
                    emit(event(
                        id,
                        "notice",
                        0,
                        0,
                        vec![],
                        Some(reason.description()),
                    ))?;
                    return Ok(());
                }
                ActiveStageOutput::DeactivateAll => {
                    let mut activation = activation_factory.create();
                    let mut buffer = ironrdp::core::WriteBuf::new();
                    loop {
                        let written = tokio::time::timeout(
                            HANDSHAKE_TIMEOUT,
                            ironrdp_tokio::single_sequence_step_read(
                                &mut reader,
                                &mut activation,
                                &mut buffer,
                            ),
                        )
                        .await
                        .map_err(|_| "RDP_REACTIVATION_TIMEOUT")?
                        .map_err(|e| e.to_string())?;
                        if written.size().is_some() {
                            writer
                                .write_all(buffer.filled())
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let connector::connection_activation::ConnectionActivationState::Finalized { desktop_size, share_id, enable_server_pointer, pointer_software_rendering } = activation.connection_activation_state() {
                            dimensions(desktop_size.width, desktop_size.height)?;
                            image = DecodedImage::new(PixelFormat::RgbA32, desktop_size.width, desktop_size.height);
                            active.set_fastpath_processor(ironrdp::session::fast_path::ProcessorBuilder { io_channel_id: activation.io_channel_id(),
                                user_channel_id: activation.user_channel_id(), share_id, enable_server_pointer, pointer_software_rendering, bulk_decompressor: None }.build());
                            active.set_share_id(share_id); active.set_enable_server_pointer(enable_server_pointer); dirty = true;
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
    }
}

fn emit_frame(
    emit: &Emit,
    id: &str,
    width: u16,
    height: u16,
    mut rgba: Vec<u8>,
) -> Result<(), String> {
    if rgba.len() != dimensions(width, height)? {
        return Err("REMOTE_DESKTOP_FRAME: Invalid framebuffer length.".into());
    }
    // RDP/RFB reserve the high byte; Flutter expects opaque straight RGBA.
    for pixel in rgba.chunks_exact_mut(4) {
        pixel[3] = 255;
    }
    emit(event(id, "frame", width, height, rgba, None))
}

#[derive(Default)]
#[flutter_rust_bridge::frb(ignore)]
struct Framebuffer {
    width: u16,
    height: u16,
    rgba: Vec<u8>,
}
#[flutter_rust_bridge::frb(ignore)]
impl Framebuffer {
    fn resize(&mut self, width: u16, height: u16) -> Result<(), String> {
        let length = dimensions(width, height)?;
        if self.width != width || self.height != height {
            self.rgba = vec![0; length];
        }
        self.width = width;
        self.height = height;
        Ok(())
    }
    fn check(&self, rect: Rect) -> Result<(), String> {
        if u32::from(rect.x) + u32::from(rect.width) > u32::from(self.width)
            || u32::from(rect.y) + u32::from(rect.height) > u32::from(self.height)
        {
            return Err("VNC_FRAME: Server rectangle exceeds the framebuffer.".into());
        }
        Ok(())
    }
    fn draw(&mut self, rect: Rect, pixels: &[u8]) -> Result<(), String> {
        self.check(rect)?;
        let row_bytes = usize::from(rect.width) * 4;
        if pixels.len() != row_bytes * usize::from(rect.height) {
            return Err("VNC_FRAME: Invalid rectangle length.".into());
        }
        for row in 0..usize::from(rect.height) {
            let dst =
                ((usize::from(rect.y) + row) * usize::from(self.width) + usize::from(rect.x)) * 4;
            self.rgba[dst..dst + row_bytes]
                .copy_from_slice(&pixels[row * row_bytes..(row + 1) * row_bytes]);
        }
        Ok(())
    }
    fn copy(&mut self, dst: Rect, src: Rect) -> Result<(), String> {
        self.check(src)?;
        self.check(dst)?;
        if src.width != dst.width || src.height != dst.height {
            return Err("VNC_FRAME: Invalid CopyRect size.".into());
        }
        let row_bytes = usize::from(src.width) * 4;
        let mut pixels = Vec::with_capacity(row_bytes * usize::from(src.height));
        for row in 0..usize::from(src.height) {
            let start =
                ((usize::from(src.y) + row) * usize::from(self.width) + usize::from(src.x)) * 4;
            pixels.extend_from_slice(&self.rgba[start..start + row_bytes]);
        }
        self.draw(dst, &pixels)
    }
}

fn vnc_keysym(key: u32, unicode: bool) -> u32 {
    if unicode && key > 255 {
        key | 0x0100_0000
    } else {
        key
    }
}

async fn run_vnc(
    config: RemoteDesktopConfigDto,
    id: &str,
    mut rx: mpsc::Receiver<RemoteInput>,
    emit: Emit,
) -> Result<(), String> {
    let connect = async {
        let tcp = TcpStream::connect((config.hostname.as_str(), config.port))
            .await
            .map_err(|e| format!("REMOTE_DESKTOP_CONNECT: {e}"))?;
        let password = config.password.clone();
        VncConnector::new(tcp)
            .set_auth_method(async move { Ok(password) })
            // ZRLE/Raw avoid JPEG loss and provide decoded RGBA without another bitmap codec.
            .add_encoding(VncEncoding::Zrle)
            .add_encoding(VncEncoding::CopyRect)
            .add_encoding(VncEncoding::Raw)
            .add_encoding(VncEncoding::DesktopSizePseudo)
            .add_encoding(VncEncoding::LastRectPseudo)
            .allow_shared(true)
            .set_pixel_format(VncPixelFormat::rgba())
            .build()
            .map_err(|e| format!("VNC_CONFIG: {e}"))?
            .try_start()
            .await
            .map_err(|e| format!("VNC_AUTHENTICATION: {e}"))?
            .finish()
            .map_err(|e| format!("VNC_CONNECT: {e}"))
    };
    let connect = tokio::time::timeout(HANDSHAKE_TIMEOUT, connect);
    tokio::pin!(connect);
    let mut connecting_heartbeat = tokio::time::interval(Duration::from_secs(1));
    let client = loop {
        tokio::select! {
            result = &mut connect => break result.map_err(|_| "REMOTE_DESKTOP_TIMEOUT: VNC handshake timed out.")??,
            input = rx.recv() => if matches!(input, None | Some(RemoteInput::Close)) { return Ok(()); },
            _ = connecting_heartbeat.tick() => emit(event(id, "heartbeat", 0, 0, vec![], None))?,
        }
    };
    let result = async {
        let mut framebuffer = Framebuffer::default();
        let mut poll = tokio::time::interval(Duration::from_millis(10));
        let mut render = desktop_frame_clock();
        let mut heartbeat = tokio::time::interval(Duration::from_secs(1));
        let mut dirty = false;
        loop {
            tokio::select! {
                _ = poll.tick() => {
                    // recv_event holds the crate's input mutex while waiting. Polling
                    // leaves that mutex free so idle desktops still accept input/close.
                    for _ in 0..64 {
                        let Some(output) = client.poll_event().await.map_err(|e| format!("VNC_CONNECTION: {e}"))? else { break; };
                        match output {
                            VncEvent::SetResolution(screen) => {
                                let initial = framebuffer.rgba.is_empty();
                                framebuffer.resize(screen.width, screen.height)?;
                                if initial { emit(event(id, "connected", screen.width, screen.height, vec![], Some(client.server_name().to_owned())))?; }
                                dirty = true;
                            },
                            VncEvent::RawImage(rect, pixels) => { framebuffer.draw(rect, &pixels)?; dirty = true; },
                            VncEvent::Copy(dst, src) => { framebuffer.copy(dst, src)?; dirty = true; },
                            VncEvent::Text(text) => emit(event(id, "clipboard", 0, 0, vec![], Some(text)))?,
                            VncEvent::Error(error) => return Err(format!("VNC_CONNECTION: {error}")),
                            VncEvent::DesktopUpdate(update) => if let Some(layout) = update.layout { framebuffer.resize(layout.width, layout.height)?; dirty = true; },
                            _ => {},
                        }
                    }
                },
                _ = render.tick() => {
                    if dirty { emit_frame(&emit, id, framebuffer.width, framebuffer.height, framebuffer.rgba.clone())?; dirty = false; }
                    client.input(X11Event::Refresh).await.map_err(|e| format!("VNC_REFRESH: {e}"))?;
                },
                _ = heartbeat.tick() => { emit(event(id, "heartbeat", 0, 0, vec![], None))?; },
                input = rx.recv() => {
                    match input {
                        None | Some(RemoteInput::Close) => return Ok(()),
                        Some(RemoteInput::Pointer { x, y, buttons, scroll_y }) => {
                            let x = x.min(framebuffer.width.saturating_sub(1)); let y = y.min(framebuffer.height.saturating_sub(1));
                            client.input(X11Event::PointerEvent((x, y, buttons & 7).into())).await.map_err(|e| e.to_string())?;
                            if scroll_y != 0 {
                                let wheel = if scroll_y > 0 { 8 } else { 16 };
                                for _ in 0..((scroll_y.unsigned_abs() / 120).max(1).min(8)) {
                                    client.input(X11Event::PointerEvent((x, y, (buttons & 7) | wheel).into())).await.map_err(|e| e.to_string())?;
                                    client.input(X11Event::PointerEvent((x, y, buttons & 7).into())).await.map_err(|e| e.to_string())?;
                                }
                            }
                        },
                        Some(RemoteInput::Key { key, down, unicode }) => client.input(X11Event::KeyEvent((vnc_keysym(key, unicode), down).into())).await.map_err(|e| e.to_string())?,
                        Some(RemoteInput::Text(text)) => for c in text.replace("\r\n", "\n").chars() {
                            let key = match c { '\n' | '\r' => 0xff0d, '\t' => 0xff09, _ => vnc_keysym(u32::from(c), true) };
                            client.input(X11Event::KeyEvent((key, true).into())).await.map_err(|e| e.to_string())?;
                            client.input(X11Event::KeyEvent((key, false).into())).await.map_err(|e| e.to_string())?;
                        },
                        Some(RemoteInput::Clipboard(text)) => client.input(X11Event::CopyText(text)).await.map_err(|e| e.to_string())?,
                    }
                },
            }
        }
    }.await;
    let _ = client.close().await;
    result
}

#[cfg(test)]
mod tests;
