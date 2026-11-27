//! Loopback-only synthetic desktop for Android RDP gesture/rendering QA.
//!
//! Run `cargo run --manifest-path rust/Cargo.toml --example qa_rdp_server`.
//! Reverse tcp:33890 and tcp:18081 to an Android test device. Startup prints
//! the independently generated TLS pin; only that pin may be passed to the
//! touchpad diagnostic as QA_RDP_FINGERPRINT. No user data or shell is exposed.
//! Set QA_RDP_TLS_DIR to a private directory to retain the test pin across
//! fixture restarts. QA_RDP_LIFETIME_SECS accepts 60..=3600 (default: 600).

use std::collections::VecDeque;
use std::fs;
use std::io::{ErrorKind, Write};
use std::num::{NonZeroU16, NonZeroUsize};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp_server::{
    BitmapUpdate, DesktopSize, DisplayUpdate, KeyboardEvent, MouseEvent, RdpServer,
    RdpServerDisplay, RdpServerDisplayUpdates, RdpServerInputHandler,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_rustls::rustls;

const WIDTH: u16 = 1280;
const HEIGHT: u16 = 720;
const RDP_PORT: u16 = 33890;
const HTTP_PORT: u16 = 18081;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Stats {
    fixture: &'static str,
    width: u16,
    height: u16,
    ticks: u64,
    moves: u64,
    left_down: u64,
    left_up: u64,
    right_down: u64,
    right_up: u64,
    keys: u64,
    pointer_x: u16,
    pointer_y: u16,
    input_sequence: u64,
}

impl Default for Stats {
    fn default() -> Self {
        Self {
            fixture: "termpulse-controlled-rdp-v1",
            width: WIDTH,
            height: HEIGHT,
            ticks: 0,
            moves: 0,
            left_down: 0,
            left_up: 0,
            right_down: 0,
            right_up: 0,
            keys: 0,
            pointer_x: WIDTH / 2,
            pointer_y: HEIGHT / 2,
            input_sequence: 0,
        }
    }
}

#[derive(Clone)]
struct Fixture(Arc<Mutex<Stats>>);

impl RdpServerInputHandler for Fixture {
    fn keyboard(&mut self, _: KeyboardEvent) {
        let mut state = self.0.lock().expect("fixture stats");
        state.keys += 1;
        state.input_sequence += 1;
    }

    fn mouse(&mut self, event: MouseEvent) {
        let mut state = self.0.lock().expect("fixture stats");
        match event {
            MouseEvent::Move { x, y } => {
                state.pointer_x = x.min(WIDTH - 1);
                state.pointer_y = y.min(HEIGHT - 1);
                state.moves += 1;
            }
            MouseEvent::LeftPressed => state.left_down += 1,
            MouseEvent::LeftReleased => state.left_up += 1,
            MouseEvent::RightPressed => state.right_down += 1,
            MouseEvent::RightReleased => state.right_up += 1,
            _ => {}
        }
        state.input_sequence += 1;
    }
}

// Small bitmap lettering keeps this fixture self-contained and deterministic.
fn glyph(c: char) -> [u8; 7] {
    match c {
        'A' => [14, 17, 17, 31, 17, 17, 17],
        'B' => [30, 17, 17, 30, 17, 17, 30],
        'C' => [14, 17, 16, 16, 16, 17, 14],
        'D' => [30, 17, 17, 17, 17, 17, 30],
        'E' => [31, 16, 16, 30, 16, 16, 31],
        'F' => [31, 16, 16, 30, 16, 16, 16],
        'G' => [14, 17, 16, 23, 17, 17, 15],
        'H' => [17, 17, 17, 31, 17, 17, 17],
        'I' => [14, 4, 4, 4, 4, 4, 14],
        'J' => [7, 2, 2, 2, 18, 18, 12],
        'K' => [17, 18, 20, 24, 20, 18, 17],
        'L' => [16, 16, 16, 16, 16, 16, 31],
        'M' => [17, 27, 21, 21, 17, 17, 17],
        'N' => [17, 25, 21, 19, 17, 17, 17],
        'O' => [14, 17, 17, 17, 17, 17, 14],
        'P' => [30, 17, 17, 30, 16, 16, 16],
        'Q' => [14, 17, 17, 17, 21, 18, 13],
        'R' => [30, 17, 17, 30, 20, 18, 17],
        'S' => [15, 16, 16, 14, 1, 1, 30],
        'T' => [31, 4, 4, 4, 4, 4, 4],
        'U' => [17, 17, 17, 17, 17, 17, 14],
        'V' => [17, 17, 17, 17, 17, 10, 4],
        'W' => [17, 17, 17, 21, 21, 21, 10],
        'X' => [17, 17, 10, 4, 10, 17, 17],
        'Y' => [17, 17, 10, 4, 4, 4, 4],
        'Z' => [31, 1, 2, 4, 8, 16, 31],
        '0' => [14, 17, 19, 21, 25, 17, 14],
        '1' => [4, 12, 4, 4, 4, 4, 14],
        '2' => [14, 17, 1, 2, 4, 8, 31],
        '3' => [30, 1, 1, 14, 1, 1, 30],
        '4' => [2, 6, 10, 18, 31, 2, 2],
        '5' => [31, 16, 16, 30, 1, 1, 30],
        '6' => [14, 16, 16, 30, 17, 17, 14],
        '7' => [31, 1, 2, 4, 8, 8, 8],
        '8' => [14, 17, 17, 14, 17, 17, 14],
        '9' => [14, 17, 17, 15, 1, 1, 14],
        ':' => [0, 4, 4, 0, 4, 4, 0],
        '-' => [0, 0, 0, 31, 0, 0, 0],
        '/' => [1, 2, 2, 4, 8, 8, 16],
        _ => [0; 7],
    }
}

fn rect(data: &mut [u8], w: usize, x: usize, y: usize, rw: usize, rh: usize, rgb: [u8; 3]) {
    let h = data.len() / (w * 4);
    for py in y..(y + rh).min(h) {
        for px in x..(x + rw).min(w) {
            let at = (py * w + px) * 4;
            data[at..at + 4].copy_from_slice(&[rgb[2], rgb[1], rgb[0], 255]);
        }
    }
}

fn text(data: &mut [u8], w: usize, x: usize, y: usize, value: &str, scale: usize) {
    for (index, character) in value.chars().enumerate() {
        for (row, bits) in glyph(character).iter().enumerate() {
            for column in 0..5 {
                if bits & (1 << (4 - column)) != 0 {
                    rect(
                        data,
                        w,
                        x + (index * 6 + column) * scale,
                        y + row * scale,
                        scale,
                        scale,
                        [230, 237, 245],
                    );
                }
            }
        }
    }
}

fn background() -> Vec<u8> {
    let w = usize::from(WIDTH);
    let mut data = [27, 22, 18, 255].repeat(w * usize::from(HEIGHT));
    for x in (0..w).step_by(80) {
        rect(&mut data, w, x, 0, 1, HEIGHT.into(), [42, 53, 66]);
    }
    for y in (0..usize::from(HEIGHT)).step_by(80) {
        rect(&mut data, w, 0, y, w, 1, [42, 53, 66]);
    }
    rect(&mut data, w, 0, 0, w, 68, [35, 53, 73]);
    text(
        &mut data,
        w,
        28,
        20,
        "TERMPULSE CONTROLLED DESKTOP 1280 X 720",
        4,
    );
    text(&mut data, w, 40, 105, "SYNTHETIC DATA ONLY", 3);
    text(&mut data, w, 40, 150, "SWIPE TO MOVE POINTER", 3);
    text(
        &mut data,
        w,
        40,
        194,
        "ONE TAP LEFT - TWO FINGER TAP RIGHT",
        3,
    );
    text(
        &mut data,
        w,
        40,
        238,
        "PINCH TO ZOOM - FULLSCREEN TO READ",
        3,
    );
    for (x, label, color) in [
        (60, "LEFT CLICK", [30, 100, 90]),
        (460, "RIGHT CLICK", [57, 73, 120]),
        (860, "SCROLL TEST", [110, 75, 44]),
    ] {
        rect(&mut data, w, x, 330, 350, 120, color);
        text(&mut data, w, x + 20, 375, label, 4);
    }
    text(&mut data, w, 40, 485, "REMOTE TEXT AT 100 PERCENT", 2);
    text(
        &mut data,
        w,
        40,
        520,
        "ZOOM WITHOUT ACCIDENTAL REMOTE CLICKS",
        2,
    );
    data
}

fn bitmap(x: u16, y: u16, width: u16, height: u16, data: Vec<u8>) -> DisplayUpdate {
    DisplayUpdate::Bitmap(BitmapUpdate {
        x,
        y,
        width: NonZeroU16::new(width).unwrap(),
        height: NonZeroU16::new(height).unwrap(),
        format: PixelFormat::BgrA32,
        data: data.into(),
        stride: NonZeroUsize::new(usize::from(width) * 4).unwrap(),
    })
}

struct Updates {
    fixture: Fixture,
    interval: tokio::time::Interval,
    initial: bool,
    base: Vec<u8>,
    queued: VecDeque<DisplayUpdate>,
    previous_pointer: Option<(u16, u16)>,
}

impl Updates {
    fn cursor_patch(&self, x: u16, y: u16, draw: bool) -> DisplayUpdate {
        let left = x.saturating_sub(12).min(WIDTH - 25);
        let top = y.saturating_sub(12).min(HEIGHT - 25);
        let mut data = Vec::with_capacity(25 * 25 * 4);
        for row in top..top + 25 {
            let start = (usize::from(row) * usize::from(WIDTH) + usize::from(left)) * 4;
            data.extend_from_slice(&self.base[start..start + 25 * 4]);
        }
        if draw {
            rect(&mut data, 25, 11, 0, 3, 25, [255, 240, 40]);
            rect(&mut data, 25, 0, 11, 25, 3, [255, 240, 40]);
        }
        bitmap(left, top, 25, 25, data)
    }
}

#[async_trait::async_trait]
impl RdpServerDisplayUpdates for Updates {
    async fn next_update(&mut self) -> anyhow::Result<Option<DisplayUpdate>> {
        if let Some(update) = self.queued.pop_front() {
            return Ok(Some(update));
        }
        if self.initial {
            self.initial = false;
            return Ok(Some(bitmap(0, 0, WIDTH, HEIGHT, self.base.clone())));
        }
        self.interval.tick().await;
        let state = {
            let mut current = self.fixture.0.lock().expect("fixture stats");
            current.ticks += 1;
            current.clone()
        };
        if let Some((x, y)) = self.previous_pointer {
            if (x, y) != (state.pointer_x, state.pointer_y) {
                self.queued.push_back(self.cursor_patch(x, y, false));
            }
        }
        self.previous_pointer = Some((state.pointer_x, state.pointer_y));
        self.queued
            .push_back(self.cursor_patch(state.pointer_x, state.pointer_y, true));
        let mut status = [51, 39, 28, 255].repeat(1280 * 132);
        text(
            &mut status,
            1280,
            24,
            12,
            &format!("FRAMES {} INPUT {}", state.ticks, state.input_sequence),
            3,
        );
        text(
            &mut status,
            1280,
            24,
            52,
            &format!(
                "LEFT {} / {} RIGHT {} / {}",
                state.left_down, state.left_up, state.right_down, state.right_up
            ),
            3,
        );
        text(
            &mut status,
            1280,
            24,
            92,
            &format!(
                "POINTER {} : {} KEYS {}",
                state.pointer_x, state.pointer_y, state.keys
            ),
            3,
        );
        // Fixed-position color marker changes with input, independently of text
        // and animation. Native tests can match with codec quantization tolerance.
        let red = ((state.input_sequence % 8) * 28 + 16) as u8;
        let green = (((state.input_sequence / 8) % 8) * 28 + 16) as u8;
        rect(&mut status, 1280, 1216, 12, 48, 48, [red, green, 80]);
        self.queued
            .push_back(bitmap(0, HEIGHT - 132, WIDTH, 132, status));
        Ok(self.queued.pop_front())
    }
}

#[async_trait::async_trait]
impl RdpServerDisplay for Fixture {
    async fn size(&mut self) -> DesktopSize {
        DesktopSize {
            width: WIDTH,
            height: HEIGHT,
        }
    }

    async fn updates(&mut self) -> anyhow::Result<Box<dyn RdpServerDisplayUpdates>> {
        let mut interval = tokio::time::interval(Duration::from_millis(50));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        Ok(Box::new(Updates {
            fixture: self.clone(),
            interval,
            initial: true,
            base: background(),
            queued: VecDeque::new(),
            previous_pointer: None,
        }))
    }
}

async fn serve_stats(listener: TcpListener, fixture: Fixture) -> anyhow::Result<()> {
    loop {
        let (mut socket, _) = listener.accept().await?;
        let mut request = [0; 1024];
        let size = socket.read(&mut request).await?;
        let valid = request[..size].starts_with(b"GET /stats ");
        let body = if valid {
            serde_json::to_string(&*fixture.0.lock().expect("fixture stats"))?
        } else {
            "{\"error\":\"fixture_stats_only\"}".into()
        };
        let status = if valid { "200 OK" } else { "404 Not Found" };
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        socket.write_all(response.as_bytes()).await?;
        socket.shutdown().await?;
    }
}

fn read_private_file(path: &Path) -> anyhow::Result<Option<Vec<u8>>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    anyhow::ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "QA TLS identity files must be ordinary files"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        anyhow::ensure!(
            metadata.permissions().mode() & 0o077 == 0,
            "QA TLS identity files must be private (0600)"
        );
    }
    Ok(Some(fs::read(path)?))
}

fn write_new_private_file(path: &Path, data: &[u8]) -> anyhow::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    let result = file.write_all(data).and_then(|_| file.sync_all());
    if result.is_err() {
        drop(file);
        let _ = fs::remove_file(path);
    }
    result.map_err(Into::into)
}

fn tls_identity() -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
    let generate = || -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()])?;
        Ok((cert.cert.der().to_vec(), cert.signing_key.serialize_der()))
    };
    let Some(directory) = std::env::var_os("QA_RDP_TLS_DIR") else {
        return generate();
    };
    let directory = Path::new(&directory);
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(directory) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(directory)?;
    anyhow::ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "QA_RDP_TLS_DIR must be an ordinary private directory"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        anyhow::ensure!(
            metadata.permissions().mode() & 0o077 == 0,
            "QA_RDP_TLS_DIR must be private (0700)"
        );
    }
    let cert_path = directory.join("server-cert.der");
    let key_path = directory.join("server-key.der");
    match (
        read_private_file(&cert_path)?,
        read_private_file(&key_path)?,
    ) {
        (Some(cert), Some(key)) => Ok((cert, key)),
        (None, None) => {
            let (cert, key) = generate()?;
            write_new_private_file(&key_path, &key)?;
            if let Err(error) = write_new_private_file(&cert_path, &cert) {
                let _ = fs::remove_file(&key_path);
                return Err(error);
            }
            Ok((cert, key))
        }
        _ => anyhow::bail!("QA TLS identity is incomplete; both DER files must exist"),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    let lifetime_secs = std::env::var("QA_RDP_LIFETIME_SECS")
        .unwrap_or_else(|_| "600".into())
        .parse::<u64>()?;
    anyhow::ensure!(
        (60..=3600).contains(&lifetime_secs),
        "QA_RDP_LIFETIME_SECS must be between 60 and 3600"
    );
    let lifetime = Duration::from_secs(lifetime_secs);
    let (cert, key) = tls_identity()?;
    let der = rustls::pki_types::CertificateDer::from(cert);
    let pin = Sha256::digest(der.as_ref())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(key);
    let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_no_client_auth()
    .with_single_cert(vec![der], key.into())?;
    let rdp = TcpListener::bind(("127.0.0.1", RDP_PORT)).await?;
    let stats = TcpListener::bind(("127.0.0.1", HTTP_PORT)).await?;
    let fixture = Fixture(Arc::new(Mutex::new(Stats::default())));
    let stats_task = tokio::spawn(serve_stats(stats, fixture.clone()));
    println!("TERMPULSE_QA_RDP_READY {{\"rdpPort\":{RDP_PORT},\"httpPort\":{HTTP_PORT},\"width\":{WIDTH},\"height\":{HEIGHT},\"lifetimeSecs\":{lifetime_secs},\"tlsSha256\":\"{pin}\",\"username\":\"fixture\",\"password\":\"fixture-password\"}}");
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(tls));
    let started = Instant::now();
    while started.elapsed() < lifetime {
        let remaining = lifetime.saturating_sub(started.elapsed());
        let (socket, _) = match tokio::time::timeout(remaining, rdp.accept()).await {
            Ok(accepted) => accepted?,
            Err(_) => break,
        };
        socket.set_nodelay(true)?;
        let mut server = RdpServer::builder()
            .with_addr(rdp.local_addr()?)
            .with_tls(acceptor.clone())
            .with_input_handler(fixture.clone())
            .with_display_handler(fixture.clone())
            .build();
        server.set_credentials(Some(ironrdp_server::Credentials {
            username: "fixture".into(),
            password: "fixture-password".into(),
            domain: None,
        }));
        // Certificate probes intentionally disconnect before authentication.
        let remaining = lifetime.saturating_sub(started.elapsed());
        let _ = tokio::time::timeout(
            remaining.min(Duration::from_secs(300)),
            server.run_connection(socket),
        )
        .await;
    }
    stats_task.abort();
    Ok(())
}
