//! Native desktop serial I/O. Linux tests use OS PTYs rather than USB hardware.
use crate::{SessionInput, SessionOutput, TransportError};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub const SERIAL_UNSUPPORTED_REASON: &str =
    "Serial chỉ hỗ trợ Linux, Windows và macOS. USB Serial trên Android/iOS chưa được triển khai.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SerialConfig {
    pub port_name: String,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub parity: String,
    pub stop_bits: u8,
    pub flow_control: String,
}

impl Default for SerialConfig {
    fn default() -> Self {
        Self {
            port_name: String::new(),
            baud_rate: 115_200,
            data_bits: 8,
            parity: "none".into(),
            stop_bits: 1,
            flow_control: "none".into(),
        }
    }
}

impl SerialConfig {
    pub fn validate(&self) -> Result<(), TransportError> {
        let invalid = |message: &str| TransportError::Connect(message.to_string());
        if self.port_name.trim().is_empty() || self.port_name.chars().any(char::is_control) {
            return Err(invalid(
                "Hãy nhập tên cổng Serial hợp lệ, ví dụ /dev/ttyUSB0 hoặc COM3.",
            ));
        }
        if !(1..=4_000_000).contains(&self.baud_rate) {
            return Err(invalid("Baud rate phải nằm trong khoảng 1–4000000."));
        }
        if !(5..=8).contains(&self.data_bits) {
            return Err(invalid("Serial data bits phải là 5, 6, 7 hoặc 8."));
        }
        if !matches!(self.parity.as_str(), "none" | "odd" | "even") {
            return Err(invalid("Serial parity phải là none, odd hoặc even."));
        }
        if !matches!(self.stop_bits, 1 | 2) {
            return Err(invalid("Serial stop bits phải là 1 hoặc 2."));
        }
        if !matches!(self.flow_control.as_str(), "none" | "software" | "hardware") {
            return Err(invalid(
                "Serial flow control phải là none, software hoặc hardware.",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SerialPortInfo {
    pub port_name: String,
    pub port_type: String,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub serial_number: Option<String>,
}

pub fn serial_supported() -> bool {
    cfg!(any(
        target_os = "linux",
        target_os = "windows",
        target_os = "macos"
    ))
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
pub fn list_serial_ports() -> Result<Vec<SerialPortInfo>, TransportError> {
    let ports = serialport::available_ports().map_err(|error| {
        TransportError::Connect(format!("Không đọc được danh sách cổng Serial: {error}"))
    })?;
    let mut ports = ports
        .into_iter()
        .map(|port| {
            let (kind, manufacturer, product, serial_number) = match port.port_type {
                serialport::SerialPortType::UsbPort(usb) => {
                    ("usb", usb.manufacturer, usb.product, usb.serial_number)
                }
                serialport::SerialPortType::PciPort => ("pci", None, None, None),
                serialport::SerialPortType::BluetoothPort => ("bluetooth", None, None, None),
                serialport::SerialPortType::Unknown => ("unknown", None, None, None),
            };
            SerialPortInfo {
                port_name: port.port_name,
                port_type: kind.into(),
                manufacturer,
                product,
                serial_number,
            }
        })
        .collect::<Vec<_>>();
    ports.sort_by(|left, right| left.port_name.cmp(&right.port_name));
    ports.dedup_by(|left, right| left.port_name == right.port_name);
    Ok(ports)
}

#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
pub fn list_serial_ports() -> Result<Vec<SerialPortInfo>, TransportError> {
    Err(TransportError::Connect(SERIAL_UNSUPPORTED_REASON.into()))
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
fn open_port(config: &SerialConfig) -> Result<Box<dyn serialport::SerialPort>, TransportError> {
    config.validate()?;
    let data_bits = match config.data_bits {
        5 => serialport::DataBits::Five,
        6 => serialport::DataBits::Six,
        7 => serialport::DataBits::Seven,
        _ => serialport::DataBits::Eight,
    };
    let parity = match config.parity.as_str() {
        "odd" => serialport::Parity::Odd,
        "even" => serialport::Parity::Even,
        _ => serialport::Parity::None,
    };
    let flow_control = match config.flow_control.as_str() {
        "software" => serialport::FlowControl::Software,
        "hardware" => serialport::FlowControl::Hardware,
        _ => serialport::FlowControl::None,
    };
    serialport::new(&config.port_name, config.baud_rate)
        .data_bits(data_bits)
        .parity(parity)
        .stop_bits(if config.stop_bits == 2 { serialport::StopBits::Two } else { serialport::StopBits::One })
        .flow_control(flow_control)
        // Bounded reads let one worker process Close even when a device is idle.
        .timeout(std::time::Duration::from_millis(40))
        .open()
        .map_err(|error| TransportError::Connect(format!(
            "Không mở được cổng Serial {}: {error}. Kiểm tra thiết bị, quyền truy cập và cổng có đang được ứng dụng khác dùng hay không.",
            config.port_name,
        )))
}

/// Opens a real native device; no local echo or synthetic terminal output.
/// Serial devices have no PTY geometry, so Resize is intentionally ignored.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos"))]
pub fn connect_serial(
    config: &SerialConfig,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    use std::collections::VecDeque;
    use std::io::ErrorKind;
    let mut port = open_port(config)?;
    let port_name = config.port_name.clone();
    let (input_tx, mut input_rx) = mpsc::channel(128);
    let (output_tx, output_rx) = mpsc::channel(128);
    std::thread::Builder::new()
        .name("termpulse-serial".into())
        .spawn(move || {
            let mut pending = VecDeque::<Vec<u8>>::new();
            let mut offset = 0;
            let mut buffer = [0_u8; 8192];
            let reason = 'session: loop {
                // Check controls between every bounded read/write, including
                // when hardware flow control temporarily stops transmission.
                for _ in 0..128 {
                    match input_rx.try_recv() {
                        Ok(SessionInput::Bytes(bytes)) if !bytes.is_empty() => {
                            pending.push_back(bytes)
                        }
                        Ok(SessionInput::Bytes(_)) | Ok(SessionInput::Resize { .. }) => {}
                        Ok(SessionInput::Close) | Err(mpsc::error::TryRecvError::Disconnected) => {
                            break 'session None
                        }
                        Err(mpsc::error::TryRecvError::Empty) => break,
                    }
                }
                if let Some(bytes) = pending.front() {
                    let end = (offset + 4096).min(bytes.len());
                    match port.write(&bytes[offset..end]) {
                        Ok(0) => {
                            break Some(format!("Cổng Serial {port_name} không nhận thêm dữ liệu."))
                        }
                        Ok(written) => {
                            offset += written;
                            if offset == bytes.len() {
                                pending.pop_front();
                                offset = 0;
                            }
                        }
                        Err(error)
                            if matches!(
                                error.kind(),
                                ErrorKind::TimedOut
                                    | ErrorKind::WouldBlock
                                    | ErrorKind::Interrupted
                            ) => {}
                        Err(error) => {
                            break Some(format!("Ghi Serial {port_name} thất bại: {error}"))
                        }
                    }
                }
                match port.read(&mut buffer) {
                    Ok(0) => break Some(format!("Thiết bị Serial {port_name} đã ngắt kết nối.")),
                    Ok(count) => {
                        if output_tx
                            .blocking_send(SessionOutput::Data(buffer[..count].to_vec()))
                            .is_err()
                        {
                            break None;
                        }
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            ErrorKind::TimedOut | ErrorKind::WouldBlock | ErrorKind::Interrupted
                        ) => {}
                    Err(error) => break Some(format!("Đọc Serial {port_name} thất bại: {error}")),
                }
            };
            // Drop the native handle before announcing closure so reconnect can
            // immediately acquire the same exclusive port.
            drop(port);
            let _ = output_tx.blocking_send(SessionOutput::Closed(reason));
        })?;
    Ok((input_tx, output_rx))
}

#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
pub fn connect_serial(
    _config: &SerialConfig,
) -> Result<(mpsc::Sender<SessionInput>, mpsc::Receiver<SessionOutput>), TransportError> {
    Err(TransportError::Connect(SERIAL_UNSUPPORTED_REASON.into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serial_settings_reject_invalid_values_before_opening() {
        let config = SerialConfig {
            port_name: "/dev/not-opened".into(),
            ..Default::default()
        };
        assert!(config.validate().is_ok());
        for invalid in [
            SerialConfig {
                port_name: " ".into(),
                ..config.clone()
            },
            SerialConfig {
                port_name: "COM3\n".into(),
                ..config.clone()
            },
            SerialConfig {
                baud_rate: 0,
                ..config.clone()
            },
            SerialConfig {
                baud_rate: 4_000_001,
                ..config.clone()
            },
            SerialConfig {
                data_bits: 9,
                ..config.clone()
            },
            SerialConfig {
                parity: "mark".into(),
                ..config.clone()
            },
            SerialConfig {
                stop_bits: 3,
                ..config.clone()
            },
            SerialConfig {
                flow_control: "fake".into(),
                ..config.clone()
            },
        ] {
            assert!(invalid.validate().is_err(), "{invalid:?}");
        }
    }

    #[cfg(target_os = "linux")]
    mod linux_pty {
        use super::*;
        use serialport::SerialPort;
        use std::io::{Read, Write};
        use std::time::Duration;

        fn pair() -> (serialport::TTYPort, SerialConfig) {
            let (mut master, slave) = serialport::TTYPort::pair().unwrap();
            master.set_timeout(Duration::from_secs(2)).unwrap();
            let config = SerialConfig {
                port_name: slave.name().unwrap(),
                ..Default::default()
            };
            drop(slave);
            (master, config)
        }

        async fn data(rx: &mut mpsc::Receiver<SessionOutput>, expected: &[u8]) {
            let mut bytes = Vec::new();
            tokio::time::timeout(Duration::from_secs(3), async {
                while bytes.len() < expected.len() {
                    match rx.recv().await {
                        Some(SessionOutput::Data(chunk)) => bytes.extend(chunk),
                        other => panic!("Serial ended before expected data: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            assert_eq!(bytes, expected);
        }

        #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn serial_pty_read_write_close_and_reconnect() {
            let (mut master, config) = pair();
            let (tx, mut rx) = connect_serial(&config).unwrap();
            master.write_all(b"device -> terminal\r\n").unwrap();
            data(&mut rx, b"device -> terminal\r\n").await;
            tx.send(SessionInput::Resize { cols: 20, rows: 3 })
                .await
                .unwrap();
            tx.send(SessionInput::Bytes(b"terminal -> device\r\n".to_vec()))
                .await
                .unwrap();
            let mut bytes = vec![0; b"terminal -> device\r\n".len()];
            master.read_exact(&mut bytes).unwrap();
            assert_eq!(bytes, b"terminal -> device\r\n");
            tx.send(SessionInput::Close).await.unwrap();
            assert!(matches!(
                tokio::time::timeout(Duration::from_secs(2), rx.recv())
                    .await
                    .unwrap(),
                Some(SessionOutput::Closed(None))
            ));
            let (tx, mut rx) = connect_serial(&config).unwrap();
            master.write_all(b"same port reconnected").unwrap();
            data(&mut rx, b"same port reconnected").await;
            tx.send(SessionInput::Close).await.unwrap();
            assert!(matches!(rx.recv().await, Some(SessionOutput::Closed(None))));
        }

        #[tokio::test]
        async fn serial_pty_reports_device_disconnect() {
            let (master, config) = pair();
            let (_tx, mut rx) = connect_serial(&config).unwrap();
            drop(master);
            let closed = tokio::time::timeout(Duration::from_secs(2), rx.recv())
                .await
                .unwrap();
            assert!(matches!(closed, Some(SessionOutput::Closed(Some(_)))));
        }

        #[test]
        fn serial_pty_applies_requested_baud_and_frame_settings() {
            let (_master, mut config) = pair();
            config.baud_rate = 9_600;
            config.stop_bits = 2;
            config.flow_control = "software".into();
            let port = open_port(&config).unwrap();
            assert_eq!(port.baud_rate().unwrap(), 9_600);
            assert_eq!(port.data_bits().unwrap(), serialport::DataBits::Eight);
            assert_eq!(port.parity().unwrap(), serialport::Parity::None);
            assert_eq!(port.stop_bits().unwrap(), serialport::StopBits::Two);
            assert_eq!(
                port.flow_control().unwrap(),
                serialport::FlowControl::Software
            );
        }

        #[test]
        fn serial_missing_port_fails_instead_of_creating_a_fake_session() {
            let config = SerialConfig {
                port_name: "/dev/termpulse_missing_serial_fixture".into(),
                ..Default::default()
            };
            let error = match connect_serial(&config) {
                Ok(_) => panic!("A nonexistent serial device opened successfully"),
                Err(error) => error,
            };
            assert!(error.to_string().contains(&config.port_name));
        }
    }
}
