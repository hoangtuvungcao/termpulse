use crate::TransportError;
use russh::keys::ssh_key::certificate::CertType;
use russh::keys::ssh_key::known_hosts::{HostPatterns, KnownHosts, Marker};
use russh::keys::{Certificate, HashAlg, PublicKey, PublicKeyOrCertificate};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::oneshot;

const MAX_STORE_BYTES: u64 = 1024 * 1024;
const DECISION_TIMEOUT: Duration = Duration::from_secs(120);
/// Handshakes allow time for a human decision, which itself expires sooner.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(150);

#[cfg(test)]
pub(crate) static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Clone, Debug)]
pub struct HostKeyPrompt {
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

#[derive(Clone, Debug)]
pub struct HostKeyRecord {
    pub record_id: String,
    pub hostname: String,
    pub port: u16,
    pub algorithm: String,
    pub fingerprint: String,
    pub public_key: String,
    pub certificate_authority: bool,
    pub revoked: bool,
}

#[derive(Clone)]
struct Candidate {
    trust_key: PublicKey,
    server_key_fingerprint: String,
    certificate: Option<Certificate>,
}

impl Candidate {
    fn from_server(
        hostname: &str,
        server_key: &PublicKeyOrCertificate,
    ) -> Result<Self, TransportError> {
        let leaf = server_key.public_key();
        let certificate = server_key.certificate().cloned();
        if let Some(certificate) = certificate.as_ref() {
            validate_host_certificate(hostname, certificate)?;
        }
        let trust_key = certificate
            .as_ref()
            .map(|certificate| PublicKey::new(certificate.signature_key().clone(), ""))
            .unwrap_or_else(|| leaf.clone());
        Ok(Self {
            trust_key,
            server_key_fingerprint: fingerprint(&leaf),
            certificate,
        })
    }

    fn is_ca(&self) -> bool {
        self.certificate.is_some()
    }
}

struct Pending {
    path: PathBuf,
    prompt: HostKeyPrompt,
    expires_at: Instant,
    answer: oneshot::Sender<bool>,
}

static PENDING: OnceLock<Mutex<BTreeMap<String, Pending>>> = OnceLock::new();
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
static TRUST_EPOCH: AtomicU64 = AtomicU64::new(0);

fn pending() -> &'static Mutex<BTreeMap<String, Pending>> {
    PENDING.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn error(message: impl Into<String>) -> TransportError {
    TransportError::HostKey(message.into())
}
fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

fn endpoint(hostname: &str, port: u16) -> Result<String, TransportError> {
    if hostname.is_empty()
        || port == 0
        || hostname
            .chars()
            .any(|ch| ch.is_whitespace() || ch.is_control() || ",*?!|#@[]/\\".contains(ch))
    {
        return Err(error("Tên máy chủ hoặc cổng không hợp lệ"));
    }
    let hostname = hostname.to_ascii_lowercase();
    Ok(if port == 22 {
        hostname
    } else {
        format!("[{hostname}]:{port}")
    })
}

fn split_endpoint(value: &str) -> Result<(String, u16), TransportError> {
    if let Some(value) = value.strip_prefix('[') {
        let (host, port) = value
            .rsplit_once("]:")
            .ok_or_else(|| error("Bản ghi host key có địa chỉ không hợp lệ"))?;
        let port = port
            .parse()
            .map_err(|_| error("Bản ghi host key có cổng không hợp lệ"))?;
        endpoint(host, port)?;
        Ok((host.to_string(), port))
    } else {
        endpoint(value, 22)?;
        Ok((value.to_string(), 22))
    }
}

fn validate_host_certificate(
    hostname: &str,
    certificate: &Certificate,
) -> Result<(), TransportError> {
    if certificate.cert_type() != CertType::Host {
        return Err(error("SSH certificate không phải loại host certificate"));
    }
    if !certificate
        .valid_principals()
        .iter()
        .any(|principal| principal.eq_ignore_ascii_case(hostname))
    {
        return Err(error(
            "SSH certificate không có principal chính xác cho máy chủ này",
        ));
    }
    if !certificate.critical_options().is_empty() {
        return Err(error(
            "SSH certificate chứa critical option chưa được hỗ trợ",
        ));
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| error("Đồng hồ hệ thống không hợp lệ để xác minh SSH certificate"))?
        .as_secs();
    let ca = certificate.signature_key().fingerprint(HashAlg::Sha256);
    // At this stage we check signature and time against the presented CA. Trust
    // in that CA is a separate mandatory store/interactive check below.
    certificate
        .validate_at(now, [&ca])
        .map_err(|_| error("SSH certificate sai chữ ký, chưa có hiệu lực hoặc đã hết hạn"))
}

#[derive(Clone)]
struct StoreRecord {
    hosts: Vec<String>,
    marker: Option<Marker>,
    key: PublicKey,
}

enum StoreLine {
    Text(String),
    Record(StoreRecord),
}

struct Store {
    path: PathBuf,
    _lock: File,
    lines: Vec<StoreLine>,
}

fn private_file(path: &Path, create_new: bool) -> Result<File, TransportError> {
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    if create_new {
        options.create_new(true);
    } else {
        options.create(true).truncate(false);
    }
    #[cfg(unix)]
    options.mode(0o600);
    options
        .open(path)
        .map_err(|e| error(format!("Không mở được kho SSH {}: {e}", path.display())))
}

fn check_store_metadata(file: &File, path: &Path) -> Result<(), TransportError> {
    let metadata = file
        .metadata()
        .map_err(|e| error(format!("Không đọc được kho SSH: {e}")))?;
    if !metadata.is_file() || metadata.len() > MAX_STORE_BYTES {
        return Err(error(format!(
            "Kho SSH không phải tệp hợp lệ hoặc vượt 1 MiB: {}",
            path.display()
        )));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o022 != 0 {
            return Err(error(format!(
                "Kho SSH cho phép người dùng khác sửa; hãy đặt quyền 600: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

#[cfg(not(target_os = "android"))]
fn try_lock_store(file: &File) -> Result<(), std::fs::TryLockError> {
    file.try_lock()
}

#[cfg(target_os = "android")]
fn try_lock_store(file: &File) -> Result<(), std::fs::TryLockError> {
    try_lock_store_with_flock(file)
}

// Rust's std file-locking implementation does not support Android. Bionic's
// flock provides the same exclusive, nonblocking lock and releases it when the
// owning File closes. Compile it on Unix test hosts too so this backend is
// covered even when the tests do not run on a connected Android device.
#[cfg(any(target_os = "android", all(test, unix)))]
fn try_lock_store_with_flock(file: &File) -> Result<(), std::fs::TryLockError> {
    use std::os::fd::AsRawFd;

    loop {
        // SAFETY: File owns this live descriptor for the duration of the call;
        // flock neither takes ownership of it nor accesses Rust memory.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        match error.kind() {
            std::io::ErrorKind::Interrupted => continue,
            std::io::ErrorKind::WouldBlock => return Err(std::fs::TryLockError::WouldBlock),
            _ => return Err(std::fs::TryLockError::Error(error)),
        }
    }
}

impl Store {
    fn open(path: &Path) -> Result<Self, TransportError> {
        if let Some(parent) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .map_err(|e| error(format!("Không tạo được thư mục kho SSH: {e}")))?;
        }
        // A stable sidecar lock also protects readers during atomic replacement.
        let mut lock_name = path.as_os_str().to_os_string();
        lock_name.push(".lock");
        let lock_path = PathBuf::from(lock_name);
        let lock = private_file(&lock_path, false)?;
        check_store_metadata(&lock, &lock_path)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match try_lock_store(&lock) {
                Ok(()) => break,
                Err(std::fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(e) => return Err(error(format!("Không khóa được kho SSH: {e}"))),
            }
        }
        let mut content = String::new();
        match File::open(path) {
            Ok(mut file) => {
                check_store_metadata(&file, path)?;
                file.read_to_string(&mut content)
                    .map_err(|e| error(format!("Không đọc được kho SSH: {e}")))?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(error(format!(
                    "Không đọc được kho SSH {}: {e}",
                    path.display()
                )))
            }
        }
        let mut lines = Vec::new();
        for line in content.lines() {
            let Some(entry) = KnownHosts::new(line).next() else {
                lines.push(StoreLine::Text(line.to_string()));
                continue;
            };
            let entry =
                entry.map_err(|e| error(format!("Kho SSH bị hỏng; không tự ghi đè: {e}")))?;
            let HostPatterns::Patterns(hosts) = entry.host_patterns() else {
                return Err(error("Kho riêng của ứng dụng chỉ hỗ trợ tên máy chủ chính xác, chưa hỗ trợ tên đã băm"));
            };
            for host in hosts {
                split_endpoint(host)?;
            }
            lines.push(StoreLine::Record(StoreRecord {
                hosts: hosts.clone(),
                marker: entry.marker().copied(),
                key: entry.public_key().clone(),
            }));
        }
        Ok(Self {
            path: path.to_path_buf(),
            _lock: lock,
            lines,
        })
    }

    fn records_for<'a>(&'a self, endpoint: &'a str) -> impl Iterator<Item = &'a StoreRecord> {
        self.lines.iter().filter_map(|line| match line {
            StoreLine::Record(record)
                if record
                    .hosts
                    .iter()
                    .any(|host| host.eq_ignore_ascii_case(endpoint)) =>
            {
                Some(record)
            }
            _ => None,
        })
    }

    fn snapshot(&self, endpoint: &str) -> Vec<String> {
        let mut values: Vec<_> = self
            .records_for(endpoint)
            .map(|record| {
                format!(
                    "{}:{}",
                    marker_name(record.marker),
                    fingerprint(&record.key)
                )
            })
            .collect();
        values.sort();
        values
    }

    fn trusted(&self, endpoint: &str, candidate: &Candidate) -> Result<bool, TransportError> {
        let mut trusted = false;
        for record in self.records_for(endpoint) {
            let same_key = record.key.key_data() == candidate.trust_key.key_data();
            if record.marker == Some(Marker::Revoked)
                && (same_key || fingerprint(&record.key) == candidate.server_key_fingerprint)
            {
                return Err(error(
                    "Host key hoặc CA của máy chủ đã bị thu hồi; kết nối bị chặn",
                ));
            }
            if same_key
                && (record.marker == Some(Marker::CertAuthority)) == candidate.is_ca()
                && record.marker != Some(Marker::Revoked)
            {
                trusted = true;
            }
        }
        Ok(trusted)
    }

    fn insert(&mut self, endpoint: &str, key: &PublicKey, is_ca: bool, replace: bool) {
        if replace {
            for line in &mut self.lines {
                if let StoreLine::Record(record) = line {
                    if record.marker != Some(Marker::Revoked) {
                        record
                            .hosts
                            .retain(|host| !host.eq_ignore_ascii_case(endpoint));
                    }
                }
            }
        }
        self.lines.push(StoreLine::Record(StoreRecord {
            hosts: vec![endpoint.to_string()],
            marker: is_ca.then_some(Marker::CertAuthority),
            key: key.clone(),
        }));
    }

    fn save(&self) -> Result<(), TransportError> {
        let mut content = String::new();
        for line in &self.lines {
            match line {
                StoreLine::Text(text) => content.push_str(text),
                StoreLine::Record(record) if record.hosts.is_empty() => continue,
                StoreLine::Record(record) => {
                    if let Some(marker) = record.marker {
                        content.push_str(marker.as_str());
                        content.push(' ');
                    }
                    content.push_str(&record.hosts.join(","));
                    content.push(' ');
                    content.push_str(
                        &record
                            .key
                            .to_openssh()
                            .map_err(|e| error(format!("Host key không hợp lệ: {e}")))?,
                    );
                }
            }
            content.push('\n');
        }
        if content.len() as u64 > MAX_STORE_BYTES {
            return Err(error("Kho SSH vượt giới hạn 1 MiB"));
        }
        let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let mut temporary_name = self.path.as_os_str().to_os_string();
        temporary_name.push(format!(".tmp-{}-{id}", std::process::id()));
        let temporary_path = PathBuf::from(temporary_name);
        let result = (|| {
            let mut file = private_file(&temporary_path, true)?;
            file.write_all(content.as_bytes())
                .map_err(|e| error(format!("Không lưu được host key: {e}")))?;
            file.sync_all()
                .map_err(|e| error(format!("Không đồng bộ được host key: {e}")))?;
            std::fs::rename(&temporary_path, &self.path)
                .map_err(|e| error(format!("Không cập nhật được kho SSH: {e}")))?;
            #[cfg(unix)]
            if let Some(parent) = self
                .path
                .parent()
                .filter(|path| !path.as_os_str().is_empty())
            {
                File::open(parent)
                    .and_then(|directory| directory.sync_all())
                    .map_err(|e| error(format!("Không đồng bộ được thư mục kho SSH: {e}")))?;
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary_path);
        }
        result
    }
}

fn marker_name(marker: Option<Marker>) -> &'static str {
    match marker {
        None => "key",
        Some(Marker::CertAuthority) => "ca",
        Some(Marker::Revoked) => "revoked",
    }
}

pub async fn verify_server_key(
    path: &Path,
    hostname: &str,
    port: u16,
    server_key: &PublicKeyOrCertificate,
) -> Result<String, TransportError> {
    verify_server_key_at_epoch(path, hostname, port, server_key, current_epoch()).await
}

pub(crate) fn current_epoch() -> u64 {
    TRUST_EPOCH.load(Ordering::Acquire)
}

pub(crate) fn ensure_epoch(epoch: u64) -> Result<(), TransportError> {
    if current_epoch() != epoch {
        return Err(error("Xác minh SSH đã bị hủy khi khóa hoặc đổi Vault"));
    }
    Ok(())
}

pub(crate) async fn verify_server_key_at_epoch(
    path: &Path,
    hostname: &str,
    port: u16,
    server_key: &PublicKeyOrCertificate,
    epoch: u64,
) -> Result<String, TransportError> {
    ensure_epoch(epoch)?;
    let endpoint = endpoint(hostname, port)?;
    let candidate = Candidate::from_server(hostname, server_key)?;
    let path_owned = path.to_path_buf();
    let endpoint_owned = endpoint.clone();
    let candidate_owned = candidate.clone();
    let (trusted, snapshot) = tokio::task::spawn_blocking(move || {
        let store = Store::open(&path_owned)?;
        Ok::<_, TransportError>((
            store.trusted(&endpoint_owned, &candidate_owned)?,
            store.snapshot(&endpoint_owned),
        ))
    })
    .await
    .map_err(|e| error(format!("Không đọc được kho SSH: {e}")))??;
    if TRUST_EPOCH.load(Ordering::Acquire) != epoch {
        return Err(error("Xác minh SSH đã bị hủy khi khóa hoặc đổi Vault"));
    }
    if trusted {
        return Ok(candidate.server_key_fingerprint);
    }
    let request_id = format!(
        "{}-{}",
        std::process::id(),
        NEXT_REQUEST.fetch_add(1, Ordering::Relaxed)
    );
    let (answer, receiver) = oneshot::channel();
    let prompt = HostKeyPrompt {
        request_id: request_id.clone(),
        hostname: hostname.to_string(),
        port,
        algorithm: candidate.trust_key.algorithm().to_string(),
        fingerprint: fingerprint(&candidate.trust_key),
        public_key: candidate
            .trust_key
            .to_openssh()
            .map_err(|e| error(e.to_string()))?,
        previous_fingerprints: snapshot.iter().cloned().collect(),
        changed: !snapshot.is_empty(),
        certificate_authority: candidate.is_ca(),
        server_key_fingerprint: candidate.server_key_fingerprint.clone(),
        certificate_principals: candidate
            .certificate
            .as_ref()
            .map(|c| c.valid_principals().to_vec())
            .unwrap_or_default(),
        certificate_valid_until: candidate
            .certificate
            .as_ref()
            .map(|c| c.valid_before().to_string()),
    };
    {
        let mut pending = pending()
            .lock()
            .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?;
        if TRUST_EPOCH.load(Ordering::Acquire) != epoch {
            return Err(error("Xác minh SSH đã bị hủy khi khóa hoặc đổi Vault"));
        }
        pending.insert(
            request_id.clone(),
            Pending {
                path: path.to_path_buf(),
                prompt,
                expires_at: Instant::now() + DECISION_TIMEOUT,
                answer,
            },
        );
    }
    let decision = tokio::time::timeout(DECISION_TIMEOUT, receiver).await;
    pending()
        .lock()
        .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?
        .remove(&request_id);
    if !matches!(decision, Ok(Ok(true))) {
        return Err(error(if snapshot.is_empty() {
            "Chưa được chấp thuận host key; kết nối đã bị hủy hoặc hết thời gian xác minh"
        } else {
            "HOST KEY ĐÃ THAY ĐỔI; chưa có xác minh thay thế rõ ràng, kết nối bị chặn"
        }));
    }
    if let Some(certificate) = candidate.certificate.as_ref() {
        validate_host_certificate(hostname, certificate)?;
    }
    let path = path.to_path_buf();
    let candidate_for_store = candidate.clone();
    tokio::task::spawn_blocking(move || {
        let mut store = Store::open(&path)?;
        // Serialize the final commit with Vault cancellation as well as with
        // concurrent decisions. A stale approval can never populate a new Vault.
        let _lifecycle = pending()
            .lock()
            .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?;
        if TRUST_EPOCH.load(Ordering::Acquire) != epoch {
            return Err(error("Xác minh SSH đã bị hủy khi khóa hoặc đổi Vault"));
        }
        if store.trusted(&endpoint, &candidate_for_store)? {
            return Ok(());
        }
        if store.snapshot(&endpoint) != snapshot {
            return Err(error(
                "Kho SSH đã thay đổi trong lúc xác minh; hãy kết nối lại để kiểm tra",
            ));
        }
        store.insert(
            &endpoint,
            &candidate_for_store.trust_key,
            candidate_for_store.is_ca(),
            !snapshot.is_empty(),
        );
        store.save()
    })
    .await
    .map_err(|e| error(format!("Không lưu được host key: {e}")))??;
    if TRUST_EPOCH.load(Ordering::Acquire) != epoch {
        return Err(error("Xác minh SSH đã bị hủy khi khóa hoặc đổi Vault"));
    }
    Ok(candidate.server_key_fingerprint)
}

/// Call before locking or changing the active Vault. Dropping every sender
/// immediately interrupts handshakes, including approval/commit races.
pub fn cancel_pending() -> Result<(), TransportError> {
    let mut pending = pending()
        .lock()
        .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?;
    TRUST_EPOCH.fetch_add(1, Ordering::AcqRel);
    pending.clear();
    Ok(())
}

pub fn list_pending(path: &Path) -> Result<Vec<HostKeyPrompt>, TransportError> {
    let mut pending = pending()
        .lock()
        .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?;
    pending.retain(|_, request| request.expires_at > Instant::now() && !request.answer.is_closed());
    Ok(pending
        .values()
        .filter(|request| request.path == path)
        .map(|request| request.prompt.clone())
        .collect())
}

pub fn decide(
    path: &Path,
    request_id: &str,
    decision: &str,
    expected_fingerprint: &str,
) -> Result<(), TransportError> {
    let mut pending = pending()
        .lock()
        .map_err(|_| error("Không mở được hàng đợi xác minh SSH"))?;
    let request = pending
        .get(request_id)
        .ok_or_else(|| error("Yêu cầu xác minh đã hết hạn hoặc đã được xử lý"))?;
    if request.path != path || request.expires_at <= Instant::now() || request.answer.is_closed() {
        return Err(error("Yêu cầu xác minh không còn hợp lệ cho Vault này"));
    }
    if request.prompt.fingerprint != expected_fingerprint.trim() {
        return Err(error("Dấu vân tay xác nhận không khớp yêu cầu đang chờ"));
    }
    let approve = match decision {
        "reject" => false,
        "trust" if !request.prompt.changed => true,
        "replace_verified" if request.prompt.changed => true,
        _ => {
            return Err(error(
                "Cần quyết định xác minh phù hợp: trust, replace_verified hoặc reject",
            ))
        }
    };
    let request = pending
        .remove(request_id)
        .ok_or_else(|| error("Yêu cầu đã được xử lý"))?;
    request
        .answer
        .send(approve)
        .map_err(|_| error("Kết nối đang chờ đã kết thúc"))
}

pub fn list_records(path: &Path) -> Result<Vec<HostKeyRecord>, TransportError> {
    let store = Store::open(path)?;
    let mut records = Vec::new();
    for line in &store.lines {
        let StoreLine::Record(record) = line else {
            continue;
        };
        let fingerprint = fingerprint(&record.key);
        for host in &record.hosts {
            let (hostname, port) = split_endpoint(host)?;
            records.push(HostKeyRecord {
                record_id: format!(
                    "{}|{}|{}",
                    host.to_ascii_lowercase(),
                    marker_name(record.marker),
                    fingerprint
                ),
                hostname,
                port,
                algorithm: record.key.algorithm().to_string(),
                fingerprint: fingerprint.clone(),
                public_key: record.key.to_openssh().map_err(|e| error(e.to_string()))?,
                certificate_authority: record.marker == Some(Marker::CertAuthority),
                revoked: record.marker == Some(Marker::Revoked),
            });
        }
    }
    Ok(records)
}

pub fn remove_record(
    path: &Path,
    record_id: &str,
    expected_fingerprint: &str,
) -> Result<(), TransportError> {
    let mut store = Store::open(path)?;
    let mut removed = false;
    for line in &mut store.lines {
        let StoreLine::Record(record) = line else {
            continue;
        };
        let actual = fingerprint(&record.key);
        if actual != expected_fingerprint.trim() {
            continue;
        }
        record.hosts.retain(|host| {
            let id = format!(
                "{}|{}|{}",
                host.to_ascii_lowercase(),
                marker_name(record.marker),
                actual
            );
            let retain = id != record_id;
            removed |= !retain;
            retain
        });
    }
    if !removed {
        return Err(error(
            "Bản ghi đã thay đổi hoặc dấu vân tay không khớp; hãy tải lại danh sách",
        ));
    }
    store.save()
}

pub fn import_public_key(
    path: &Path,
    hostname: &str,
    port: u16,
    public_key: &str,
    is_ca: bool,
    replace_existing: bool,
    expected_fingerprint: &str,
) -> Result<(), TransportError> {
    let endpoint = endpoint(hostname, port)?;
    let public_key = public_key.trim();
    if public_key.is_empty() || public_key.chars().any(char::is_control) {
        return Err(error(
            "Public key phải là một dòng OpenSSH duy nhất, không có ký tự điều khiển",
        ));
    }
    let key = PublicKey::from_openssh(public_key)
        .map_err(|e| error(format!("Public key OpenSSH không hợp lệ: {e}")))?;
    if fingerprint(&key) != expected_fingerprint.trim() {
        return Err(error(
            "Dấu vân tay đã xác minh không khớp public key nhập vào",
        ));
    }
    let candidate = Candidate {
        trust_key: key.clone(),
        server_key_fingerprint: fingerprint(&key),
        certificate: None,
    };
    let mut store = Store::open(path)?;
    // Revocation always wins over an import or an interactive replacement.
    if store.records_for(&endpoint).any(|record| {
        record.marker == Some(Marker::Revoked) && record.key.key_data() == key.key_data()
    }) {
        return Err(error(
            "Khóa này đã bị thu hồi; cần xử lý bản ghi thu hồi trước",
        ));
    }
    let exact_match = store.records_for(&endpoint).any(|record| {
        record.key.key_data() == candidate.trust_key.key_data()
            && record.marker
                == if is_ca {
                    Some(Marker::CertAuthority)
                } else {
                    None
                }
    });
    if exact_match {
        return Ok(());
    }
    if !store.snapshot(&endpoint).is_empty() && !replace_existing {
        return Err(error(
            "Máy chủ đã có host key/CA khác; cần xác minh và chọn thay thế rõ ràng",
        ));
    }
    store.insert(&endpoint, &key, is_ca, replace_existing);
    store.save()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use russh::keys::{Algorithm, PrivateKey};

    #[cfg(unix)]
    #[test]
    fn android_flock_child_attempt() {
        let Some(path) = std::env::var_os("TERMPULSE_TEST_FLOCK_PATH") else {
            return;
        };
        let file = private_file(Path::new(&path), false).unwrap();
        let result = try_lock_store_with_flock(&file);
        if std::env::var_os("TERMPULSE_TEST_FLOCK_BLOCKED").is_some() {
            assert!(matches!(result, Err(std::fs::TryLockError::WouldBlock)));
        } else {
            result.unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn android_flock_excludes_handles_and_processes_until_file_close() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts.lock");
        let first = private_file(&path, false).unwrap();
        let second = private_file(&path, false).unwrap();
        try_lock_store_with_flock(&first).unwrap();
        assert!(matches!(
            try_lock_store_with_flock(&second),
            Err(std::fs::TryLockError::WouldBlock)
        ));
        let child = |blocked: bool| {
            let mut command = std::process::Command::new(std::env::current_exe().unwrap());
            command
                .args(["--exact", "host_keys::tests::android_flock_child_attempt"])
                .env("TERMPULSE_TEST_FLOCK_PATH", &path);
            if blocked {
                command.env("TERMPULSE_TEST_FLOCK_BLOCKED", "1");
            } else {
                command.env_remove("TERMPULSE_TEST_FLOCK_BLOCKED");
            }
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "child lock check failed: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
        };
        child(true);
        drop(first);
        try_lock_store_with_flock(&second).unwrap();
        drop(second);
        child(false);
    }

    #[cfg(unix)]
    #[test]
    fn store_sidecar_lock_stays_exclusive_after_atomic_save() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let store = Store::open(&path).unwrap();
        store.save().unwrap();
        let competing_lock =
            private_file(&directory.path().join("known_hosts.lock"), false).unwrap();
        assert!(matches!(
            try_lock_store_with_flock(&competing_lock),
            Err(std::fs::TryLockError::WouldBlock)
        ));
        drop(store);
        try_lock_store_with_flock(&competing_lock).unwrap();
    }

    #[test]
    fn store_lock_contention_times_out_without_changing_trust() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let mut store = Store::open(&path).unwrap();
        store
            .lines
            .push(StoreLine::Text("# existing trust store".into()));
        store.save().unwrap();
        let before = std::fs::read(&path).unwrap();
        let started = Instant::now();
        let result = Store::open(&path);
        assert!(started.elapsed() >= Duration::from_secs(5));
        assert!(matches!(
            result,
            Err(TransportError::HostKey(message)) if message.contains("Không khóa được kho SSH")
        ));
        assert_eq!(std::fs::read(&path).unwrap(), before);
        drop(store);
        Store::open(&path).unwrap();
    }

    fn key() -> PrivateKey {
        PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()
    }

    fn provision(path: &Path, hostname: &str, port: u16, key: &PublicKey, ca: bool, replace: bool) {
        import_public_key(
            path,
            hostname,
            port,
            &key.to_openssh().unwrap(),
            ca,
            replace,
            &fingerprint(key),
        )
        .unwrap();
    }

    fn verify(
        path: &Path,
        hostname: &str,
        port: u16,
        key: PublicKeyOrCertificate,
    ) -> tokio::task::JoinHandle<Result<String, TransportError>> {
        let path = path.to_owned();
        let hostname = hostname.to_owned();
        tokio::spawn(async move { verify_server_key(&path, &hostname, port, &key).await })
    }

    pub(crate) async fn wait_for_prompt(path: &Path) -> HostKeyPrompt {
        tokio::time::timeout(Duration::from_secs(4), async {
            loop {
                if let Some(prompt) = list_pending(path).unwrap().first() {
                    break prompt.clone();
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("SSH verification prompt was not queued")
    }

    fn certificate(
        ca: &PrivateKey,
        leaf: &PublicKey,
        principal: Option<&str>,
        kind: CertType,
        after: u64,
        before: u64,
        critical: bool,
    ) -> Certificate {
        let mut builder = russh::keys::ssh_key::certificate::Builder::new(
            vec![42; 16],
            leaf.key_data().clone(),
            after,
            before,
        )
        .unwrap();
        builder.cert_type(kind).unwrap();
        if let Some(principal) = principal {
            builder.valid_principal(principal).unwrap();
        } else {
            builder.all_principals_valid().unwrap();
        }
        if critical {
            builder
                .critical_option("unknown-option", "required")
                .unwrap();
        }
        builder.sign(ca).unwrap()
    }

    #[tokio::test]
    async fn unknown_key_requires_explicit_bound_decision_before_persistence() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let private = key();
        let check = verify(
            &path,
            "Example.COM",
            2222,
            private.public_key().clone().into(),
        );
        let prompt = wait_for_prompt(&path).await;
        assert!(!path.exists());
        assert!(!prompt.changed);
        assert_eq!(prompt.fingerprint, fingerprint(private.public_key()));
        assert_eq!(prompt.server_key_fingerprint, prompt.fingerprint);
        assert!(list_pending(&directory.path().join("other-vault"))
            .unwrap()
            .is_empty());
        assert!(decide(&path, "unknown-token", "trust", &prompt.fingerprint).is_err());
        assert!(decide(
            &directory.path().join("other-vault"),
            &prompt.request_id,
            "trust",
            &prompt.fingerprint
        )
        .is_err());
        assert!(decide(&path, &prompt.request_id, "trust", "SHA256:wrong-key").is_err());
        assert!(!check.is_finished());
        decide(&path, &prompt.request_id, "reject", &prompt.fingerprint).unwrap();
        assert!(check.await.unwrap().is_err());
        assert!(!path.exists());
        let check = verify(
            &path,
            "example.com",
            2222,
            private.public_key().clone().into(),
        );
        let approved = wait_for_prompt(&path).await;
        decide(&path, &approved.request_id, "trust", &approved.fingerprint).unwrap();
        assert_eq!(check.await.unwrap().unwrap(), approved.fingerprint);
        assert!(decide(&path, &approved.request_id, "trust", &approved.fingerprint).is_err());
        let record = std::fs::read_to_string(&path).unwrap();
        assert!(record.starts_with("[example.com]:2222 ssh-ed25519 "));
        verify_server_key(
            &path,
            "EXAMPLE.com",
            2222,
            &private.public_key().clone().into(),
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), record);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[tokio::test]
    async fn changed_key_requires_verified_replacement_and_cannot_silently_change_algorithm() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let original = key();
        provision(
            &path,
            "ssh.example",
            22,
            original.public_key(),
            false,
            false,
        );
        for algorithm in [
            Algorithm::Ed25519,
            Algorithm::Ecdsa {
                curve: russh::keys::EcdsaCurve::NistP256,
            },
        ] {
            let candidate = PrivateKey::random(&mut rand::rng(), algorithm).unwrap();
            let before = std::fs::read(&path).unwrap();
            let check = verify(
                &path,
                "ssh.example",
                22,
                candidate.public_key().clone().into(),
            );
            let prompt = wait_for_prompt(&path).await;
            assert!(prompt.changed);
            assert_eq!(prompt.previous_fingerprints.len(), 1);
            assert!(decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).is_err());
            decide(&path, &prompt.request_id, "reject", &prompt.fingerprint).unwrap();
            assert!(check
                .await
                .unwrap()
                .unwrap_err()
                .to_string()
                .contains("HOST KEY ĐÃ THAY ĐỔI"));
            assert_eq!(std::fs::read(&path).unwrap(), before);
            let check = verify(
                &path,
                "ssh.example",
                22,
                candidate.public_key().clone().into(),
            );
            let prompt = wait_for_prompt(&path).await;
            decide(
                &path,
                &prompt.request_id,
                "replace_verified",
                &prompt.fingerprint,
            )
            .unwrap();
            check.await.unwrap().unwrap();
            assert_eq!(
                list_records(&path).unwrap()[0].fingerprint,
                fingerprint(candidate.public_key())
            );
        }
    }

    #[tokio::test]
    async fn competing_approvals_and_store_changes_cannot_overwrite_verified_trust() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let a = key();
        let b = key();
        let first = verify(&path, "ssh.example", 22, a.public_key().clone().into());
        let first_prompt = wait_for_prompt(&path).await;
        let second = verify(&path, "ssh.example", 22, b.public_key().clone().into());
        tokio::time::timeout(Duration::from_secs(4), async {
            while list_pending(&path).unwrap().len() != 2 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        let second_prompt = list_pending(&path)
            .unwrap()
            .into_iter()
            .find(|p| p.request_id != first_prompt.request_id)
            .unwrap();
        decide(
            &path,
            &first_prompt.request_id,
            "trust",
            &first_prompt.fingerprint,
        )
        .unwrap();
        first.await.unwrap().unwrap();
        decide(
            &path,
            &second_prompt.request_id,
            "trust",
            &second_prompt.fingerprint,
        )
        .unwrap();
        assert!(second
            .await
            .unwrap()
            .unwrap_err()
            .to_string()
            .contains("đã thay đổi"));
        assert_eq!(list_records(&path).unwrap().len(), 1);
        assert_eq!(
            list_records(&path).unwrap()[0].fingerprint,
            fingerprint(a.public_key())
        );
    }

    #[tokio::test]
    async fn cancellation_expiry_and_abandoned_handshakes_fail_closed() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let private = key();
        let check = verify(
            &path,
            "ssh.example",
            22,
            private.public_key().clone().into(),
        );
        let prompt = wait_for_prompt(&path).await;
        let before_lock = current_epoch();
        cancel_pending().unwrap();
        assert!(verify_server_key_at_epoch(
            &path,
            "ssh.example",
            22,
            &private.public_key().clone().into(),
            before_lock
        )
        .await
        .is_err());
        assert!(check.await.unwrap().is_err());
        assert!(list_pending(&path).unwrap().is_empty());
        assert!(!path.exists());
        assert!(decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).is_err());
        let check = verify(
            &path,
            "ssh.example",
            22,
            private.public_key().clone().into(),
        );
        let prompt = wait_for_prompt(&path).await;
        pending()
            .lock()
            .unwrap()
            .get_mut(&prompt.request_id)
            .unwrap()
            .expires_at = Instant::now() - Duration::from_secs(1);
        assert!(decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).is_err());
        assert!(list_pending(&path).unwrap().is_empty());
        assert!(check.await.unwrap().is_err());
        let check = verify(
            &path,
            "ssh.example",
            22,
            private.public_key().clone().into(),
        );
        wait_for_prompt(&path).await;
        check.abort();
        let _ = check.await;
        assert!(list_pending(&path).unwrap().is_empty());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn management_requires_matching_fingerprints_and_preserves_aliases_and_port_scope() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let a = key();
        let b = key();
        assert!(import_public_key(
            &path,
            "ssh.example",
            22,
            &format!(
                "{}\nattacker.example {}",
                a.public_key().to_openssh().unwrap(),
                b.public_key().to_openssh().unwrap()
            ),
            false,
            false,
            &fingerprint(a.public_key())
        )
        .is_err());
        assert!(!path.exists());
        provision(&path, "ssh.example", 22, a.public_key(), false, false);
        provision(&path, "ssh.example", 22, a.public_key(), false, false);
        provision(&path, "ssh.example", 2222, b.public_key(), false, false);
        provision(&path, "2001:db8::1", 22, b.public_key(), false, false);
        provision(&path, "2001:db8::1", 2222, b.public_key(), false, false);
        assert_eq!(list_records(&path).unwrap().len(), 4);
        assert!(import_public_key(
            &path,
            "ssh.example",
            22,
            &b.public_key().to_openssh().unwrap(),
            false,
            false,
            &fingerprint(b.public_key())
        )
        .is_err());
        assert!(import_public_key(
            &path,
            "new.example",
            22,
            &b.public_key().to_openssh().unwrap(),
            false,
            false,
            &fingerprint(a.public_key())
        )
        .is_err());
        let record = list_records(&path)
            .unwrap()
            .into_iter()
            .find(|r| r.hostname == "ssh.example" && r.port == 22)
            .unwrap();
        assert!(remove_record(&path, &record.record_id, &fingerprint(b.public_key())).is_err());
        remove_record(&path, &record.record_id, &record.fingerprint).unwrap();
        assert_eq!(list_records(&path).unwrap().len(), 3);
        std::fs::write(
            &path,
            format!(
                "# existing aliases\nssh.example,alias.example {}\n",
                a.public_key().to_openssh().unwrap()
            ),
        )
        .unwrap();
        provision(&path, "ssh.example", 22, b.public_key(), true, true);
        let records = list_records(&path).unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(
            records
                .iter()
                .find(|r| r.hostname == "alias.example")
                .unwrap()
                .fingerprint,
            fingerprint(a.public_key())
        );
        assert!(
            records
                .iter()
                .find(|r| r.hostname == "ssh.example")
                .unwrap()
                .certificate_authority
        );
        assert!(std::fs::read_to_string(&path)
            .unwrap()
            .starts_with("# existing aliases\n"));
    }

    #[tokio::test]
    async fn corrupt_unsafe_revoked_and_injected_records_are_never_repaired_or_accepted() {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let private = key();
        for host in [
            "bad\nrecord",
            "*.example",
            "ssh.example,attacker",
            "",
            "[::1]",
        ] {
            assert!(
                verify_server_key(&path, host, 22, &private.public_key().clone().into())
                    .await
                    .is_err()
            );
        }
        assert!(!path.exists());
        let parent_file = directory.path().join("not_a_directory");
        std::fs::write(&parent_file, "existing").unwrap();
        assert!(list_records(&parent_file.join("known_hosts")).is_err());
        for content in [
            "broken record\n".to_string(),
            format!("*.example {}\n", private.public_key().to_openssh().unwrap()),
            format!(
                "!ssh.example {}\n",
                private.public_key().to_openssh().unwrap()
            ),
            format!(
                "@revoked ssh.example {}\n",
                private.public_key().to_openssh().unwrap()
            ),
        ] {
            std::fs::write(&path, &content).unwrap();
            assert!(verify_server_key(
                &path,
                "ssh.example",
                22,
                &private.public_key().clone().into()
            )
            .await
            .is_err());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), content);
            assert!(list_pending(&path).unwrap().is_empty());
        }
        assert!(import_public_key(
            &path,
            "ssh.example",
            22,
            &private.public_key().to_openssh().unwrap(),
            false,
            true,
            &fingerprint(private.public_key())
        )
        .is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::write(&path, "").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
            assert!(list_records(&path)
                .unwrap_err()
                .to_string()
                .contains("quyền 600"));
        }
    }

    #[tokio::test]
    async fn certificates_require_explicit_ca_trust_and_recheck_principal_time_signature_and_revocation(
    ) {
        let _guard = TEST_LOCK.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("known_hosts");
        let ca = key();
        let leaf = key();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let cert = certificate(
            &ca,
            leaf.public_key(),
            Some("ssh.example"),
            CertType::Host,
            now - 60,
            now + 3600,
            false,
        );
        let check = verify(&path, "ssh.example", 22, cert.clone().into());
        let prompt = wait_for_prompt(&path).await;
        assert!(prompt.certificate_authority);
        assert_eq!(prompt.fingerprint, fingerprint(ca.public_key()));
        assert_eq!(
            prompt.server_key_fingerprint,
            fingerprint(leaf.public_key())
        );
        assert_eq!(prompt.certificate_principals, vec!["ssh.example"]);
        decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).unwrap();
        check.await.unwrap().unwrap();
        assert!(list_records(&path).unwrap()[0].certificate_authority);
        verify_server_key(&path, "ssh.example", 22, &cert.clone().into())
            .await
            .unwrap();
        for invalid in [
            certificate(
                &ca,
                leaf.public_key(),
                Some("attacker.example"),
                CertType::Host,
                now - 60,
                now + 3600,
                false,
            ),
            certificate(
                &ca,
                leaf.public_key(),
                None,
                CertType::Host,
                now - 60,
                now + 3600,
                false,
            ),
            certificate(
                &ca,
                leaf.public_key(),
                Some("ssh.example"),
                CertType::User,
                now - 60,
                now + 3600,
                false,
            ),
            certificate(
                &ca,
                leaf.public_key(),
                Some("ssh.example"),
                CertType::Host,
                now - 3600,
                now - 60,
                false,
            ),
            certificate(
                &ca,
                leaf.public_key(),
                Some("ssh.example"),
                CertType::Host,
                now + 3600,
                now + 7200,
                false,
            ),
            certificate(
                &ca,
                leaf.public_key(),
                Some("ssh.example"),
                CertType::Host,
                now - 60,
                now + 3600,
                true,
            ),
        ] {
            assert!(verify_server_key(&path, "ssh.example", 22, &invalid.into())
                .await
                .is_err());
            assert!(list_pending(&path).unwrap().is_empty());
        }
        let mut tampered = cert.to_bytes().unwrap();
        *tampered.last_mut().unwrap() ^= 1;
        let invalid = Certificate::from_bytes(&tampered).unwrap();
        assert!(verify_server_key(&path, "ssh.example", 22, &invalid.into())
            .await
            .is_err());
        let untrusted_ca = key();
        let other_cert = certificate(
            &untrusted_ca,
            leaf.public_key(),
            Some("ssh.example"),
            CertType::Host,
            now - 60,
            now + 3600,
            false,
        );
        let check = verify(&path, "ssh.example", 22, other_cert.into());
        let prompt = wait_for_prompt(&path).await;
        assert!(prompt.changed && prompt.certificate_authority);
        assert!(decide(&path, &prompt.request_id, "trust", &prompt.fingerprint).is_err());
        decide(&path, &prompt.request_id, "reject", &prompt.fingerprint).unwrap();
        assert!(check.await.unwrap().is_err());
        let trusted = std::fs::read_to_string(&path).unwrap();
        for revoked_key in [ca.public_key(), leaf.public_key()] {
            std::fs::write(
                &path,
                format!(
                    "{trusted}@revoked ssh.example {}\n",
                    revoked_key.to_openssh().unwrap()
                ),
            )
            .unwrap();
            assert!(
                verify_server_key(&path, "ssh.example", 22, &cert.clone().into())
                    .await
                    .unwrap_err()
                    .to_string()
                    .contains("thu hồi")
            );
        }
    }
}
