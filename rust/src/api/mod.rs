pub mod dto;
pub mod hosts_api;
pub mod host_keys_api;
pub mod ops_api;
pub mod session_api;
pub mod serial_api;
pub mod remote_desktop_api;
pub mod sftp_api;
pub mod vault_api;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // The bridge's starter default enables Trace even in release builds. RDP
    // emits many per-tile traces/spans, so leave diagnostics at warnings/errors
    // instead of formatting and writing them on every frame.
    flutter_rust_bridge::setup_log_to_console(log::LevelFilter::Warn);
    flutter_rust_bridge::setup_backtrace();
    let _ = crate::state::state();
}

#[flutter_rust_bridge::frb(sync)]
pub fn health_check() -> String {
    "termpulse-rust-core-ok".to_string()
}
