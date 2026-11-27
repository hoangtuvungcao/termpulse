//! Desktop Serial bridge; shares normal terminal input, output and close paths.
use crate::api::dto::TerminalEventDto;
use crate::api::session_api::{announce_session, spawn_output_pump};
use crate::frb_generated::StreamSink;
use crate::state::{state, with_vault, ActiveSession};
use core_model::EnvTag;
use core_transport::{connect_serial as open_serial, SerialConfig};
use std::sync::Arc;
use tokio::sync::Mutex as AsyncMutex;

#[derive(Debug, Clone)]
pub struct SerialConfigDto {
    pub port_name: String,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub parity: String,
    pub stop_bits: u8,
    pub flow_control: String,
}

impl From<SerialConfigDto> for SerialConfig {
    fn from(config: SerialConfigDto) -> Self {
        Self {
            port_name: config.port_name,
            baud_rate: config.baud_rate,
            data_bits: config.data_bits,
            parity: config.parity,
            stop_bits: config.stop_bits,
            flow_control: config.flow_control,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SerialPortInfoDto {
    pub port_name: String,
    pub port_type: String,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub serial_number: Option<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn serial_supported() -> bool {
    core_transport::serial_supported()
}

pub fn list_serial_ports() -> Result<Vec<SerialPortInfoDto>, String> {
    core_transport::list_serial_ports()
        .map(|ports| {
            ports
                .into_iter()
                .map(|port| SerialPortInfoDto {
                    port_name: port.port_name,
                    port_type: port.port_type,
                    manufacturer: port.manufacturer,
                    product: port.product,
                    serial_number: port.serial_number,
                })
                .collect()
        })
        .map_err(|error| error.to_string())
}

// Keep setup errors on the terminal stream; FRB discards its setup Future.
pub fn connect_serial(
    config: SerialConfigDto,
    label: Option<String>,
    host_id: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) {
    if let Err(error) = connect_serial_inner(config, label, host_id, sink.clone()) {
        let _ = sink.add_error(error);
    }
}

fn connect_serial_inner(
    config: SerialConfigDto,
    label: Option<String>,
    host_id: Option<String>,
    sink: StreamSink<TerminalEventDto>,
) -> Result<String, String> {
    let env_tag = if let Some(host_id) = host_id.as_deref() {
        with_vault(|store| {
            store
                .get_host(host_id)
                .map_err(|error| error.to_string())?
                .map(|host| host.env_tag)
                .ok_or_else(|| "Không tìm thấy Host Serial".to_string())
        })?
    } else {
        EnvTag::Dev
    };
    let config: SerialConfig = config.into();
    let (input_tx, output_rx) = open_serial(&config).map_err(|error| error.to_string())?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let session = ActiveSession {
        id: session_id.clone(),
        host_id: host_id.clone(),
        title: label
            .filter(|label| !label.trim().is_empty())
            .unwrap_or_else(|| format!("Serial {} · {} baud", config.port_name, config.baud_rate)),
        env_tag,
        cwd: "/".into(),
        input_tx,
        ssh: None,
        sftp: Arc::new(AsyncMutex::new(None)),
        sftp_unavailable_reason: Some("Kết nối Serial không hỗ trợ SFTP.".into()),
        prev_cpu: None,
    };
    state().rt.block_on(async {
        state()
            .sessions
            .lock()
            .await
            .insert(session_id.clone(), session);
    });
    announce_session(&session_id, &sink)?;
    if let Some(host_id) = host_id {
        let _ = with_vault(|store| {
            store
                .mark_host_connected(&host_id)
                .map_err(|error| error.to_string())
        });
    }
    spawn_output_pump(session_id.clone(), output_rx, sink);
    Ok(session_id)
}
