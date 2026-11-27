use russh::keys::{Algorithm, HashAlg, PrivateKey};
use russh::server::{self, Auth, Msg, Server as _, Session, VerifiedPublicKey};
use russh::{Channel, ChannelId, Pty};
use russh_sftp::protocol::{
    Attrs, File, FileAttributes, Handle, Name, OpenFlags, SftpHandle, Status, StatusCode, Version,
};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

#[derive(Clone)]
struct QaSshServer {
    root_dir: PathBuf,
}

impl server::Server for QaSshServer {
    type Handler = QaSession;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        QaSession {
            root_dir: self.root_dir.clone(),
            channels: Arc::new(Mutex::new(HashMap::new())),
            pty_cols: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

struct QaSession {
    root_dir: PathBuf,
    channels: Arc<Mutex<HashMap<ChannelId, Channel<Msg>>>>,
    pty_cols: Arc<Mutex<HashMap<ChannelId, u32>>>,
}

fn format_dir_listing(root: &Path, cwd: &str) -> String {
    let rel = cwd.trim_start_matches('/');
    let host_dir = root.join(rel);
    let mut lines = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&host_dir) {
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let name = e.file_name().to_string_lossy().to_string();
            let md = e.metadata();
            let is_dir = md.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let size = md.as_ref().map(|m| m.len()).unwrap_or(0);
            if is_dir {
                lines.push(format!("\x1b[1;34mdrwxr-xr-x\x1b[0m  4096 {name}/"));
            } else {
                lines.push(format!("-rw-r--r-- {:>5} {name}", size));
            }
        }
    }
    if lines.is_empty() {
        "(empty directory)".into()
    } else {
        lines.join("\r\n")
    }
}

// This fixture deliberately paces writes so native UI tests can observe and
// exercise pause/resume/cancel before a loopback upload finishes.
fn qa_write_delay() -> Duration {
    static DELAY: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *DELAY.get_or_init(|| {
        let millis = std::env::var("TERMPULSE_QA_SFTP_WRITE_DELAY_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(20)
            .min(250);
        Duration::from_millis(millis)
    })
}

impl server::Handler for QaSession {
    type Error = anyhow::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "ops" && password == "termpulse2026" {
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
        if user == "ops" {
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
        col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.pty_cols.lock().await.insert(channel, col_width);
        session.channel_success(channel)?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.pty_cols.lock().await.insert(channel, col_width);
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel_id: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel_id)?;
        let root_dir = self.root_dir.clone();
        let cols = self
            .pty_cols
            .lock()
            .await
            .get(&channel_id)
            .copied()
            .unwrap_or(56)
            .clamp(38, 56) as usize;
        if let Some(mut ch) = self.channels.lock().await.remove(&channel_id) {
            tokio::spawn(async move {
                let mut cwd = "/home/ops/app".to_string();
                let inner_w = cols.saturating_sub(2).max(36);
                let title_text = "TermPulse SSHv2 · SFTP · /proc · Tunnel";
                let title_fit: String =
                    title_text.chars().take(inner_w.saturating_sub(2)).collect();
                let title_len = title_fit.chars().count();
                let pad_left = (inner_w.saturating_sub(title_len)) / 2;
                let pad_right = inner_w.saturating_sub(title_len + pad_left);
                let hline = "─".repeat(inner_w);
                let banner = format!(
                    "\x1b[1;36m╭{hline}╮\x1b[0m\r\n\
                     \x1b[1;36m│\x1b[0m{lp}\x1b[1;32m{title_fit}\x1b[0m{rp}\x1b[1;36m│\x1b[0m\r\n\
                     \x1b[1;36m╰{hline}╯\x1b[0m\r\n\
                     WELCOME_TERMPULSE\r\n\
                     Ubuntu 24.04.2 LTS · Kernel 6.8.0-49-generic x86_64\r\n\
                     \x1b]7;file://qa-server/home/ops/app\x07\
                     \x1b[1;32mops@prod-web-01\x1b[0m:\x1b[1;34m/home/ops/app\x1b[0m$ ",
                    lp = " ".repeat(pad_left),
                    rp = " ".repeat(pad_right),
                );
                let _ = ch.data(banner.as_bytes()).await;

                let mut line_buf = String::new();
                while let Some(msg) = ch.wait().await {
                    match msg {
                        russh::ChannelMsg::Data { data } => {
                            let s = String::from_utf8_lossy(&data).to_string();
                            for c in s.chars() {
                                if c == '\r' || c == '\n' {
                                    let _ = ch.data(&b"\r\n"[..]).await;
                                    let cmd = line_buf.trim().to_string();
                                    line_buf.clear();
                                    if cmd.is_empty() {
                                        // just re-prompt
                                    } else if let Some(rest) = cmd.strip_prefix("cd ") {
                                        let raw_target =
                                            rest.trim().trim_matches('\'').trim_matches('"');
                                        let next_cwd = if raw_target == "~" || raw_target.is_empty()
                                        {
                                            "/home/ops/app".to_string()
                                        } else if raw_target.starts_with('/') {
                                            raw_target.to_string()
                                        } else {
                                            format!("{}/{}", cwd.trim_end_matches('/'), raw_target)
                                        };
                                        let disk = root_dir.join(next_cwd.trim_start_matches('/'));
                                        if disk.is_dir() {
                                            cwd = next_cwd;
                                            let osc7 = format!("\x1b]7;file://qa-server{cwd}\x07");
                                            let _ = ch.data(osc7.as_bytes()).await;
                                        } else {
                                            let msg = format!("bash: cd: {raw_target}: No such file or directory\r\n");
                                            let _ = ch.data(msg.as_bytes()).await;
                                        }
                                    } else if cmd == "pwd" {
                                        let out = format!("{cwd}\r\n");
                                        let _ = ch.data(out.as_bytes()).await;
                                    } else if cmd.starts_with("ls") {
                                        let out =
                                            format!("{}\r\n", format_dir_listing(&root_dir, &cwd));
                                        let _ = ch.data(out.as_bytes()).await;
                                    } else if cmd == "agent-done" {
                                        let osc777 = "\x1b]777;notify;TermPulse QA;Notification received\x1b\\\x1b[1;35m[Agent Notification]\x1b[0m Notification round-trip complete\r\n";
                                        let _ = ch.data(osc777.as_bytes()).await;
                                    } else if cmd == "uname -a" {
                                        let _ = ch.data(&b"Linux prod-web-01 6.8.0-49-generic #49-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux\r\n"[..]).await;
                                    } else {
                                        let out =
                                            format!("\x1b[32m[ok]\x1b[0m executed: {cmd}\r\n");
                                        let _ = ch.data(out.as_bytes()).await;
                                    }
                                    let prompt = format!(
                                        "\x1b[1;32mops@prod-web-01\x1b[0m:\x1b[1;34m{cwd}\x1b[0m$ "
                                    );
                                    let _ = ch.data(prompt.as_bytes()).await;
                                } else if c == '\x7f' || c == '\x08' {
                                    if !line_buf.is_empty() {
                                        line_buf.pop();
                                        let _ = ch.data(&b"\x08 \x08"[..]).await;
                                    }
                                } else {
                                    line_buf.push(c);
                                    let mut tmp = [0u8; 4];
                                    let encoded = c.encode_utf8(&mut tmp);
                                    let _ = ch.data(encoded.as_bytes()).await;
                                }
                            }
                        }
                        russh::ChannelMsg::Eof | russh::ChannelMsg::Close => break,
                        _ => {}
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
        session.channel_success(channel_id)?;
        let cmd = String::from_utf8_lossy(data).to_string();
        if let Some(ch) = self.channels.lock().await.remove(&channel_id) {
            tokio::spawn(async move {
                if cmd.contains("/proc/stat") {
                    let sample = b"CPU=2800,2000\nMEM=2410,8192\nDISK=42.60,120.00\nNET=1840000,920000\nLOAD=0.62 0.48 0.35\nUP=86400\n";
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
                let handler = QaSftpFs {
                    root: self.root_dir.clone(),
                    files: HashMap::new(),
                    dirs_read: HashMap::new(),
                    dirs_path: HashMap::new(),
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
            } else {
                let _ = channel
                    .data(&b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nTermPulse Direct-TCPIP Tunnel OK\r\n"[..])
                    .await;
                let _ = channel.eof().await;
            }
        });
        Ok(())
    }
}

struct QaSftpFs {
    root: PathBuf,
    files: HashMap<String, PathBuf>,
    dirs_read: HashMap<String, bool>,
    dirs_path: HashMap<String, PathBuf>,
}

impl QaSftpFs {
    fn normalize_virtual(raw: &str) -> String {
        if raw.is_empty() || raw == "." {
            return "/home/ops/app".to_string();
        }
        let mut stack: Vec<String> = Vec::new();
        for comp in Path::new(raw).components() {
            match comp {
                Component::RootDir | Component::CurDir => {}
                Component::ParentDir => {
                    stack.pop();
                }
                Component::Normal(p) => {
                    stack.push(p.to_string_lossy().to_string());
                }
                Component::Prefix(_) => {}
            }
        }
        if stack.is_empty() {
            "/".to_string()
        } else {
            format!("/{}", stack.join("/"))
        }
    }

    fn resolve_disk(&self, virtual_path: &str) -> PathBuf {
        let norm = Self::normalize_virtual(virtual_path);
        let rel = norm.trim_start_matches('/');
        if rel.is_empty() {
            self.root.clone()
        } else {
            self.root.join(rel)
        }
    }

    fn ok_status(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: "Ok".into(),
            language_tag: "en-US".into(),
        }
    }

    fn attrs_for(md: &std::fs::Metadata) -> FileAttributes {
        let mut attrs = FileAttributes::default();
        attrs.size = Some(md.len());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            attrs.permissions = Some(md.permissions().mode());
        }
        #[cfg(not(unix))]
        {
            attrs.permissions = Some(if md.is_dir() { 0o040755 } else { 0o100644 });
        }
        attrs
    }
}

impl russh_sftp::server::Handler for QaSftpFs {
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
        let norm = Self::normalize_virtual(&path);
        Ok(Name {
            id,
            files: vec![File::new(norm, FileAttributes::default())],
        })
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let disk = self.resolve_disk(&path);
        let md = std::fs::metadata(&disk).map_err(|_| StatusCode::NoSuchFile)?;
        Ok(Attrs {
            id,
            attrs: Self::attrs_for(&md),
        })
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let disk = self.resolve_disk(&path);
        let md = std::fs::symlink_metadata(&disk).map_err(|_| StatusCode::NoSuchFile)?;
        Ok(Attrs {
            id,
            attrs: Self::attrs_for(&md),
        })
    }

    async fn setstat(
        &mut self,
        id: u32,
        path: String,
        attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        let disk = self.resolve_disk(&path);
        if !disk.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        if let Some(mode) = attrs.permissions {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&disk, std::fs::Permissions::from_mode(mode & 0o7777))
                    .map_err(|_| StatusCode::PermissionDenied)?;
            }
            #[cfg(not(unix))]
            {
                let _ = mode;
                return Err(StatusCode::OpUnsupported);
            }
        }
        if let Some(size) = attrs.size {
            std::fs::OpenOptions::new()
                .write(true)
                .open(&disk)
                .and_then(|file| file.set_len(size))
                .map_err(|_| StatusCode::Failure)?;
        }
        if attrs.permissions.is_none() && attrs.size.is_none() {
            return Err(StatusCode::OpUnsupported);
        }
        Ok(Self::ok_status(id))
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        let disk = self.resolve_disk(&path);
        if !disk.is_dir() {
            return Err(StatusCode::NoSuchFile);
        }
        let h = format!("dir_{id}_{path}");
        self.dirs_read.insert(h.clone(), false);
        self.dirs_path.insert(h.clone(), disk);
        Ok(Handle {
            id,
            handle: h.into(),
        })
    }

    async fn readdir(&mut self, id: u32, handle: SftpHandle) -> Result<Name, Self::Error> {
        let key = String::from_utf8_lossy(handle.as_bytes()).to_string();
        if *self.dirs_read.get(&key).unwrap_or(&true) {
            return Err(StatusCode::Eof);
        }
        self.dirs_read.insert(key.clone(), true);
        let dir = self.dirs_path.get(&key).ok_or(StatusCode::NoSuchFile)?;
        let mut out = Vec::new();
        if let Ok(rd) = std::fs::read_dir(dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                let attrs = e
                    .metadata()
                    .map(|md| Self::attrs_for(&md))
                    .unwrap_or_default();
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
        let full = self.resolve_disk(&filename);
        if pflags.contains(OpenFlags::CREATE) {
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::OpenOptions::new()
                .create(true)
                .truncate(pflags.contains(OpenFlags::TRUNCATE))
                .write(true)
                .open(&full)
                .map_err(|_| StatusCode::Failure)?;
        } else if !full.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        let h = format!("fh_{id}_{filename}");
        self.files.insert(h.clone(), full);
        Ok(Handle {
            id,
            handle: h.into(),
        })
    }

    async fn read(
        &mut self,
        id: u32,
        handle: SftpHandle,
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
        handle: SftpHandle,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        use std::io::{Seek, SeekFrom, Write};
        tokio::time::sleep(qa_write_delay()).await;
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
        Ok(Self::ok_status(id))
    }

    async fn close(&mut self, id: u32, handle: SftpHandle) -> Result<Status, Self::Error> {
        let key = String::from_utf8_lossy(handle.as_bytes()).to_string();
        self.files.remove(&key);
        self.dirs_read.remove(&key);
        self.dirs_path.remove(&key);
        Ok(Self::ok_status(id))
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        let full = self.resolve_disk(&path);
        std::fs::create_dir_all(&full).map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        let full = self.resolve_disk(&filename);
        std::fs::remove_file(&full).map_err(|_| StatusCode::NoSuchFile)?;
        Ok(Self::ok_status(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        let full = self.resolve_disk(&path);
        std::fs::remove_dir(&full).map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }

    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, Self::Error> {
        let old_disk = self.resolve_disk(&oldpath);
        let new_disk = self.resolve_disk(&newpath);
        std::fs::rename(&old_disk, &new_disk).map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }
}

fn seed_qa_filesystem(root: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(root.join("home/ops/app"))?;
    std::fs::create_dir_all(root.join("etc/nginx"))?;
    std::fs::create_dir_all(root.join("var/log"))?;
    std::fs::write(
        root.join("home/ops/app/.termpulse-qa-fixture.json"),
        format!(
            "{{\"fixture\":\"termpulse-controlled-ssh\",\"writeDelayMs\":{},\"realUnixPermissions\":{}}}",
            qa_write_delay().as_millis(),
            cfg!(unix)
        ),
    )?;

    std::fs::write(
        root.join("home/ops/app/main.rs"),
        b"fn main() {\n    println!(\"TermPulse QA server running on :8080\");\n}\n",
    )?;
    std::fs::write(
        root.join("home/ops/app/Cargo.toml"),
        b"[package]\nname = \"qa-service\"\nversion = \"1.4.2\"\nedition = \"2021\"\n",
    )?;
    std::fs::write(
        root.join("home/ops/app/.env"),
        b"APP_ENV=production\nPORT=8080\nLOG_LEVEL=info\n",
    )?;
    std::fs::write(
        root.join("etc/nginx/nginx.conf"),
        b"worker_processes auto;\nhttp {\n  server {\n    listen 80;\n    location / { proxy_pass http://127.0.0.1:8080; }\n  }\n}\n",
    )?;
    std::fs::write(
        root.join("etc/nginx/mime.types"),
        b"types {\n  text/html html htm;\n  application/json json;\n}\n",
    )?;
    std::fs::write(
        root.join("var/log/syslog"),
        b"Nov 26 21:00:01 prod-web-01 systemd[1]: Started qa-service.service.\n",
    )?;
    std::fs::write(
        root.join("var/log/auth.log"),
        b"Nov 26 21:01:12 prod-web-01 sshd[4102]: Accepted password for ops from 127.0.0.1\n",
    )?;
    std::fs::write(
        root.join("var/log/app-error.log"),
        b"[WARN] Slow upstream query took 142ms\n",
    )?;
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let qa_directory = tempfile::tempdir()?;
    let root = qa_directory.path().to_path_buf();
    seed_qa_filesystem(&root)?;

    // Also spawn a tiny local HTTP health target on 127.0.0.1:18080 so direct-tcpip tunnels have a real target
    let http_listener = TcpListener::bind("127.0.0.1:18080").await?;
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = http_listener.accept().await {
            tokio::spawn(async move {
                let _ = sock
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 24\r\n\r\nTermPulse Tunnel Target\n",
                    )
                    .await;
            });
        }
    });

    let host_key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?;
    let host_fingerprint = host_key.public_key().fingerprint(HashAlg::Sha256);
    let config = Arc::new(server::Config {
        keys: vec![host_key],
        auth_rejection_time: Duration::from_millis(20),
        ..Default::default()
    });
    let listener = TcpListener::bind("127.0.0.1:22220").await?;
    println!(
        "QA_SSH_SERVER_LISTENING=127.0.0.1:22220 root={}",
        root.display()
    );
    println!("QA_SSH_SERVER_FINGERPRINT={host_fingerprint}");
    let mut srv = QaSshServer { root_dir: root };
    srv.run_on_socket(config, &listener).await?;
    Ok(())
}
