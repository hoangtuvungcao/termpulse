use crate::api::dto::{SftpListingDto, TransferProgressDto};
use crate::frb_generated::StreamSink;
use crate::state::state;
use core_transport::{
    sftp_chmod, sftp_delete, sftp_download_file, sftp_list_dir, sftp_mkdir, sftp_read_bytes,
    sftp_rename, sftp_upload_file, sftp_write_bytes, TransferControl,
};
use russh_sftp::client::SftpSession;
use std::sync::atomic::Ordering;
use std::sync::Arc;

fn decode_text_file(bytes: Vec<u8>) -> Result<String, String> {
    String::from_utf8(bytes).map_err(|_| {
        "File không phải văn bản UTF-8. Hãy tải file về để mở bằng ứng dụng phù hợp.".into()
    })
}

async fn get_sftp(session_id: &str) -> Result<Arc<SftpSession>, String> {
    let guard = state().sessions.lock().await;
    let sess = guard
        .get(session_id)
        .ok_or_else(|| "Phiên không tồn tại".to_string())?;
    let sftp_arc = sess.sftp.clone();
    let reason = sess.sftp_unavailable_reason.clone();
    drop(guard);

    let sftp_guard = sftp_arc.lock().await;
    sftp_guard.clone().ok_or_else(|| {
        reason.unwrap_or_else(|| {
            "Server chưa bật SFTP subsystem. Hãy yêu cầu quản trị viên bật SFTP để truyền file."
                .into()
        })
    })
}

pub fn sftp_list_directory(session_id: String, path: String) -> Result<SftpListingDto, String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        let target = if path.trim().is_empty() || path == "~" {
            ".".to_string()
        } else {
            path
        };
        let (cwd, entries) = sftp_list_dir(&sftp, &target)
            .await
            .map_err(|e| e.to_string())?;
        Ok(SftpListingDto {
            cwd,
            entries: entries.into_iter().map(Into::into).collect(),
        })
    })
}

pub fn sftp_read_text(session_id: String, remote_path: String) -> Result<String, String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        let bytes = sftp_read_bytes(&sftp, &remote_path, 2 * 1024 * 1024)
            .await
            .map_err(|e| e.to_string())?;
        decode_text_file(bytes)
    })
}

pub fn sftp_write_text(
    session_id: String,
    remote_path: String,
    content: String,
) -> Result<(), String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        sftp_write_bytes(&sftp, &remote_path, content.as_bytes())
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn sftp_create_dir(session_id: String, remote_path: String) -> Result<(), String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        sftp_mkdir(&sftp, &remote_path)
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn sftp_rename_entry(
    session_id: String,
    old_path: String,
    new_path: String,
) -> Result<(), String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        sftp_rename(&sftp, &old_path, &new_path)
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn sftp_delete_entry(
    session_id: String,
    remote_path: String,
    is_dir: bool,
) -> Result<(), String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        sftp_delete(&sftp, &remote_path, is_dir)
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn sftp_set_permissions(
    session_id: String,
    remote_path: String,
    mode: u32,
) -> Result<(), String> {
    state().rt.block_on(async {
        let sftp = get_sftp(&session_id).await?;
        sftp_chmod(&sftp, &remote_path, mode)
            .await
            .map_err(|e| e.to_string())
    })
}

pub fn sftp_start_transfer(
    session_id: String,
    is_upload: bool,
    local_path: String,
    remote_path: String,
    sink: StreamSink<TransferProgressDto>,
) -> Result<String, String> {
    let transfer_id = uuid::Uuid::new_v4().to_string();
    let ctrl = Arc::new(TransferControl::default());
    state().rt.block_on(async {
        state().transfers.lock().await.insert(transfer_id.clone(), ctrl.clone());
    });

    let tid_spawn = transfer_id.clone();
    state().rt.spawn(async move {
        let sftp = match get_sftp(&session_id).await {
            Ok(s) => s,
            Err(e) => {
                state().transfers.lock().await.remove(&tid_spawn);
                let _ = sink.add(TransferProgressDto {
                    transfer_id: tid_spawn,
                    bytes_done: 0,
                    bytes_total: 0,
                    finished: true,
                    error: Some(e),
                });
                return;
            }
        };
        let tid_cb = tid_spawn.clone();
        let sink_cb = sink.clone();
        let res = if is_upload {
            sftp_upload_file(&sftp, &local_path, &remote_path, ctrl, move |done, total| {
                let _ = sink_cb.add(TransferProgressDto {
                    transfer_id: tid_cb.clone(),
                    bytes_done: done,
                    bytes_total: total,
                    finished: false,
                    error: None,
                });
            })
            .await
        } else {
            sftp_download_file(&sftp, &remote_path, &local_path, ctrl, move |done, total| {
                let _ = sink_cb.add(TransferProgressDto {
                    transfer_id: tid_cb.clone(),
                    bytes_done: done,
                    bytes_total: total,
                    finished: false,
                    error: None,
                });
            })
            .await
        };

        state().transfers.lock().await.remove(&tid_spawn);
        match res {
            Ok(bytes) => {
                let _ = sink.add(TransferProgressDto {
                    transfer_id: tid_spawn,
                    bytes_done: bytes,
                    bytes_total: bytes,
                    finished: true,
                    error: None,
                });
            }
            Err(e) => {
                let _ = sink.add(TransferProgressDto {
                    transfer_id: tid_spawn,
                    bytes_done: 0,
                    bytes_total: 0,
                    finished: true,
                    error: Some(e.to_string()),
                });
            }
        }
    });

    Ok(transfer_id)
}

pub fn sftp_control_transfer(transfer_id: String, action: String) -> Result<(), String> {
    if !matches!(action.as_str(), "pause" | "resume" | "cancel") {
        return Err("Thao tác truyền file không hợp lệ".into());
    }
    state().rt.block_on(async {
        if let Some(ctrl) = state().transfers.lock().await.get(&transfer_id) {
            match action.as_str() {
                "pause" => ctrl.paused.store(true, Ordering::Relaxed),
                "resume" => ctrl.paused.store(false, Ordering::Relaxed),
                "cancel" => ctrl.cancelled.store(true, Ordering::Relaxed),
                _ => {}
            }
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::decode_text_file;

    #[test]
    fn text_editor_preserves_utf8_and_rejects_binary_instead_of_replacing_bytes() {
        let text = "Tiếng Việt\r\nline two\n";
        assert_eq!(decode_text_file(text.as_bytes().to_vec()).unwrap(), text);
        assert!(decode_text_file(vec![0xff, 0xfe, 0x80]).is_err());
        assert_eq!(decode_text_file(Vec::new()).unwrap(), "");
    }
}
