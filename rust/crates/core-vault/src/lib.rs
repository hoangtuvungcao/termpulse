use argon2::Argon2;
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Nonce,
};
use core_model::{
    Credential, CredentialKind, EnvTag, Group, HighlightRule, Host, Identity, IdentityMode,
    InheritMode, ProtocolKind, ProxyConfig, ProxyKind, Snippet, TunnelKind, TunnelRule,
};
use rand::RngCore;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;
use zeroize::Zeroizing;

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("SQLite error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("Serialization error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Vault chưa được mở khoá")]
    Locked,
    #[error("Mật khẩu chính không chính xác")]
    InvalidMasterPassword,
    #[error("Lỗi mã hoá dữ liệu: {0}")]
    Crypto(String),
    #[error("Dữ liệu nhập không hợp lệ: {0}")]
    InvalidImport(String),
    #[error("Không tìm thấy Proxy ({0}). Chọn lại Proxy khả dụng trước khi lưu.")]
    MissingProxy(String),
    #[error("Không thể xoá Proxy vì đang được tham chiếu bởi: {0}")]
    ProxyInUse(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultExportBundle {
    pub version: u32,
    pub exported_at: i64,
    pub groups: Vec<Group>,
    pub credentials: Vec<Credential>,
    pub identities: Vec<Identity>,
    pub proxies: Vec<ProxyConfig>,
    pub hosts: Vec<Host>,
    pub tunnels: Vec<TunnelRule>,
    pub snippets: Vec<Snippet>,
    pub highlight_sets: Vec<HighlightRule>,
}

pub struct VaultStore {
    conn: Connection,
    master_key: Option<Zeroizing<[u8; 32]>>,
}

fn now_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn derive_key(password: &str, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>, VaultError> {
    let mut key = Zeroizing::new([0u8; 32]);
    Argon2::default()
        .hash_password_into(password.as_bytes(), salt, &mut *key)
        .map_err(|e| VaultError::Crypto(e.to_string()))?;
    Ok(key)
}

fn encrypt_bytes(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, VaultError> {
    let cipher = ChaCha20Poly1305::new(key.into());
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| VaultError::Crypto(e.to_string()))?;
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

fn decrypt_bytes(key: &[u8; 32], blob: &[u8]) -> Result<Vec<u8>, VaultError> {
    if blob.len() < 12 {
        return Err(VaultError::Crypto("Ciphertext truncated".into()));
    }
    let cipher = ChaCha20Poly1305::new(key.into());
    let nonce = Nonce::from_slice(&blob[..12]);
    cipher
        .decrypt(nonce, &blob[12..])
        .map_err(|_| VaultError::InvalidMasterPassword)
}

impl VaultStore {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, VaultError> {
        if let Some(parent) = path.as_ref().parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| VaultError::Crypto(format!("Cannot create vault dir: {e}")))?;
            }
        }
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
        Self::init_schema(&conn)?;
        Ok(Self {
            conn,
            master_key: None,
        })
    }

    pub fn open_in_memory() -> Result<Self, VaultError> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        Self::init_schema(&conn)?;
        Ok(Self {
            conn,
            master_key: None,
        })
    }

    fn init_schema(conn: &Connection) -> Result<(), VaultError> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS vault_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS groups (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                name TEXT NOT NULL,
                color_hex TEXT,
                icon TEXT,
                default_identity_id TEXT,
                default_jump_host_id TEXT,
                default_proxy_id TEXT,
                default_theme TEXT,
                env_json TEXT NOT NULL DEFAULT '{}',
                sort_order INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS credentials (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                secret_blob BLOB,
                public_key TEXT,
                key_fingerprint TEXT,
                storage_backend TEXT NOT NULL DEFAULT 'vault',
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS identities (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                username TEXT NOT NULL,
                credential_id TEXT,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS proxies (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                username TEXT,
                credential_id TEXT,
                tls INTEGER,
                tls_server_name TEXT,
                tls_ca_pem TEXT,
                auth_method TEXT,
                auth_domain TEXT,
                auth_spn TEXT,
                auth_kdc_url TEXT,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS hosts (
                id TEXT PRIMARY KEY,
                group_id TEXT,
                label TEXT NOT NULL,
                protocol TEXT NOT NULL,
                hostname TEXT NOT NULL,
                port INTEGER NOT NULL,
                identity_mode TEXT NOT NULL,
                identity_id TEXT,
                identity_name_ref TEXT,
                jump_host_mode TEXT NOT NULL,
                jump_host_id TEXT,
                proxy_mode TEXT NOT NULL,
                proxy_id TEXT,
                color_hex TEXT,
                icon TEXT,
                env_tag TEXT NOT NULL,
                tags_json TEXT NOT NULL DEFAULT '[]',
                notes TEXT NOT NULL DEFAULT '',
                startup_dir TEXT,
                startup_cmd TEXT,
                env_json TEXT NOT NULL DEFAULT '{}',
                follow_terminal_sftp INTEGER,
                preconnect_json TEXT NOT NULL DEFAULT '{}',
                serial_baudrate INTEGER,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                last_connected_at INTEGER,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS tunnels (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                host_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                bind_addr TEXT NOT NULL,
                bind_port INTEGER NOT NULL,
                target_host TEXT,
                target_port INTEGER,
                auto_start INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS snippets (
                id TEXT PRIMARY KEY,
                scope TEXT NOT NULL,
                scope_id TEXT,
                title TEXT NOT NULL,
                command_tpl TEXT NOT NULL,
                pin_button_bar INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS highlight_sets (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                pattern TEXT NOT NULL,
                fg_hex TEXT NOT NULL,
                bg_hex TEXT,
                bold INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS command_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host_id TEXT,
                command_text TEXT NOT NULL,
                used_count INTEGER NOT NULL DEFAULT 1,
                last_used_at INTEGER NOT NULL,
                UNIQUE(host_id, command_text)
            );
            "#,
        )?;
        let migration = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
        let proxy_columns = {
            let mut statement = migration.prepare("PRAGMA table_info(proxies)")?;
            let names = statement.query_map([], |row| row.get::<_, String>(1))?;
            names.collect::<Result<Vec<_>, _>>()?
        };
        for (name, definition) in [
            ("username", "TEXT"),
            ("tls", "INTEGER"),
            ("tls_server_name", "TEXT"),
            ("tls_ca_pem", "TEXT"),
            ("auth_method", "TEXT"),
            ("auth_domain", "TEXT"),
            ("auth_spn", "TEXT"),
            ("auth_kdc_url", "TEXT"),
        ] {
            if !proxy_columns.iter().any(|column| column == name) {
                migration.execute(&format!("ALTER TABLE proxies ADD COLUMN {name} {definition}"), [])?;
            }
        }
        let host_columns = {
            let mut statement = migration.prepare("PRAGMA table_info(hosts)")?;
            let names = statement.query_map([], |row| row.get::<_, String>(1))?;
            names.collect::<Result<Vec<_>, _>>()?
        };
        for (name, definition) in [
            ("serial_data_bits", "INTEGER"),
            ("serial_parity", "TEXT"),
            ("serial_stop_bits", "INTEGER"),
            ("serial_flow_control", "TEXT"),
            ("remote_desktop_json", "TEXT"),
        ] {
            if !host_columns.iter().any(|column| column == name) {
                migration.execute(&format!("ALTER TABLE hosts ADD COLUMN {name} {definition}"), [])?;
            }
        }
        migration.commit()?;
        Ok(())
    }

    pub fn is_initialized(&self) -> Result<bool, VaultError> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM vault_meta WHERE key = 'kdf_salt'",
            [],
            |r| r.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn is_unlocked(&self) -> bool {
        self.master_key.is_some()
    }

    pub fn lock(&mut self) {
        self.master_key = None;
    }

    /// Initializes a brand new vault with a master password (Argon2id + ChaCha20-Poly1305 verifier).
    pub fn initialize_and_unlock(&mut self, master_password: &str) -> Result<(), VaultError> {
        let mut salt = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut salt);
        let key = derive_key(master_password, &salt)?;
        let verifier = encrypt_bytes(&key, b"TERMPULSE_VAULT_V1")?;

        self.conn.execute(
            "INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('kdf_salt', ?1)",
            params![B64.encode(salt)],
        )?;
        self.conn.execute(
            "INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('verifier', ?1)",
            params![B64.encode(verifier)],
        )?;
        self.master_key = Some(key);
        self.seed_defaults_if_empty()?;
        Ok(())
    }

    pub fn unlock(&mut self, master_password: &str) -> Result<(), VaultError> {
        if !self.is_initialized()? {
            return self.initialize_and_unlock(master_password);
        }
        let salt_b64: String = self.conn.query_row(
            "SELECT value FROM vault_meta WHERE key = 'kdf_salt'",
            [],
            |r| r.get(0),
        )?;
        let verifier_b64: String = self.conn.query_row(
            "SELECT value FROM vault_meta WHERE key = 'verifier'",
            [],
            |r| r.get(0),
        )?;
        let salt = B64
            .decode(salt_b64)
            .map_err(|e| VaultError::Crypto(e.to_string()))?;
        let verifier = B64
            .decode(verifier_b64)
            .map_err(|e| VaultError::Crypto(e.to_string()))?;

        let key = derive_key(master_password, &salt)?;
        let plain = decrypt_bytes(&key, &verifier)?;
        if plain != b"TERMPULSE_VAULT_V1" {
            return Err(VaultError::InvalidMasterPassword);
        }
        self.master_key = Some(key);
        Ok(())
    }

    fn require_key(&self) -> Result<&[u8; 32], VaultError> {
        self.master_key
            .as_deref()
            .ok_or(VaultError::Locked)
    }

    // Import already holds an immediate transaction. Standalone writes acquire the
    // same lock before checking references so deletion cannot race a new reference.
    fn begin_reference_write(&self) -> Result<Option<rusqlite::Transaction<'_>>, VaultError> {
        if self.conn.is_autocommit() {
            Ok(Some(rusqlite::Transaction::new_unchecked(
                &self.conn,
                rusqlite::TransactionBehavior::Immediate,
            )?))
        } else {
            Ok(None)
        }
    }

    fn require_existing_proxy(&self, id: Option<&str>) -> Result<(), VaultError> {
        if let Some(id) = id {
            let exists: bool = self.conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM proxies WHERE id = ?1)",
                params![id],
                |row| row.get(0),
            )?;
            if !exists {
                return Err(VaultError::MissingProxy(id.to_owned()));
            }
        }
        Ok(())
    }

    fn seed_defaults_if_empty(&self) -> Result<(), VaultError> {
        let snip_count: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM snippets", [], |r| r.get(0))?;
        if snip_count == 0 {
            let defaults = [
                ("s_docker", "Docker PS", "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'", true),
                ("s_ports", "Listening Ports", "ss -tulnp", true),
                ("s_disk", "Disk Free", "df -hT", true),
                ("s_journal", "Systemd Errors", "journalctl -p err -n 50 --no-pager", false),
            ];
            for (id, title, cmd, pin) in defaults {
                self.upsert_snippet(&Snippet {
                    id: id.into(),
                    scope: "global".into(),
                    scope_id: None,
                    title: title.into(),
                    command_tpl: cmd.into(),
                    pin_button_bar: pin,
                })?;
            }
        }
        let hl_count: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM highlight_sets", [], |r| r.get(0))?;
        if hl_count == 0 {
            self.upsert_highlight(&HighlightRule {
                id: "hl_err".into(),
                name: "Errors".into(),
                pattern: "ERROR".into(),
                fg_hex: "#f87171".into(),
                bg_hex: None,
                bold: true,
            })?;
            self.upsert_highlight(&HighlightRule {
                id: "hl_warn".into(),
                name: "Warnings".into(),
                pattern: "WARN".into(),
                fg_hex: "#fbbf24".into(),
                bg_hex: None,
                bold: true,
            })?;
        }
        Ok(())
    }

    // --- Groups ---
    pub fn upsert_group(&self, g: &Group) -> Result<(), VaultError> {
        self.require_key()?;
        let transaction = self.begin_reference_write()?;
        self.require_existing_proxy(g.default_proxy_id.as_deref())?;
        self.conn.execute(
            r#"INSERT OR REPLACE INTO groups
               (id, parent_id, name, color_hex, icon, default_identity_id, default_jump_host_id,
                default_proxy_id, default_theme, env_json, sort_order, updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)"#,
            params![
                g.id,
                g.parent_id,
                g.name,
                g.color_hex,
                g.icon,
                g.default_identity_id,
                g.default_jump_host_id,
                g.default_proxy_id,
                g.default_theme,
                serde_json::to_string(&g.env)?,
                g.sort_order,
                now_ts()
            ],
        )?;
        if let Some(transaction) = transaction {
            transaction.commit()?;
        }
        Ok(())
    }

    pub fn list_groups(&self) -> Result<Vec<Group>, VaultError> {
        self.require_key()?;
        let mut stmt = self.conn.prepare(
            "SELECT id, parent_id, name, color_hex, icon, default_identity_id, default_jump_host_id,
                    default_proxy_id, default_theme, env_json, sort_order
             FROM groups ORDER BY sort_order ASC, name ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            let env_str: String = r.get(9)?;
            let env: BTreeMap<String, String> =
                serde_json::from_str(&env_str).unwrap_or_default();
            Ok(Group {
                id: r.get(0)?,
                parent_id: r.get(1)?,
                name: r.get(2)?,
                color_hex: r.get(3)?,
                icon: r.get(4)?,
                default_identity_id: r.get(5)?,
                default_jump_host_id: r.get(6)?,
                default_proxy_id: r.get(7)?,
                default_theme: r.get(8)?,
                env,
                sort_order: r.get(10)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_group(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute("DELETE FROM groups WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Credentials (Secrets encrypted with ChaCha20-Poly1305) ---
    pub fn upsert_credential(&self, c: &Credential) -> Result<(), VaultError> {
        let key = self.require_key()?;
        #[derive(Serialize)]
        struct SecretPayload<'a> {
            secret: Option<&'a str>,
            passphrase: Option<&'a str>,
        }
        let payload = serde_json::to_vec(&SecretPayload {
            secret: c.secret.as_deref(),
            passphrase: c.passphrase.as_deref(),
        })?;
        let encrypted = encrypt_bytes(key, &payload)?;

        self.conn.execute(
            r#"INSERT OR REPLACE INTO credentials
               (id, name, kind, secret_blob, public_key, key_fingerprint, storage_backend, updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8)"#,
            params![
                c.id,
                c.name,
                serde_json::to_string(&c.kind)?,
                encrypted,
                c.public_key,
                c.key_fingerprint,
                c.storage_backend,
                now_ts()
            ],
        )?;
        Ok(())
    }

    pub fn list_credentials(&self) -> Result<Vec<Credential>, VaultError> {
        let key = self.require_key()?;
        #[derive(Deserialize)]
        struct SecretPayload {
            secret: Option<String>,
            passphrase: Option<String>,
        }
        let mut stmt = self.conn.prepare(
            "SELECT id, name, kind, secret_blob, public_key, key_fingerprint, storage_backend
             FROM credentials ORDER BY name ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            let kind_str: String = r.get(2)?;
            let blob: Option<Vec<u8>> = r.get(3)?;
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                kind_str,
                blob,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, Option<String>>(5)?,
                r.get::<_, String>(6)?,
            ))
        })?;

        let mut out = Vec::new();
        for row in rows {
            let (id, name, kind_str, blob, public_key, key_fingerprint, storage_backend) = row?;
            let kind: CredentialKind =
                serde_json::from_str(&kind_str).unwrap_or(CredentialKind::Password);
            let (secret, passphrase) = if let Some(b) = blob {
                let dec = decrypt_bytes(key, &b)?;
                let parsed: SecretPayload = serde_json::from_slice(&dec)?;
                (parsed.secret, parsed.passphrase)
            } else {
                (None, None)
            };
            out.push(Credential {
                id,
                name,
                kind,
                secret,
                passphrase,
                public_key,
                key_fingerprint,
                storage_backend,
            });
        }
        Ok(out)
    }

    pub fn delete_credential(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn
            .execute("DELETE FROM credentials WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Identities ---
    pub fn upsert_identity(&self, ident: &Identity) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            "INSERT OR REPLACE INTO identities (id, name, username, credential_id, updated_at)
             VALUES (?1,?2,?3,?4,?5)",
            params![
                ident.id,
                ident.name,
                ident.username,
                ident.credential_id,
                now_ts()
            ],
        )?;
        Ok(())
    }

    pub fn list_identities(&self) -> Result<Vec<Identity>, VaultError> {
        self.require_key()?;
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, username, credential_id FROM identities ORDER BY name ASC")?;
        let rows = stmt.query_map([], |r| {
            Ok(Identity {
                id: r.get(0)?,
                name: r.get(1)?,
                username: r.get(2)?,
                credential_id: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_identity(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn
            .execute("DELETE FROM identities WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Proxies ---
    pub fn upsert_proxy(&self, p: &ProxyConfig) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            "INSERT OR REPLACE INTO proxies (id, name, kind, host, port, username, credential_id, updated_at,
                tls, tls_server_name, tls_ca_pem, auth_method, auth_domain, auth_spn, auth_kdc_url)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                p.id,
                p.name,
                serde_json::to_string(&p.kind)?,
                p.host,
                p.port as i64,
                p.username,
                p.credential_id,
                now_ts(),
                p.tls.map(i64::from),
                p.tls_server_name,
                p.tls_ca_pem,
                p.auth_method,
                p.auth_domain,
                p.auth_spn,
                p.auth_kdc_url,
            ],
        )?;
        Ok(())
    }

    pub fn list_proxies(&self) -> Result<Vec<ProxyConfig>, VaultError> {
        self.require_key()?;
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, kind, host, port, credential_id, username,
                tls, tls_server_name, tls_ca_pem, auth_method, auth_domain, auth_spn, auth_kdc_url
                FROM proxies ORDER BY name ASC")?;
        let rows = stmt.query_map([], |r| {
            let kind_str: String = r.get(2)?;
            Ok(ProxyConfig {
                id: r.get(0)?,
                name: r.get(1)?,
                kind: serde_json::from_str(&kind_str).unwrap_or(ProxyKind::Socks5),
                host: r.get(3)?,
                port: r.get::<_, i64>(4)? as u16,
                credential_id: r.get(5)?,
                username: r.get(6)?,
                tls: r.get::<_, Option<i64>>(7)?.map(|value| value != 0),
                tls_server_name: r.get(8)?,
                tls_ca_pem: r.get(9)?,
                auth_method: r.get(10)?,
                auth_domain: r.get(11)?,
                auth_spn: r.get(12)?,
                auth_kdc_url: r.get(13)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_proxy(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        let transaction = self.begin_reference_write()?;
        let references = {
            let mut statement = self.conn.prepare(
                "SELECT 'Host', label, id FROM hosts WHERE proxy_id = ?1
                 UNION ALL SELECT 'Group', name, id FROM groups WHERE default_proxy_id = ?1
                 ORDER BY 1, 2, 3",
            )?;
            let rows = statement.query_map(params![id], |row| {
                Ok(format!("{} \"{}\" ({})", row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        if !references.is_empty() {
            return Err(VaultError::ProxyInUse(references.join("; ")));
        }
        // A credential can be shared by identities and other proxies. Never
        // remove or overwrite it as a side effect of deleting a configuration.
        self.conn.execute("DELETE FROM proxies WHERE id = ?1", params![id])?;
        if let Some(transaction) = transaction {
            transaction.commit()?;
        }
        Ok(())
    }

    // --- Hosts ---
    pub fn upsert_host(&self, h: &Host) -> Result<(), VaultError> {
        self.require_key()?;
        let transaction = self.begin_reference_write()?;
        self.require_existing_proxy(h.proxy_id.as_deref())?;
        self.conn.execute(
            r#"INSERT OR REPLACE INTO hosts (
                id, group_id, label, protocol, hostname, port, identity_mode, identity_id,
                identity_name_ref, jump_host_mode, jump_host_id, proxy_mode, proxy_id,
                color_hex, icon, env_tag, tags_json, notes, startup_dir, startup_cmd,
                env_json, follow_terminal_sftp, preconnect_json, serial_baudrate,
                is_favorite, last_connected_at, updated_at,
                serial_data_bits, serial_parity, serial_stop_bits, serial_flow_control, remote_desktop_json
            ) VALUES (
                ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32
            )"#,
            params![
                h.id,
                h.group_id,
                h.label,
                serde_json::to_string(&h.protocol)?,
                h.hostname,
                h.port as i64,
                serde_json::to_string(&h.identity_mode)?,
                h.identity_id,
                h.identity_name_ref,
                serde_json::to_string(&h.jump_host_mode)?,
                h.jump_host_id,
                serde_json::to_string(&h.proxy_mode)?,
                h.proxy_id,
                h.color_hex,
                h.icon,
                serde_json::to_string(&h.env_tag)?,
                serde_json::to_string(&h.tags)?,
                h.notes,
                h.startup_dir,
                h.startup_cmd,
                serde_json::to_string(&h.env)?,
                h.follow_terminal_sftp.map(|v| if v { 1i64 } else { 0i64 }),
                serde_json::to_string(&h.preconnect)?,
                h.serial_baudrate.map(|v| v as i64),
                if h.is_favorite { 1i64 } else { 0i64 },
                h.last_connected_at,
                now_ts(),
                h.serial_data_bits.map(i64::from),
                h.serial_parity,
                h.serial_stop_bits.map(i64::from),
                h.serial_flow_control,
                h.remote_desktop_json,
            ],
        )?;
        if let Some(transaction) = transaction {
            transaction.commit()?;
        }
        Ok(())
    }

    pub fn list_hosts(&self) -> Result<Vec<Host>, VaultError> {
        self.require_key()?;
        let mut stmt = self.conn.prepare(
            "SELECT id, group_id, label, protocol, hostname, port, identity_mode, identity_id,
                    identity_name_ref, jump_host_mode, jump_host_id, proxy_mode, proxy_id,
                    color_hex, icon, env_tag, tags_json, notes, startup_dir, startup_cmd,
                    env_json, follow_terminal_sftp, preconnect_json, serial_baudrate,
                    is_favorite, last_connected_at,
                    serial_data_bits, serial_parity, serial_stop_bits, serial_flow_control, remote_desktop_json
             FROM hosts ORDER BY is_favorite DESC, label ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            let proto_s: String = r.get(3)?;
            let id_mode_s: String = r.get(6)?;
            let j_mode_s: String = r.get(9)?;
            let p_mode_s: String = r.get(11)?;
            let env_tag_s: String = r.get(15)?;
            let tags_s: String = r.get(16)?;
            let env_s: String = r.get(20)?;
            let follow_opt: Option<i64> = r.get(21)?;
            let pre_s: String = r.get(22)?;
            let baud_opt: Option<i64> = r.get(23)?;
            let fav: i64 = r.get(24)?;

            Ok(Host {
                id: r.get(0)?,
                group_id: r.get(1)?,
                label: r.get(2)?,
                protocol: serde_json::from_str(&proto_s).unwrap_or(ProtocolKind::Ssh),
                hostname: r.get(4)?,
                port: r.get::<_, i64>(5)? as u16,
                identity_mode: serde_json::from_str(&id_mode_s).unwrap_or(IdentityMode::Inherit),
                identity_id: r.get(7)?,
                identity_name_ref: r.get(8)?,
                jump_host_mode: serde_json::from_str(&j_mode_s).unwrap_or(InheritMode::Inherit),
                jump_host_id: r.get(10)?,
                proxy_mode: serde_json::from_str(&p_mode_s).unwrap_or(InheritMode::Inherit),
                proxy_id: r.get(12)?,
                color_hex: r.get(13)?,
                icon: r.get(14)?,
                env_tag: serde_json::from_str(&env_tag_s).unwrap_or(EnvTag::Dev),
                tags: serde_json::from_str(&tags_s).unwrap_or_default(),
                notes: r.get(17)?,
                startup_dir: r.get(18)?,
                startup_cmd: r.get(19)?,
                env: serde_json::from_str(&env_s).unwrap_or_default(),
                follow_terminal_sftp: follow_opt.map(|v| v != 0),
                preconnect: serde_json::from_str(&pre_s).unwrap_or_default(),
                serial_baudrate: baud_opt.map(|v| v as u32),
                serial_data_bits: r.get::<_, Option<u8>>(26)?,
                serial_parity: r.get(27)?,
                serial_stop_bits: r.get::<_, Option<u8>>(28)?,
                serial_flow_control: r.get(29)?,
                remote_desktop_json: r.get(30)?,
                is_favorite: fav != 0,
                last_connected_at: r.get(25)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn get_host(&self, id: &str) -> Result<Option<Host>, VaultError> {
        let all = self.list_hosts()?;
        Ok(all.into_iter().find(|h| h.id == id))
    }

    pub fn delete_host(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn
            .execute("DELETE FROM hosts WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn mark_host_connected(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            "UPDATE hosts SET last_connected_at = ?1 WHERE id = ?2",
            params![now_ts(), id],
        )?;
        Ok(())
    }

    // --- Tunnels ---
    pub fn upsert_tunnel(&self, t: &TunnelRule) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            r#"INSERT OR REPLACE INTO tunnels
               (id, name, host_id, kind, bind_addr, bind_port, target_host, target_port, auto_start, updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)"#,
            params![
                t.id,
                t.name,
                t.host_id,
                serde_json::to_string(&t.kind)?,
                t.bind_addr,
                t.bind_port as i64,
                t.target_host,
                t.target_port.map(|p| p as i64),
                if t.auto_start { 1i64 } else { 0i64 },
                now_ts()
            ],
        )?;
        Ok(())
    }

    pub fn list_tunnels(&self) -> Result<Vec<TunnelRule>, VaultError> {
        self.require_key()?;
        let mut stmt = self.conn.prepare(
            "SELECT id, name, host_id, kind, bind_addr, bind_port, target_host, target_port, auto_start
             FROM tunnels ORDER BY name ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            let kind_s: String = r.get(3)?;
            Ok(TunnelRule {
                id: r.get(0)?,
                name: r.get(1)?,
                host_id: r.get(2)?,
                kind: serde_json::from_str(&kind_s).unwrap_or(TunnelKind::Local),
                bind_addr: r.get(4)?,
                bind_port: r.get::<_, i64>(5)? as u16,
                target_host: r.get(6)?,
                target_port: r.get::<_, Option<i64>>(7)?.map(|p| p as u16),
                auto_start: r.get::<_, i64>(8)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_tunnel(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn
            .execute("DELETE FROM tunnels WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Snippets ---
    pub fn upsert_snippet(&self, s: &Snippet) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            "INSERT OR REPLACE INTO snippets (id, scope, scope_id, title, command_tpl, pin_button_bar, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                s.id,
                s.scope,
                s.scope_id,
                s.title,
                s.command_tpl,
                if s.pin_button_bar { 1i64 } else { 0i64 },
                now_ts()
            ],
        )?;
        Ok(())
    }

    pub fn list_snippets(&self) -> Result<Vec<Snippet>, VaultError> {
        self.require_key()?;
        let mut stmt = self.conn.prepare(
            "SELECT id, scope, scope_id, title, command_tpl, pin_button_bar FROM snippets ORDER BY pin_button_bar DESC, title ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Snippet {
                id: r.get(0)?,
                scope: r.get(1)?,
                scope_id: r.get(2)?,
                title: r.get(3)?,
                command_tpl: r.get(4)?,
                pin_button_bar: r.get::<_, i64>(5)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_snippet(&self, id: &str) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn
            .execute("DELETE FROM snippets WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Highlights & History ---
    pub fn upsert_highlight(&self, h: &HighlightRule) -> Result<(), VaultError> {
        self.require_key()?;
        self.conn.execute(
            "INSERT OR REPLACE INTO highlight_sets (id, name, pattern, fg_hex, bg_hex, bold)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                h.id,
                h.name,
                h.pattern,
                h.fg_hex,
                h.bg_hex,
                if h.bold { 1i64 } else { 0i64 }
            ],
        )?;
        Ok(())
    }

    pub fn list_highlights(&self) -> Result<Vec<HighlightRule>, VaultError> {
        self.require_key()?;
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, pattern, fg_hex, bg_hex, bold FROM highlight_sets")?;
        let rows = stmt.query_map([], |r| {
            Ok(HighlightRule {
                id: r.get(0)?,
                name: r.get(1)?,
                pattern: r.get(2)?,
                fg_hex: r.get(3)?,
                bg_hex: r.get(4)?,
                bold: r.get::<_, i64>(5)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn record_command_history(&self, host_id: Option<&str>, cmd: &str) -> Result<(), VaultError> {
        self.require_key()?;
        let trimmed = cmd.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM command_history WHERE host_id IS ?1 AND command_text = ?2",
                params![host_id, trimmed],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(row_id) = existing {
            self.conn.execute(
                "UPDATE command_history SET used_count = used_count + 1, last_used_at = ?1 WHERE id = ?2",
                params![now_ts(), row_id],
            )?;
        } else {
            self.conn.execute(
                "INSERT INTO command_history (host_id, command_text, used_count, last_used_at) VALUES (?1,?2,1,?3)",
                params![host_id, trimmed, now_ts()],
            )?;
        }
        Ok(())
    }

    pub fn list_command_history(&self, limit: usize) -> Result<Vec<(String, i64)>, VaultError> {
        self.require_key()?;
        let mut stmt = self.conn.prepare(
            "SELECT command_text, used_count FROM command_history ORDER BY used_count DESC, last_used_at DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    // --- Open JSON Export / Import (Never-brick guarantee) ---
    pub fn export_json(&self, include_secrets: bool) -> Result<String, VaultError> {
        self.require_key()?;
        let mut credentials = self.list_credentials()?;
        if !include_secrets {
            for c in &mut credentials {
                c.secret = None;
                c.passphrase = None;
            }
        }
        let bundle = VaultExportBundle {
            version: 1,
            exported_at: now_ts(),
            groups: self.list_groups()?,
            credentials,
            identities: self.list_identities()?,
            proxies: self.list_proxies()?,
            hosts: self.list_hosts()?,
            tunnels: self.list_tunnels()?,
            snippets: self.list_snippets()?,
            highlight_sets: self.list_highlights()?,
        };
        Ok(serde_json::to_string_pretty(&bundle)?)
    }

    pub fn import_json(&self, raw: &str) -> Result<usize, VaultError> {
        self.require_key()?;
        let bundle: VaultExportBundle = serde_json::from_str(raw)?;
        if bundle.version != 1 {
            return Err(VaultError::InvalidImport(format!(
                "Không hỗ trợ phiên bản {}", bundle.version
            )));
        }
        let existing_credentials = self.list_credentials()?;
        let transaction = rusqlite::Transaction::new_unchecked(
            &self.conn, rusqlite::TransactionBehavior::Immediate,
        )?;
        for proxy in &bundle.proxies {
            self.upsert_proxy(proxy)?;
        }
        for g in &bundle.groups {
            self.upsert_group(g)?;
        }
        for c in &bundle.credentials {
            let mut credential = c.clone();
            // A metadata-only export must not erase a secret already stored in this vault.
            if credential.secret.is_none() {
                if let Some(existing) = existing_credentials.iter().find(|existing| {
                    existing.id == credential.id && existing.kind == credential.kind
                }) {
                    credential.secret = existing.secret.clone();
                    if credential.passphrase.is_none() {
                        credential.passphrase = existing.passphrase.clone();
                    }
                }
            }
            self.upsert_credential(&credential)?;
        }
        for i in &bundle.identities {
            self.upsert_identity(i)?;
        }
        for h in &bundle.hosts {
            self.upsert_host(h)?;
        }
        for t in &bundle.tunnels {
            self.upsert_tunnel(t)?;
        }
        for s in &bundle.snippets {
            self.upsert_snippet(s)?;
        }
        for hl in &bundle.highlight_sets {
            self.upsert_highlight(hl)?;
        }
        transaction.commit()?;
        Ok(bundle.hosts.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    #[test]
    fn old_proxy_schema_migrates_without_losing_existing_configuration() {
        let database = NamedTempFile::new().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection.execute_batch("CREATE TABLE proxies (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL, credential_id TEXT, updated_at INTEGER NOT NULL);").unwrap();
        connection.execute("INSERT INTO proxies VALUES (?1,?2,?3,?4,?5,?6,?7)", params!["legacy", "Legacy proxy", "\"socks5\"", "127.0.0.1", 1080, "password-id", 1]).unwrap();
        drop(connection);
        let mut vault = VaultStore::open(database.path()).unwrap();
        vault.initialize_and_unlock("migration-test").unwrap();
        let mut proxy = vault.list_proxies().unwrap().remove(0);
        assert_eq!(proxy.id, "legacy");
        assert_eq!(proxy.username, None);
        assert_eq!(proxy.tls, None);
        assert_eq!(proxy.auth_method, None);
        assert_eq!(proxy.auth_kdc_url, None);
        assert_eq!(proxy.credential_id.as_deref(), Some("password-id"));
        proxy.username = Some("proxy-operator".into());
        proxy.tls = Some(true);
        proxy.tls_server_name = Some("secure.proxy.example".into());
        proxy.auth_method = Some("kerberos".into());
        proxy.auth_domain = Some("EXAMPLE.COM".into());
        proxy.auth_spn = Some("HTTP/secure.proxy.example".into());
        proxy.auth_kdc_url = Some("tcp://kdc.example:88".into());
        vault.upsert_proxy(&proxy).unwrap();
        drop(vault);
        let mut reopened = VaultStore::open(database.path()).unwrap();
        reopened.unlock("migration-test").unwrap();
        assert_eq!(reopened.list_proxies().unwrap(), vec![proxy]);
    }

    #[test]
    fn remote_desktop_options_survive_reopen_export_import_and_old_json() {
        let database = NamedTempFile::new().unwrap();
        let mut vault = VaultStore::open(database.path()).unwrap();
        vault.initialize_and_unlock("remote-test").unwrap();
        let host = Host { protocol: ProtocolKind::Rdp, hostname: "windows.example".into(), port: 3389,
            remote_desktop_json: Some(r#"{"width":1920,"height":1080,"domain":"CORP","tls_certificate_sha256":"aa"}"#.into()), ..Default::default() };
        vault.upsert_host(&host).unwrap(); drop(vault);
        let mut reopened = VaultStore::open(database.path()).unwrap(); reopened.unlock("remote-test").unwrap();
        assert_eq!(reopened.get_host(&host.id).unwrap(), Some(host.clone()));
        let exported = reopened.export_json(false).unwrap();
        let mut imported = VaultStore::open_in_memory().unwrap(); imported.initialize_and_unlock("other-test").unwrap();
        imported.import_json(&exported).unwrap();
        assert_eq!(imported.get_host(&host.id).unwrap(), Some(host.clone()));
        let mut old = serde_json::to_value(&host).unwrap(); old.as_object_mut().unwrap().remove("remote_desktop_json");
        assert_eq!(serde_json::from_value::<Host>(old).unwrap().remote_desktop_json, None);
    }

    #[test]
    fn serial_frame_settings_survive_reopen_and_export_import() {
        let database = NamedTempFile::new().unwrap();
        let mut vault = VaultStore::open(database.path()).unwrap();
        vault.initialize_and_unlock("serial-test").unwrap();
        let host = Host {protocol:core_model::ProtocolKind::Serial, hostname:"/dev/ttyUSB0".into(),
            serial_baudrate:Some(57600), serial_data_bits:Some(7), serial_parity:Some("even".into()),
            serial_stop_bits:Some(2), serial_flow_control:Some("hardware".into()), ..Default::default()};
        vault.upsert_host(&host).unwrap();
        drop(vault);
        let mut reopened = VaultStore::open(database.path()).unwrap();
        reopened.unlock("serial-test").unwrap();
        assert_eq!(reopened.get_host(&host.id).unwrap(),Some(host.clone()));
        let exported = reopened.export_json(false).unwrap();
        let mut imported = VaultStore::open_in_memory().unwrap();
        imported.initialize_and_unlock("import-test").unwrap();
        imported.import_json(&exported).unwrap();
        assert_eq!(imported.get_host(&host.id).unwrap(),Some(host));
    }

    #[test]
    fn proxy_auth_metadata_roundtrips_and_redacted_import_preserves_passwords() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("proxy-vault-test").unwrap();
        vault.upsert_credential(&Credential {
            id: "proxy-password".into(), name: "Proxy password".into(),
            secret: Some("PROXY_SECRET_TEST_837".into()), ..Default::default()
        }).unwrap();
        let proxy = ProxyConfig {
            id: "proxy".into(), name: "Corporate proxy".into(),
            kind: ProxyKind::HttpConnect, host: "proxy.example".into(), port: 3128,
            username: Some("proxy-user".into()), credential_id: Some("proxy-password".into()),
            tls: Some(true), tls_server_name: Some("proxy.example".into()),
            tls_ca_pem: Some("TEST_CA_PUBLIC_CERTIFICATE".into()),
            auth_method: Some("ntlm".into()), auth_domain: Some("CORP".into()),
            auth_spn: Some("HTTP/proxy.example".into()),
            auth_kdc_url: Some("https://kdc.example/KdcProxy".into()),
        };
        vault.upsert_proxy(&proxy).unwrap();
        let redacted = vault.export_json(false).unwrap();
        assert!(redacted.contains("proxy-user"));
        assert!(!redacted.contains("PROXY_SECRET_TEST_837"));
        vault.import_json(&redacted).unwrap();
        assert_eq!(vault.list_proxies().unwrap(), vec![proxy.clone()]);
        assert_eq!(vault.list_credentials().unwrap()[0].secret.as_deref(), Some("PROXY_SECRET_TEST_837"));
        let mut destination = VaultStore::open_in_memory().unwrap();
        destination.initialize_and_unlock("destination-test").unwrap();
        destination.import_json(&vault.export_json(true).unwrap()).unwrap();
        assert_eq!(destination.list_proxies().unwrap(), vec![proxy]);
        assert_eq!(destination.list_credentials().unwrap()[0].secret.as_deref(), Some("PROXY_SECRET_TEST_837"));
        // Legacy version-1 bundles omit all advanced metadata; they remain importable.
        let mut legacy: serde_json::Value = serde_json::from_str(&redacted).unwrap();
        for field in ["username", "tls", "tls_server_name", "tls_ca_pem", "auth_method", "auth_domain", "auth_spn", "auth_kdc_url"] {
            legacy["proxies"][0].as_object_mut().unwrap().remove(field);
        }
        destination.import_json(&legacy.to_string()).unwrap();
        assert_eq!(destination.list_proxies().unwrap()[0].username, None);
        assert_eq!(destination.list_proxies().unwrap()[0].tls, None);
        assert_eq!(destination.list_proxies().unwrap()[0].auth_method, None);
        assert_eq!(destination.list_proxies().unwrap()[0].auth_kdc_url, None);
        assert_eq!(destination.list_credentials().unwrap()[0].secret.as_deref(), Some("PROXY_SECRET_TEST_837"));
    }

    #[test]
    fn deleting_proxy_reports_all_stored_references_and_preserves_them() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("proxy-delete-references").unwrap();
        let proxy = ProxyConfig { id: "shared-proxy".into(), name: "Shared proxy".into(), ..Default::default() };
        vault.upsert_proxy(&proxy).unwrap();
        let host = Host {
            id: "host-ref".into(), label: "Production server".into(),
            proxy_mode: InheritMode::None, proxy_id: Some(proxy.id.clone()), ..Default::default()
        };
        let group = Group {
            id: "group-ref".into(), name: "Production group".into(),
            default_proxy_id: Some(proxy.id.clone()), ..Default::default()
        };
        vault.upsert_host(&host).unwrap();
        vault.upsert_group(&group).unwrap();
        let error = vault.delete_proxy(&proxy.id).unwrap_err();
        assert!(matches!(error, VaultError::ProxyInUse(_)));
        let message = error.to_string();
        for reference in ["Production server", "host-ref", "Production group", "group-ref"] {
            assert!(message.contains(reference), "missing reference {reference}: {message}");
        }
        assert_eq!(vault.list_proxies().unwrap(), vec![proxy.clone()]);
        assert_eq!(vault.list_hosts().unwrap(), vec![host]);
        assert_eq!(vault.list_groups().unwrap(), vec![group]);
        vault.delete_host("host-ref").unwrap();
        assert!(matches!(vault.delete_proxy(&proxy.id), Err(VaultError::ProxyInUse(_))));
        vault.delete_group("group-ref").unwrap();
        vault.delete_proxy(&proxy.id).unwrap();
        assert!(vault.list_proxies().unwrap().is_empty());
    }

    #[test]
    fn deleting_proxy_retains_shared_credentials_and_requires_unlocked_vault() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("proxy-delete-secret").unwrap();
        let credential = Credential {
            id: "shared-secret".into(), secret: Some("KEEP_SECRET".into()), ..Default::default()
        };
        vault.upsert_credential(&credential).unwrap();
        let proxy = ProxyConfig { id: "first".into(), credential_id: Some(credential.id.clone()), ..Default::default() };
        let other = ProxyConfig { id: "second".into(), ..proxy.clone() };
        vault.upsert_proxy(&proxy).unwrap();
        vault.upsert_proxy(&other).unwrap();
        vault.lock();
        assert!(matches!(vault.delete_proxy(&proxy.id), Err(VaultError::Locked)));
        vault.unlock("proxy-delete-secret").unwrap();
        vault.delete_proxy(&proxy.id).unwrap();
        assert_eq!(vault.list_proxies().unwrap(), vec![other]);
        assert_eq!(vault.list_credentials().unwrap(), vec![credential]);
        vault.delete_proxy("already-removed").unwrap();
    }

    #[test]
    fn deleted_proxy_cannot_be_reintroduced_by_stale_host_or_group_reference() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("proxy-stale-reference").unwrap();
        let proxy = ProxyConfig { id: "deleted-proxy".into(), ..Default::default() };
        vault.upsert_proxy(&proxy).unwrap();
        vault.delete_proxy(&proxy.id).unwrap();
        let host = Host { proxy_id: Some(proxy.id.clone()), ..Default::default() };
        let group = Group { default_proxy_id: Some(proxy.id.clone()), ..Default::default() };
        assert!(matches!(vault.upsert_host(&host), Err(VaultError::MissingProxy(_))));
        assert!(matches!(vault.upsert_group(&group), Err(VaultError::MissingProxy(_))));
        assert!(vault.list_hosts().unwrap().is_empty());
        assert!(vault.list_groups().unwrap().is_empty());
        // Import creates declared proxies before groups and validates every reference.
        let mut bundle: VaultExportBundle = serde_json::from_str(&vault.export_json(true).unwrap()).unwrap();
        bundle.proxies.push(proxy.clone());
        bundle.groups.push(group.clone());
        bundle.hosts.push(host.clone());
        vault.import_json(&serde_json::to_string(&bundle).unwrap()).unwrap();
        assert_eq!(vault.list_hosts().unwrap(), vec![host]);
        assert_eq!(vault.list_groups().unwrap(), vec![group]);
        assert_eq!(vault.list_proxies().unwrap(), vec![proxy]);
    }

    #[test]
    fn importing_metadata_preserves_existing_credentials() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("test-password").unwrap();
        vault.upsert_credential(&Credential {
            id: "existing".into(),
            name: "Existing key".into(),
            kind: CredentialKind::SshKey,
            secret: Some("PRIVATE_KEY_TEST".into()),
            passphrase: Some("PASSPHRASE_TEST".into()),
            ..Default::default()
        }).unwrap();
        let redacted = vault.export_json(false).unwrap();
        vault.import_json(&redacted).unwrap();
        let credentials = vault.list_credentials().unwrap();
        assert_eq!(credentials[0].secret.as_deref(), Some("PRIVATE_KEY_TEST"));
        assert_eq!(credentials[0].passphrase.as_deref(), Some("PASSPHRASE_TEST"));
    }

    #[test]
    fn failed_import_rolls_back_all_changes() {
        let mut vault = VaultStore::open_in_memory().unwrap();
        vault.initialize_and_unlock("test-password").unwrap();
        let mut bundle: VaultExportBundle = serde_json::from_str(&vault.export_json(true).unwrap()).unwrap();
        bundle.groups.push(Group { id: "new-group".into(), name: "New group".into(), ..Default::default() });
        bundle.hosts.push(Host { id: "fail-host".into(), ..Default::default() });
        vault.conn.execute_batch("CREATE TRIGGER reject_test_host BEFORE INSERT ON hosts BEGIN SELECT RAISE(FAIL, 'test failure'); END;").unwrap();
        assert!(vault.import_json(&serde_json::to_string(&bundle).unwrap()).is_err());
        assert!(vault.list_groups().unwrap().is_empty());

        bundle.version = 99;
        assert!(matches!(vault.import_json(&serde_json::to_string(&bundle).unwrap()), Err(VaultError::InvalidImport(_))));
        assert!(vault.list_groups().unwrap().is_empty());
    }

    #[test]
    fn vault_encrypts_secrets_and_roundtrips_json() {
        let tmp = NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();

        let mut vault = VaultStore::open(&path).unwrap();
        assert!(!vault.is_initialized().unwrap());
        vault.initialize_and_unlock("correct-horse-battery").unwrap();
        assert!(vault.is_unlocked());

        let cred = Credential {
            id: "c1".into(),
            name: "Prod Secret".into(),
            kind: CredentialKind::Password,
            secret: Some("super_secret_pw_999".into()),
            ..Default::default()
        };
        vault.upsert_credential(&cred).unwrap();

        let ident = Identity {
            id: "i1".into(),
            name: "Prod Ops".into(),
            username: "deploy".into(),
            credential_id: Some("c1".into()),
        };
        vault.upsert_identity(&ident).unwrap();

        let host = Host {
            id: "h1".into(),
            label: "prod-api-01".into(),
            hostname: "10.10.0.5".into(),
            identity_mode: IdentityMode::ById,
            identity_id: Some("i1".into()),
            env_tag: EnvTag::Prod,
            ..Default::default()
        };
        vault.upsert_host(&host).unwrap();

        // Ensure plaintext secret is NOT present raw in the sqlite file
        let raw_db_bytes = std::fs::read(&path).unwrap();
        assert!(
            !raw_db_bytes
                .windows(b"super_secret_pw_999".len())
                .any(|w| w == b"super_secret_pw_999"),
            "Secret leaked as plaintext on disk!"
        );

        let exported = vault.export_json(true).unwrap();
        drop(vault);

        // Wrong password must fail
        let mut vault2 = VaultStore::open(&path).unwrap();
        assert!(matches!(
            vault2.unlock("wrong-pass"),
            Err(VaultError::InvalidMasterPassword)
        ));
        vault2.unlock("correct-horse-battery").unwrap();
        assert_eq!(vault2.list_hosts().unwrap().len(), 1);
        assert_eq!(
            vault2.list_credentials().unwrap()[0].secret.as_deref(),
            Some("super_secret_pw_999")
        );

        // Import JSON into fresh vault
        let mut vault3 = VaultStore::open_in_memory().unwrap();
        vault3.initialize_and_unlock("new-pw").unwrap();
        let count = vault3.import_json(&exported).unwrap();
        assert_eq!(count, 1);
    }
}
