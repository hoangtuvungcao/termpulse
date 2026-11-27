use super::*;
use ironrdp_server::{
    BitmapUpdate, DesktopSize, DisplayUpdate, KeyboardEvent, MouseEvent, RdpServer,
    RdpServerDisplay, RdpServerDisplayUpdates, RdpServerInputHandler,
};
use std::num::{NonZeroU16, NonZeroUsize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

fn config(protocol: &str, port: u16) -> RemoteDesktopConfigDto {
    RemoteDesktopConfigDto {
        protocol: protocol.into(),
        hostname: "127.0.0.1".into(),
        port,
        username: "fixture".into(),
        password: "fixture-password".into(),
        domain: None,
        width: 64,
        height: 64,
        tls_server_name: Some("localhost".into()),
        tls_ca_pem: None,
        tls_certificate_sha256: None,
    }
}

fn channel() -> (Emit, mpsc::UnboundedReceiver<RemoteDesktopEventDto>) {
    let (tx, rx) = mpsc::unbounded_channel();
    (
        Arc::new(move |event| tx.send(event).map_err(|_| "View closed".into())),
        rx,
    )
}

async fn next_frame(
    rx: &mut mpsc::UnboundedReceiver<RemoteDesktopEventDto>,
    matches: impl Fn(&RemoteDesktopEventDto) -> bool,
) -> RemoteDesktopEventDto {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let event = rx.recv().await.expect("event stream closed");
            if event.kind == "frame" && matches(&event) {
                return event;
            }
        }
    })
    .await
    .expect("frame timed out")
}

fn pointer(x: u16, buttons: u8, scroll_y: i16) -> RemoteInput {
    RemoteInput::Pointer {
        x,
        y: x + 1,
        buttons,
        scroll_y,
    }
}

#[test]
fn pointer_motion_uses_latest_position_without_crossing_button_key_or_wheel_edges() {
    let (tx, mut rx) = mpsc::channel(16);
    tx.try_send(pointer(2, 0, 0)).unwrap();
    tx.try_send(pointer(3, 0, 0)).unwrap();
    tx.try_send(pointer(4, 1, 0)).unwrap(); // Press at exactly (4, 5).
    tx.try_send(pointer(5, 1, 0)).unwrap();
    tx.try_send(pointer(6, 1, 0)).unwrap();
    tx.try_send(pointer(7, 0, 0)).unwrap(); // Release at exactly (7, 8).
    tx.try_send(pointer(8, 0, 120)).unwrap();
    tx.try_send(RemoteInput::Key {
        key: 0x1e,
        down: true,
        unicode: false,
    })
    .unwrap();
    let mut pending = None;
    let first = coalesce_pointer_motion(Some(pointer(1, 0, 0)), &mut rx, &mut pending, 0);
    assert!(matches!(first, Some(RemoteInput::Pointer { x: 3, .. })));
    assert!(matches!(
        pending,
        Some(RemoteInput::Pointer {
            x: 4,
            buttons: 1,
            ..
        })
    ));

    let press = coalesce_pointer_motion(pending.take(), &mut rx, &mut pending, 0);
    assert!(matches!(
        press,
        Some(RemoteInput::Pointer {
            x: 4,
            buttons: 1,
            ..
        })
    ));
    assert!(pending.is_none()); // A press must not be moved to the end of a drag.

    let first_drag = rx.try_recv().unwrap();
    let drag = coalesce_pointer_motion(Some(first_drag), &mut rx, &mut pending, 1);
    assert!(matches!(
        drag,
        Some(RemoteInput::Pointer {
            x: 6,
            buttons: 1,
            ..
        })
    ));
    let release = coalesce_pointer_motion(pending.take(), &mut rx, &mut pending, 1);
    assert!(matches!(
        release,
        Some(RemoteInput::Pointer {
            x: 7,
            buttons: 0,
            ..
        })
    ));
    let wheel = rx.try_recv().unwrap();
    let wheel = coalesce_pointer_motion(Some(wheel), &mut rx, &mut pending, 0);
    assert!(matches!(
        wheel,
        Some(RemoteInput::Pointer {
            x: 8,
            scroll_y: 120,
            ..
        })
    ));
    assert!(matches!(
        rx.try_recv(),
        Ok(RemoteInput::Key { key: 0x1e, .. })
    ));
}

#[test]
fn pointer_coalescing_is_bounded_and_preserves_close() {
    let (tx, mut rx) = mpsc::channel(MAX_POINTER_COALESCE + 4);
    for x in 1..=(MAX_POINTER_COALESCE + 1) {
        tx.try_send(pointer(x as u16, 0, 0)).unwrap();
    }
    tx.try_send(RemoteInput::Close).unwrap();
    let mut pending = None;
    let motion = coalesce_pointer_motion(Some(pointer(0, 0, 0)), &mut rx, &mut pending, 0);
    assert!(
        matches!(motion, Some(RemoteInput::Pointer { x, .. }) if usize::from(x) == MAX_POINTER_COALESCE)
    );
    assert!(pending.is_none());
    let remaining = rx.try_recv().unwrap();
    let motion = coalesce_pointer_motion(Some(remaining), &mut rx, &mut pending, 0);
    assert!(
        matches!(motion, Some(RemoteInput::Pointer { x, .. }) if usize::from(x) == MAX_POINTER_COALESCE + 1)
    );
    assert!(matches!(pending, Some(RemoteInput::Close)));
}

#[tokio::test(start_paused = true)]
async fn desktop_frame_clock_skips_overdue_render_slots() {
    let mut clock = desktop_frame_clock();
    clock.tick().await;
    tokio::time::advance(Duration::from_millis(225)).await;
    clock.tick().await; // A single current frame may be emitted immediately.
    assert!(tokio::time::timeout(Duration::from_millis(1), clock.tick())
        .await
        .is_err()); // No catch-up burst for the missed 100/150/200 ms slots.
    tokio::time::advance(Duration::from_millis(24)).await;
    clock.tick().await;
}

#[test]
fn rdp_mobile_performance_flags_retain_readable_text_and_skip_decoration() {
    let flags = connector_config(&config("rdp", 3389)).performance_flags;
    assert!(flags.contains(PerformanceFlags::DISABLE_WALLPAPER));
    assert!(flags.contains(PerformanceFlags::DISABLE_CURSOR_SHADOW));
    assert!(flags.contains(PerformanceFlags::DISABLE_FULLWINDOWDRAG));
    assert!(flags.contains(PerformanceFlags::DISABLE_MENUANIMATIONS));
    assert!(flags.contains(PerformanceFlags::ENABLE_FONT_SMOOTHING));
}

#[test]
fn framebuffer_rejects_bounds_and_copies_overlapping_pixels() {
    let mut frame = Framebuffer::default();
    frame.resize(3, 1).unwrap();
    frame
        .draw(
            Rect {
                x: 0,
                y: 0,
                width: 3,
                height: 1,
            },
            &[1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0],
        )
        .unwrap();
    frame
        .copy(
            Rect {
                x: 1,
                y: 0,
                width: 2,
                height: 1,
            },
            Rect {
                x: 0,
                y: 0,
                width: 2,
                height: 1,
            },
        )
        .unwrap();
    assert_eq!(frame.rgba, [1, 2, 3, 0, 1, 2, 3, 0, 4, 5, 6, 0]);
    assert!(frame
        .draw(
            Rect {
                x: 3,
                y: 0,
                width: 1,
                height: 1
            },
            &[0; 4]
        )
        .is_err());
    assert!(frame
        .draw(
            Rect {
                x: 0,
                y: 0,
                width: 1,
                height: 1
            },
            &[0; 3]
        )
        .is_err());
    assert!(dimensions(0, 1).is_err());
    assert!(dimensions(8192, 8192).is_err());
    assert_eq!(vnc_keysym('ệ' as u32, true), 0x0100_1ec7);
    assert!(normalized_pin("123").is_err());
    assert_eq!(normalized_pin(&"AB:".repeat(32)).unwrap(), "ab".repeat(32));
}

#[test]
fn session_cancellation_bypasses_full_input_queue_and_vault_clear_cancels_all() {
    let id = uuid::Uuid::new_v4().to_string();
    let (input, mut queued) = mpsc::channel(1);
    let (cancel, mut cancelled) = oneshot::channel();
    input
        .try_send(RemoteInput::Text("queued input".into()))
        .unwrap();
    SESSIONS
        .lock()
        .unwrap()
        .insert(id.clone(), SessionHandle { input, cancel });
    close_remote_desktop(id.clone()).unwrap();
    cancelled.try_recv().unwrap();
    assert!(queued.try_recv().is_ok());
    close_remote_desktop(id).unwrap();

    let mut cancelled = Vec::new();
    for _ in 0..2 {
        let (input, _queued) = mpsc::channel(1);
        let (cancel, receiver) = oneshot::channel();
        SESSIONS.lock().unwrap().insert(
            uuid::Uuid::new_v4().to_string(),
            SessionHandle { input, cancel },
        );
        cancelled.push(receiver);
    }
    close_all_remote_desktop_sessions().unwrap();
    assert!(SESSIONS.lock().unwrap().is_empty());
    for mut receiver in cancelled {
        receiver.try_recv().unwrap();
    }
}

#[test]
fn saved_options_default_and_reject_embedded_credentials() {
    let options: SavedOptions = serde_json::from_str("{}").unwrap();
    assert_eq!((options.width, options.height), (1280, 720));
    assert!(serde_json::from_str::<SavedOptions>(r#"{"password":"must-use-vault"}"#).is_err());
    assert!(
        serde_json::from_str::<SavedOptions>(r#"{"skip_certificate_verification":true}"#).is_err()
    );
}

#[tokio::test]
async fn vnc_tcp_fixture_decodes_rgba_sends_unicode_pointer_and_closes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (observed, mut observations) = mpsc::unbounded_channel();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        socket.write_all(b"RFB 003.008\n").await.unwrap();
        let mut version = [0; 12];
        socket.read_exact(&mut version).await.unwrap();
        assert_eq!(&version, b"RFB 003.008\n");
        socket.write_all(&[1, 1]).await.unwrap();
        assert_eq!(socket.read_u8().await.unwrap(), 1);
        socket.write_u32(0).await.unwrap();
        assert_eq!(socket.read_u8().await.unwrap(), 1);
        socket.write_u16(2).await.unwrap();
        socket.write_u16(1).await.unwrap();
        socket
            .write_all(&[32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            .await
            .unwrap();
        socket.write_u32(7).await.unwrap();
        socket.write_all(b"fixture").await.unwrap();
        let mut sent_frame = false;
        loop {
            let kind = match socket.read_u8().await {
                Ok(kind) => kind,
                Err(_) => break,
            };
            match kind {
                0 => {
                    let mut rest = [0; 19];
                    socket.read_exact(&mut rest).await.unwrap();
                    assert_eq!(rest[13], 0);
                }
                2 => {
                    socket.read_u8().await.unwrap();
                    let count = socket.read_u16().await.unwrap();
                    let mut enc = vec![0; count as usize * 4];
                    socket.read_exact(&mut enc).await.unwrap();
                }
                3 => {
                    let mut request = [0; 9];
                    socket.read_exact(&mut request).await.unwrap();
                    if !sent_frame {
                        socket.write_all(&[0, 0, 0, 1]).await.unwrap(); // framebuffer update, one rectangle
                        for value in [0u16, 0, 2, 1] {
                            socket.write_u16(value).await.unwrap();
                        }
                        socket.write_i32(0).await.unwrap();
                        socket
                            .write_all(&[11, 22, 33, 0, 44, 55, 66, 0])
                            .await
                            .unwrap();
                        sent_frame = true;
                    }
                }
                4 => {
                    let down = socket.read_u8().await.unwrap();
                    socket.read_u16().await.unwrap();
                    let key = socket.read_u32().await.unwrap();
                    observed.send(format!("key:{key}:{down}")).unwrap();
                }
                5 => {
                    let buttons = socket.read_u8().await.unwrap();
                    let x = socket.read_u16().await.unwrap();
                    let y = socket.read_u16().await.unwrap();
                    observed.send(format!("pointer:{x}:{y}:{buttons}")).unwrap();
                }
                6 => {
                    let mut pad = [0; 3];
                    socket.read_exact(&mut pad).await.unwrap();
                    let length = socket.read_u32().await.unwrap();
                    let mut text = vec![0; length as usize];
                    socket.read_exact(&mut text).await.unwrap();
                    assert_eq!(text, b"caf\xe9");
                    socket
                        .write_all(&[3, 0, 0, 0, 0, 0, 0, 4, b'c', b'a', b'f', 0xe9])
                        .await
                        .unwrap();
                    observed.send("clipboard:café".into()).unwrap();
                }
                _ => panic!("unexpected client message {kind}"),
            }
        }
        observed.send("closed".into()).unwrap();
    });
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(16);
    let client =
        tokio::spawn(async move { run_vnc(config("vnc", port), "fixture", rx, emit).await });
    let frame = next_frame(&mut events, |frame| frame.rgba.first() == Some(&11)).await;
    assert_eq!((frame.width, frame.height), (2, 1));
    assert_eq!(frame.rgba, [11, 22, 33, 255, 44, 55, 66, 255]);
    tx.send(RemoteInput::Key {
        key: 'ệ' as u32,
        down: true,
        unicode: true,
    })
    .await
    .unwrap();
    tx.send(RemoteInput::Pointer {
        x: 1,
        y: 0,
        buttons: 1,
        scroll_y: 0,
    })
    .await
    .unwrap();
    tx.send(RemoteInput::Clipboard("café".into()))
        .await
        .unwrap();
    let seen = tokio::time::timeout(Duration::from_secs(2), async {
        let mut seen = Vec::new();
        while seen.len() < 3 {
            seen.push(observations.recv().await.unwrap());
        }
        seen
    })
    .await
    .unwrap();
    assert!(seen.contains(&format!("key:{}:1", 0x0100_1ec7u32)));
    assert!(seen.contains(&"pointer:1:0:1".into()));
    assert!(seen.contains(&"clipboard:café".into()));
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.kind == "clipboard" {
                assert_eq!(event.message.as_deref(), Some("café"));
                break;
            }
        }
    })
    .await
    .unwrap();
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(observations.recv().await.as_deref(), Some("closed"));
}

#[tokio::test]
async fn vnc_handshake_cancels_before_server_greeting() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut byte = [0];
        assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
    });
    let (emit, _events) = channel();
    let (tx, rx) = mpsc::channel(2);
    let client =
        tokio::spawn(async move { run_vnc(config("vnc", port), "cancel", rx, emit).await });
    tokio::time::sleep(Duration::from_millis(30)).await;
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn handshake_deadline_closes_a_server_that_never_greets() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (emit, _events) = channel();
    let (_tx, rx) = mpsc::channel(2);
    let client =
        tokio::spawn(async move { run_vnc(config("vnc", port), "timeout", rx, emit).await });
    let (mut socket, _) = listener.accept().await.unwrap();
    tokio::time::pause();
    tokio::time::advance(HANDSHAKE_TIMEOUT + Duration::from_secs(1)).await;
    let error = client.await.unwrap().unwrap_err();
    assert!(error.starts_with("REMOTE_DESKTOP_TIMEOUT:"), "{error}");
    tokio::time::resume();
    assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn rdp_handshake_cancels_during_negotiation() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (emit, _events) = channel();
    let (tx, rx) = mpsc::channel(2);
    let client =
        tokio::spawn(async move { run_rdp(config("rdp", port), "cancel", rx, emit).await });
    let (mut socket, _) = listener.accept().await.unwrap();
    assert!(socket.read(&mut [0; 256]).await.unwrap() > 0);
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn vnc_rejects_failed_authentication_without_client_init() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        socket.write_all(b"RFB 003.008\n").await.unwrap();
        let mut version = [0; 12];
        socket.read_exact(&mut version).await.unwrap();
        socket.write_all(&[1, 2]).await.unwrap();
        assert_eq!(socket.read_u8().await.unwrap(), 2);
        socket.write_all(&[42; 16]).await.unwrap();
        let mut response = [0; 16];
        socket.read_exact(&mut response).await.unwrap();
        socket.write_u32(1).await.unwrap();
        socket.write_u32(6).await.unwrap();
        socket.write_all(b"denied").await.unwrap();
        let mut trailing = Vec::new();
        socket.read_to_end(&mut trailing).await.unwrap();
        assert!(trailing.is_empty());
    });
    let (emit, _events) = channel();
    let (_tx, rx) = mpsc::channel(2);
    let error = run_vnc(config("vnc", port), "bad-password", rx, emit)
        .await
        .unwrap_err();
    assert!(error.starts_with("VNC_AUTHENTICATION:"));
    server.await.unwrap();
}

#[derive(Clone)]
struct RdpFixture {
    input: mpsc::UnboundedSender<String>,
    frames: Option<usize>,
    animate: bool,
    initial_graphics: Option<Arc<tokio::sync::Notify>>,
}
impl RdpServerInputHandler for RdpFixture {
    fn keyboard(&mut self, event: KeyboardEvent) {
        let _ = self.input.send(format!("keyboard:{event:?}"));
    }
    fn mouse(&mut self, event: MouseEvent) {
        let _ = self.input.send(format!("mouse:{event:?}"));
    }
}
struct RdpUpdates {
    remaining: Option<usize>,
    animate: bool,
    sequence: u8,
    initial_graphics: Option<Arc<tokio::sync::Notify>>,
}
#[async_trait::async_trait]
impl RdpServerDisplayUpdates for RdpUpdates {
    async fn next_update(&mut self) -> anyhow::Result<Option<DisplayUpdate>> {
        if let Some(gate) = self.initial_graphics.take() {
            gate.notified().await;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        if let Some(remaining) = self.remaining.as_mut() {
            if *remaining == 0 {
                return Ok(None);
            }
            *remaining -= 1;
        }
        self.sequence = self.sequence.wrapping_add(1);
        let blue = if self.animate {
            self.sequence.wrapping_mul(31)
        } else {
            11
        };
        Ok(Some(DisplayUpdate::Bitmap(BitmapUpdate {
            x: 0,
            y: 0,
            width: NonZeroU16::new(64).unwrap(),
            height: NonZeroU16::new(64).unwrap(),
            format: PixelFormat::BgrA32,
            data: [blue, 22, 33, 255].repeat(64 * 64).into(),
            stride: NonZeroUsize::new(64 * 4).unwrap(),
        })))
    }
}
#[async_trait::async_trait]
impl RdpServerDisplay for RdpFixture {
    async fn size(&mut self) -> DesktopSize {
        DesktopSize {
            width: 64,
            height: 64,
        }
    }
    async fn updates(&mut self) -> anyhow::Result<Box<dyn RdpServerDisplayUpdates>> {
        Ok(Box::new(RdpUpdates {
            remaining: self.frames,
            animate: self.animate,
            sequence: 0,
            initial_graphics: self.initial_graphics.clone(),
        }))
    }
}

async fn rdp_fixture(
    hybrid: bool,
) -> (
    u16,
    String,
    mpsc::UnboundedReceiver<String>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    rdp_fixture_with_frames(hybrid, None).await
}

async fn rdp_fixture_with_frames(
    hybrid: bool,
    frames: Option<usize>,
) -> (
    u16,
    String,
    mpsc::UnboundedReceiver<String>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    rdp_fixture_with_animation(hybrid, frames, false).await
}

async fn rdp_fixture_with_animation(
    hybrid: bool,
    frames: Option<usize>,
    animate: bool,
) -> (
    u16,
    String,
    mpsc::UnboundedReceiver<String>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    rdp_fixture_with_graphics_gate(hybrid, frames, animate, None).await
}

async fn rdp_fixture_with_graphics_gate(
    hybrid: bool,
    frames: Option<usize>,
    animate: bool,
    initial_graphics: Option<Arc<tokio::sync::Notify>>,
) -> (
    u16,
    String,
    mpsc::UnboundedReceiver<String>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let der = cert.cert.der().clone();
    let pin = fingerprint(der.as_ref());
    let parsed = x509_cert::Certificate::from_der(der.as_ref()).unwrap();
    let public_key = parsed
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .unwrap()
        .to_vec();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der());
    let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![der], key.into())
    .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (input, rx) = mpsc::unbounded_channel();
    let listener = listener.into_std().unwrap();
    // The upstream server intentionally uses local futures/Rc. Keep it on a
    // dedicated current-thread runtime rather than imposing Send on its API.
    let task = tokio::task::spawn_blocking(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async move {
                let listener = TcpListener::from_std(listener)?;
                let handler = RdpFixture {
                    input,
                    frames,
                    animate,
                    initial_graphics,
                };
                let builder = RdpServer::builder().with_addr(listener.local_addr()?);
                let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(tls));
                let builder = if hybrid {
                    builder.with_hybrid(acceptor, public_key)
                } else {
                    builder.with_tls(acceptor)
                };
                let mut server = builder
                    .with_input_handler(handler.clone())
                    .with_display_handler(handler)
                    .build();
                server.set_credentials(Some(ironrdp_server::Credentials {
                    username: "fixture".into(),
                    password: "fixture-password".into(),
                    domain: None,
                }));
                let (socket, _) = listener.accept().await?;
                tokio::time::timeout(Duration::from_secs(15), server.run_connection(socket)).await?
            })
    });
    (port, pin, rx, task)
}

#[tokio::test]
async fn rdp_waits_for_server_graphics_before_emitting_a_frame() {
    let graphics = Arc::new(tokio::sync::Notify::new());
    let (port, pin, _inputs, server) =
        rdp_fixture_with_graphics_gate(false, None, false, Some(graphics.clone())).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(16);
    let client = tokio::spawn(async move { run_rdp(cfg, "initial-graphics", rx, emit).await });
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let event = events.recv().await.expect("event stream closed");
            assert_ne!(event.kind, "frame", "frame arrived before connected");
            if event.kind == "connected" {
                break;
            }
        }
    })
    .await
    .unwrap();

    // Hold graphics across three render slots: the zero-filled native buffer
    // must not masquerade as the server's first desktop image.
    let premature_frame = tokio::time::timeout(Duration::from_millis(175), async {
        loop {
            let event = events.recv().await.expect("event stream closed");
            if event.kind == "frame" {
                return event;
            }
        }
    })
    .await;
    graphics.notify_one();
    assert!(premature_frame.is_err(), "placeholder frame emitted");
    let frame = next_frame(&mut events, |_| true).await;
    assert_eq!((frame.width, frame.height), (64, 64));
    assert!(frame.rgba[0].abs_diff(33) <= 3);
    assert!(frame.rgba[1].abs_diff(22) <= 3);
    assert!(frame.rgba[2].abs_diff(11) <= 3);
    assert_eq!(frame.rgba[3], 255);

    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_tls_fixture_decodes_frames_sends_input_and_disconnects() {
    let (port, pin, mut observations, server) = rdp_fixture(false).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(16);
    let client = tokio::spawn(async move { run_rdp(cfg, "rdp", rx, emit).await });
    let frame = next_frame(&mut events, |frame| {
        frame.rgba.first().is_some_and(|red| *red > 0)
    })
    .await;
    assert_eq!((frame.width, frame.height), (64, 64));
    // RemoteFX is lossy; the three decoded channels must still match the source
    // color within its quantization error and must be reordered to RGBA.
    for (actual, expected) in frame.rgba[..3].iter().zip([33u8, 22, 11]) {
        assert!(actual.abs_diff(expected) <= 3);
    }
    assert_eq!(frame.rgba[3], 255);
    tx.send(RemoteInput::Key {
        key: 0x1e,
        down: true,
        unicode: false,
    })
    .await
    .unwrap();
    tx.send(RemoteInput::Key {
        key: 'ệ' as u32,
        down: true,
        unicode: true,
    })
    .await
    .unwrap();
    tx.send(RemoteInput::Pointer {
        x: 12,
        y: 13,
        buttons: 1,
        scroll_y: 0,
    })
    .await
    .unwrap();
    let seen = tokio::time::timeout(Duration::from_secs(3), async {
        let mut seen = Vec::new();
        loop {
            seen.push(observations.recv().await.unwrap());
            if seen.iter().any(|s| s.contains("UnicodePressed(7879)"))
                && seen.iter().any(|s| s.contains("LeftPressed"))
            {
                break seen;
            }
        }
    })
    .await
    .unwrap();
    assert!(seen.iter().any(|s| s.contains("Pressed { code: 30")));
    assert!(seen.iter().any(|s| s.contains("Move { x: 12, y: 13 }")));
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_motion_burst_reaches_latest_position_and_preserves_drag_edges_on_wire() {
    let (port, pin, mut observations, server) = rdp_fixture(false).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(128);
    let client = tokio::spawn(async move { run_rdp(cfg, "motion-burst", rx, emit).await });
    next_frame(&mut events, |frame| {
        frame.rgba.first().is_some_and(|red| *red > 0)
    })
    .await;

    // Queue synchronously to model a delayed native worker receiving a burst
    // from Flutter. Intermediate hover/drag positions need not be replayed.
    for x in 0..=60 {
        tx.try_send(pointer(x, 0, 0)).unwrap();
    }
    tx.try_send(pointer(10, 1, 0)).unwrap();
    for x in 11..=59 {
        tx.try_send(pointer(x, 1, 0)).unwrap();
    }
    tx.try_send(pointer(60, 0, 0)).unwrap();
    tx.try_send(RemoteInput::Key {
        key: 0x1e,
        down: true,
        unicode: false,
    })
    .unwrap();
    let seen = tokio::time::timeout(Duration::from_secs(3), async {
        let mut seen = Vec::new();
        loop {
            let event = observations.recv().await.unwrap();
            let final_key = event.contains("Pressed { code: 30");
            seen.push(event);
            if final_key {
                break seen;
            }
        }
    })
    .await
    .unwrap();
    let moves: Vec<_> = seen
        .iter()
        .filter(|event| event.contains("mouse:Move"))
        .collect();
    assert_eq!(
        moves,
        [
            "mouse:Move { x: 60, y: 61 }",
            "mouse:Move { x: 10, y: 11 }",
            "mouse:Move { x: 59, y: 60 }",
            "mouse:Move { x: 60, y: 61 }",
        ]
    );
    let press = seen
        .iter()
        .position(|event| event.contains("LeftPressed"))
        .unwrap();
    let release = seen
        .iter()
        .position(|event| event.contains("LeftReleased"))
        .unwrap();
    assert!(seen[press - 1].contains("Move { x: 10, y: 11 }"));
    assert!(seen[release - 1].contains("Move { x: 60, y: 61 }"));
    assert!(press < release && release < seen.len() - 1);

    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_delivers_continuous_changing_frames_while_accepting_input() {
    let (port, pin, mut observations, server) = rdp_fixture_with_animation(false, None, true).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(16);
    let client = tokio::spawn(async move { run_rdp(cfg, "animation", rx, emit).await });
    let first = next_frame(&mut events, |frame| {
        frame.rgba.first().is_some_and(|red| *red > 0)
    })
    .await;
    tx.send(RemoteInput::Key {
        key: 0x1e,
        down: true,
        unicode: false,
    })
    .await
    .unwrap();
    let mut latest_blue = first.rgba[2];
    for _ in 0..5 {
        let frame = next_frame(&mut events, |frame| {
            frame.rgba.len() == 64 * 64 * 4 && frame.rgba[2].abs_diff(latest_blue) > 10
        })
        .await;
        assert!(frame.rgba.chunks_exact(4).all(|pixel| pixel[3] == 255));
        latest_blue = frame.rgba[2];
    }
    let key = tokio::time::timeout(Duration::from_secs(3), observations.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(key.contains("Pressed { code: 30"), "{key}");
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_requires_trusted_certificate_and_probe_does_not_authenticate() {
    let (port, expected, _inputs, server) = rdp_fixture(false).await;
    let cfg = config("rdp", port);
    let error = begin_rdp_tls(&cfg, false, Arc::new(Mutex::new(None)))
        .await
        .err()
        .expect("self-signed certificate was accepted");
    assert!(error.starts_with("RDP_CERTIFICATE_UNTRUSTED:"), "{error}");
    let _ = server.await;

    let (port, actual, mut inputs, server) = rdp_fixture(false).await;
    let captured = Arc::new(Mutex::new(None));
    let connection = begin_rdp_tls(&config("rdp", port), true, captured.clone())
        .await
        .unwrap();
    assert_eq!(captured.lock().unwrap().as_deref(), Some(actual.as_str()));
    assert_ne!(expected, actual); // Each fixture gets a fresh key/certificate.
    drop(connection);
    let _ = tokio::time::timeout(Duration::from_secs(2), server)
        .await
        .unwrap();
    assert!(inputs.try_recv().is_err());
}

#[tokio::test]
async fn rdp_nla_credssp_fixture_authenticates_and_renders() {
    let (port, pin, _inputs, server) = rdp_fixture(true).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (tx, rx) = mpsc::channel(16);
    let client = tokio::spawn(async move { run_rdp(cfg, "nla", rx, emit).await });
    let frame = next_frame(&mut events, |frame| {
        frame.rgba.first().is_some_and(|red| *red > 0)
    })
    .await;
    assert_eq!(frame.rgba.len(), 64 * 64 * 4);
    tx.send(RemoteInput::Close).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_nla_fixture_rejects_incorrect_password_before_connected() {
    let (port, pin, _inputs, server) = rdp_fixture(true).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    cfg.password = "incorrect-password".into();
    let (emit, mut events) = channel();
    let (_tx, rx) = mpsc::channel(2);
    let error = run_rdp(cfg, "wrong-password", rx, emit).await.unwrap_err();
    assert!(error.starts_with("RDP_AUTHENTICATION:"), "{error}");
    while let Ok(event) = events.try_recv() {
        assert_ne!(event.kind, "connected");
    }
    let _ = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .unwrap();
}

#[tokio::test]
async fn rdp_peer_shutdown_ends_the_client_without_waiting_for_input() {
    let (port, pin, _inputs, server) = rdp_fixture_with_frames(false, Some(3)).await;
    let mut cfg = config("rdp", port);
    cfg.tls_certificate_sha256 = Some(pin);
    let (emit, mut events) = channel();
    let (_tx, rx) = mpsc::channel(2);
    let client = tokio::spawn(async move { run_rdp(cfg, "peer-close", rx, emit).await });
    next_frame(&mut events, |frame| {
        frame.rgba.first().is_some_and(|red| *red > 0)
    })
    .await;
    let error = tokio::time::timeout(Duration::from_secs(3), client)
        .await
        .unwrap()
        .unwrap()
        .unwrap_err();
    assert!(error.starts_with("RDP_CONNECTION:"), "{error}");
    server.await.unwrap().unwrap();
}
