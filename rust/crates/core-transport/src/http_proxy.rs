//! HTTP CONNECT, verified TLS, and connection-bound proxy authentication.
use super::{ProxyAuthentication, TransportError};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use core_model::ProxyConfig;
use sspi::credssp::SspiContext;
use sspi::generator::{GeneratorState, NetworkRequest};
use sspi::network_client::NetworkProtocol;
use sspi::{
    AuthIdentity, BufferType, ClientRequestFlags, CredentialUse, Credentials, CredentialsBuffers,
    DataRepresentation, KerberosConfig, Negotiate, NegotiateConfig, Ntlm, SecurityBuffer,
    SecurityStatus, Sspi, SspiImpl, Username,
};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio_rustls::{rustls, TlsConnector};

pub(crate) trait ProxyIo: AsyncRead + AsyncWrite + Unpin + Send + std::fmt::Debug {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + std::fmt::Debug> ProxyIo for T {}
pub(crate) type ProxyStream = Box<dyn ProxyIo>;

fn failure(message: impl Into<String>) -> TransportError {
    TransportError::Connect(format!("HTTP CONNECT: {}", message.into()))
}

pub(crate) fn auth_method(proxy: &ProxyConfig) -> Result<&str, TransportError> {
    let method = proxy
        .auth_method
        .as_deref()
        .unwrap_or(if proxy.credential_id.is_some() {
            "basic"
        } else {
            "none"
        });
    if !matches!(method, "none" | "basic" | "ntlm" | "kerberos") {
        return Err(failure("phương thức xác thực proxy không hợp lệ"));
    }
    if proxy.kind != core_model::ProxyKind::HttpConnect {
        if proxy.tls.unwrap_or(false)
            || proxy.tls_server_name.is_some()
            || proxy.tls_ca_pem.is_some()
            || proxy
                .auth_method
                .as_deref()
                .is_some_and(|m| !matches!(m, "none" | "basic"))
        {
            return Err(failure("TLS, NTLM và Kerberos chỉ dùng với HTTP CONNECT"));
        }
    }
    if let Some(kdc) = proxy
        .auth_kdc_url
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        let url = reqwest::Url::parse(kdc).map_err(|_| failure("URL KDC không hợp lệ"))?;
        if kdc.len() > 2048
            || !matches!(url.scheme(), "tcp" | "udp" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || (url.scheme() != "https"
                && (url.query().is_some() || !matches!(url.path(), "" | "/")))
        {
            return Err(failure(
                "KDC yêu cầu tcp://, udp:// hoặc HTTPS; không chứa thông tin đăng nhập",
            ));
        }
    }
    for value in [&proxy.auth_domain, &proxy.auth_spn, &proxy.tls_server_name]
        .into_iter()
        .flatten()
    {
        if value.len() > 1024 || value.chars().any(char::is_control) {
            return Err(failure("Domain, SPN hoặc tên TLS không hợp lệ"));
        }
    }
    Ok(method)
}

async fn open_stream(proxy: &ProxyConfig) -> Result<ProxyStream, TransportError> {
    let stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    if !proxy.tls.unwrap_or(false) {
        return Ok(Box::new(stream));
    }
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    for cert in rustls_native_certs::load_native_certs().certs {
        let _ = roots.add(cert);
    }
    if let Some(pem) = proxy
        .tls_ca_pem
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        if pem.len() > 256 * 1024 || pem.contains("PRIVATE KEY") {
            return Err(failure("CA PEM không hợp lệ hoặc vượt giới hạn 256 KiB"));
        }
        let certs = rustls_pemfile::certs(&mut pem.as_bytes())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| failure("Không đọc được CA PEM"))?;
        if certs.is_empty() {
            return Err(failure("CA PEM không chứa chứng chỉ"));
        }
        for cert in certs {
            roots
                .add(cert)
                .map_err(|_| failure("Chứng chỉ CA không hợp lệ"))?;
        }
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| failure("Cấu hình TLS không hợp lệ"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let server_name = proxy
        .tls_server_name
        .as_deref()
        .filter(|s| !s.is_empty())
        .unwrap_or(&proxy.host);
    let name = rustls::pki_types::ServerName::try_from(server_name.to_owned())
        .map_err(|_| failure("Tên máy chủ TLS không hợp lệ"))?;
    let stream = TlsConnector::from(Arc::new(config))
        .connect(name, stream)
        .await
        .map_err(|_| {
            failure("TLS proxy thất bại: kiểm tra chứng chỉ CA, tên máy chủ và thời hạn")
        })?;
    Ok(Box::new(stream))
}

struct Response {
    status: u16,
    headers: Vec<(String, String)>,
}
impl Response {
    fn values<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> {
        self.headers
            .iter()
            .filter(move |(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }
    fn challenge(&self, scheme: &str) -> Result<Option<Vec<u8>>, TransportError> {
        for value in self.values("proxy-authenticate") {
            // Authentication headers may contain a comma-separated list. Neither
            // NTLM nor Negotiate tokens contain commas.
            for challenge in value.split(',') {
                let mut parts = challenge.split_ascii_whitespace();
                if parts.next().is_some_and(|s| s.eq_ignore_ascii_case(scheme)) {
                    let bytes = parts
                        .next()
                        .map(|s| BASE64.decode(s))
                        .transpose()
                        .map_err(|_| failure("Token xác thực proxy không hợp lệ"))?
                        .unwrap_or_default();
                    if parts.next().is_some() || bytes.len() > 64 * 1024 {
                        return Err(failure(
                            "Token xác thực proxy vượt giới hạn hoặc sai định dạng",
                        ));
                    }
                    return Ok(Some(bytes));
                }
            }
        }
        Ok(None)
    }
}

async fn read_response(
    stream: &mut ProxyStream,
    maximum: usize,
) -> Result<Response, TransportError> {
    let mut header = Vec::with_capacity(512);
    while !header.ends_with(b"\r\n\r\n") {
        if header.len() >= maximum {
            return Err(failure("Phản hồi proxy vượt giới hạn header"));
        }
        header.push(
            stream
                .read_u8()
                .await
                .map_err(|_| failure("Phản hồi proxy chưa hoàn chỉnh"))?,
        );
    }
    let text = std::str::from_utf8(&header).map_err(|_| failure("Header proxy không hợp lệ"))?;
    let mut lines = text.split("\r\n");
    let mut status = lines.next().unwrap_or_default().split_ascii_whitespace();
    if !matches!(status.next(), Some("HTTP/1.0" | "HTTP/1.1")) {
        return Err(failure("Phiên bản HTTP không hợp lệ"));
    }
    let code = status
        .next()
        .filter(|s| s.len() == 3 && s.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| failure("Mã trạng thái proxy không hợp lệ"))?;
    let mut headers = Vec::new();
    for line in lines.filter(|line| !line.is_empty()) {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| failure("Header proxy sai định dạng"))?;
        if name.is_empty()
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || value.chars().any(|ch| ch.is_control() && ch != '\t')
        {
            return Err(failure("Header proxy sai định dạng"));
        }
        headers.push((name.to_ascii_lowercase(), value.trim().to_owned()));
    }
    Ok(Response {
        status: code,
        headers,
    })
}

async fn discard_body(stream: &mut ProxyStream, response: &Response) -> Result<(), TransportError> {
    if response
        .values("connection")
        .chain(response.values("proxy-connection"))
        .any(|v| v.split(',').any(|v| v.trim().eq_ignore_ascii_case("close")))
    {
        return Err(failure(
            "Proxy đóng kết nối trong khi xác thực; cần keep-alive",
        ));
    }
    let lengths: Vec<_> = response.values("content-length").collect();
    let encodings: Vec<_> = response.values("transfer-encoding").collect();
    if lengths.len() > 1 || encodings.len() > 1 || (!lengths.is_empty() && !encodings.is_empty()) {
        return Err(failure("Độ dài phản hồi xác thực proxy mơ hồ"));
    }
    if let Some(length) = lengths.first() {
        let length = length
            .parse::<usize>()
            .ok()
            .filter(|n| *n <= 1024 * 1024)
            .ok_or_else(|| failure("Nội dung proxy vượt giới hạn 1 MiB"))?;
        let mut body = vec![0; length];
        stream.read_exact(&mut body).await?;
    } else if let Some(encoding) = encodings.first() {
        if !encoding.eq_ignore_ascii_case("chunked") {
            return Err(failure("Transfer-Encoding không hỗ trợ"));
        }
        let mut total = 0usize;
        loop {
            let mut line = Vec::new();
            while !line.ends_with(b"\r\n") {
                if line.len() > 128 {
                    return Err(failure("Chunk HTTP không hợp lệ"));
                }
                line.push(stream.read_u8().await?);
            }
            let length = std::str::from_utf8(&line[..line.len() - 2])
                .ok()
                .and_then(|s| {
                    usize::from_str_radix(s.split(';').next().unwrap_or_default(), 16).ok()
                })
                .ok_or_else(|| failure("Chunk HTTP không hợp lệ"))?;
            total = total
                .checked_add(length)
                .filter(|n| *n <= 1024 * 1024)
                .ok_or_else(|| failure("Nội dung proxy vượt giới hạn"))?;
            if length == 0 {
                // Refuse trailers rather than interpreting a second HTTP message.
                let mut end = [0; 2];
                stream.read_exact(&mut end).await?;
                if end != *b"\r\n" {
                    return Err(failure("Trailer HTTP không hỗ trợ"));
                }
                break;
            }
            let mut body = vec![0; length + 2];
            stream.read_exact(&mut body).await?;
            if !body.ends_with(b"\r\n") {
                return Err(failure("Chunk HTTP không hợp lệ"));
            }
        }
    } else {
        // A 407 without framing is close-delimited; retrying on this connection
        // would interpret an unknown response body as the next response.
        return Err(failure(
            "Phản hồi 407 phải có Content-Length hoặc chunked để xác thực an toàn",
        ));
    }
    Ok(())
}

struct Authentication {
    context: SspiContext,
    credentials: Option<CredentialsBuffers>,
    target: String,
    kerberos: bool,
}
impl Authentication {
    fn new(
        proxy: &ProxyConfig,
        username: &str,
        password: &str,
        kerberos: bool,
    ) -> Result<Self, TransportError> {
        let username = if username.contains('@')
            || username.contains('\\')
            || proxy.auth_domain.as_deref().unwrap_or("").is_empty()
        {
            username.to_owned()
        } else if kerberos {
            format!(
                "{username}@{}",
                proxy.auth_domain.as_deref().unwrap_or_default()
            )
        } else {
            format!(
                "{}\\{username}",
                proxy.auth_domain.as_deref().unwrap_or_default()
            )
        };
        let identity = Credentials::AuthIdentity(AuthIdentity {
            username: Username::parse(&username)
                .map_err(|_| failure("Username/domain proxy không hợp lệ"))?,
            password: password.to_owned().into(),
        });
        let mut context = if kerberos {
            let kdc = proxy
                .auth_kdc_url
                .as_deref()
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    failure("Kerberos cần URL KDC rõ ràng (tcp://, udp:// hoặc https://)")
                })?;
            SspiContext::Negotiate(
                Negotiate::new_client(NegotiateConfig::new(
                    Box::new(KerberosConfig::new_with_kdc_url(kdc, "TermPulse".into())),
                    Some("kerberos,!ntlm,!pku2u".into()),
                    "TermPulse".into(),
                ))
                .map_err(|_| failure("Không khởi tạo được Kerberos; kiểm tra realm/KDC"))?,
            )
        } else {
            SspiContext::Ntlm(Ntlm::new())
        };
        let credentials = context
            .acquire_credentials_handle()
            .with_credential_use(CredentialUse::Outbound)
            .with_auth_data(&identity)
            .execute(&mut context)
            .map_err(|_| failure("Không khởi tạo được Credential proxy"))?
            .credentials_handle;
        let target = proxy
            .auth_spn
            .clone()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| {
                format!(
                    "HTTP/{}",
                    proxy
                        .tls_server_name
                        .as_deref()
                        .filter(|s| !s.is_empty())
                        .unwrap_or(&proxy.host)
                )
            });
        Ok(Self {
            context,
            credentials,
            target,
            kerberos,
        })
    }
    async fn step(&mut self, token: Vec<u8>) -> Result<(Vec<u8>, bool), TransportError> {
        let mut input = [SecurityBuffer::new(token, BufferType::Token)];
        let mut output = [SecurityBuffer::new(Vec::new(), BufferType::Token)];
        let flags = ClientRequestFlags::ALLOCATE_MEMORY
            | ClientRequestFlags::INTEGRITY
            | if self.kerberos {
                ClientRequestFlags::MUTUAL_AUTH
            } else {
                ClientRequestFlags::empty()
            };
        let result = {
            let mut builder = self
                .context
                .initialize_security_context()
                .with_credentials_handle(&mut self.credentials)
                .with_context_requirements(flags)
                .with_target_data_representation(DataRepresentation::Native)
                .with_target_name(&self.target)
                .with_input(&mut input)
                .with_output(&mut output);
            let mut generator = self
                .context
                .initialize_security_context_impl(&mut builder)
                .map_err(|_| failure("Không tạo được token xác thực proxy"))?;
            let mut state = generator.start();
            let mut requests = 0;
            loop {
                match state {
                    GeneratorState::Completed(result) => {
                        break result.map_err(|_| {
                            failure(
                                "Xác thực proxy thất bại; kiểm tra tài khoản, realm, KDC và SPN",
                            )
                        })?
                    }
                    GeneratorState::Suspended(request) => {
                        requests += 1;
                        if requests > 12 {
                            return Err(failure("Quá nhiều lượt trao đổi Kerberos"));
                        }
                        state = generator.resume(kdc_request(request).await);
                    }
                }
            }
        };
        if matches!(
            result.status,
            SecurityStatus::CompleteNeeded | SecurityStatus::CompleteAndContinue
        ) {
            self.context
                .complete_auth_token(&mut output)
                .map_err(|_| failure("Không hoàn tất được token proxy"))?;
        }
        let done = matches!(
            result.status,
            SecurityStatus::Ok | SecurityStatus::CompleteNeeded
        );
        Ok((std::mem::take(&mut output[0].buffer), done))
    }
}

async fn kdc_request(request: NetworkRequest) -> Result<Vec<u8>, sspi::Error> {
    let error = || {
        sspi::Error::new(
            sspi::ErrorKind::NoAuthenticatingAuthority,
            "KDC không phản hồi hợp lệ hoặc đã hết thời gian",
        )
    };
    let result = tokio::time::timeout(Duration::from_secs(8), async {
        let host = request.url.host_str().ok_or_else(error)?;
        if request.data.len() > 1024 * 1024 {
            return Err(error());
        }
        match request.protocol {
            NetworkProtocol::Tcp => {
                let mut stream = TcpStream::connect((host, request.url.port().unwrap_or(88)))
                    .await
                    .map_err(|_| error())?;
                stream.write_all(&request.data).await.map_err(|_| error())?;
                let len = stream.read_u32().await.map_err(|_| error())?;
                if len == 0 || len > 1024 * 1024 {
                    return Err(error());
                }
                let mut data = vec![0; len as usize + 4];
                data[..4].copy_from_slice(&len.to_be_bytes());
                stream
                    .read_exact(&mut data[4..])
                    .await
                    .map_err(|_| error())?;
                Ok(data)
            }
            NetworkProtocol::Udp => {
                let address = tokio::net::lookup_host((host, request.url.port().unwrap_or(88)))
                    .await
                    .map_err(|_| error())?
                    .next()
                    .ok_or_else(error)?;
                let socket = UdpSocket::bind(if address.is_ipv6() {
                    "[::]:0"
                } else {
                    "0.0.0.0:0"
                })
                .await
                .map_err(|_| error())?;
                socket.connect(address).await.map_err(|_| error())?;
                socket.send(&request.data).await.map_err(|_| error())?;
                // SSPI normalizes KDC replies to the TCP length-prefixed form,
                // including replies received as a single UDP datagram.
                let mut data = vec![0; 65536 + 4];
                let count = socket.recv(&mut data[4..]).await.map_err(|_| error())?;
                if count == 0 {
                    return Err(error());
                }
                data[..4].copy_from_slice(&(count as u32).to_be_bytes());
                data.truncate(count + 4);
                Ok(data)
            }
            NetworkProtocol::Https => {
                let client = reqwest::Client::builder()
                    .no_proxy()
                    .redirect(reqwest::redirect::Policy::none())
                    .timeout(Duration::from_secs(8))
                    .build()
                    .map_err(|_| error())?;
                let mut response = client
                    .post(request.url)
                    .header("Content-Type", "application/kerberos")
                    .body(request.data)
                    .send()
                    .await
                    .map_err(|_| error())?
                    .error_for_status()
                    .map_err(|_| error())?;
                let mut data = Vec::new();
                while let Some(chunk) = response.chunk().await.map_err(|_| error())? {
                    if data.len() + chunk.len() > 1024 * 1024 {
                        return Err(error());
                    }
                    data.extend_from_slice(&chunk);
                }
                Ok(data)
            }
            NetworkProtocol::Http => Err(error()),
        }
    })
    .await;
    result.unwrap_or_else(|_| Err(error()))
}

pub(crate) async fn connect(
    proxy: &ProxyConfig,
    hostname: &str,
    port: u16,
    authentication: &ProxyAuthentication<'_>,
) -> Result<ProxyStream, TransportError> {
    let method = auth_method(proxy)?;
    let mut stream = open_stream(proxy).await?;
    let authority = if hostname.contains(':') {
        format!("[{hostname}]:{port}")
    } else {
        format!("{hostname}:{port}")
    };
    let credentials = match authentication {
        ProxyAuthentication::Password { username, password } => Some((*username, *password)),
        _ => None,
    };
    let mut engine = if matches!(method, "ntlm" | "kerberos") {
        let (username, password) = credentials
            .ok_or_else(|| failure("Phương thức proxy cần username và Credential mật khẩu"))?;
        Some(Authentication::new(
            proxy,
            username,
            password,
            method == "kerberos",
        )?)
    } else {
        None
    };
    let scheme = if method == "kerberos" {
        "Negotiate"
    } else {
        "NTLM"
    };
    let mut authorization = if method == "basic" {
        let (username, password) =
            credentials.ok_or_else(|| failure("Basic cần username và Credential mật khẩu"))?;
        Some(format!(
            "Basic {}",
            BASE64.encode(format!("{username}:{password}"))
        ))
    } else {
        None
    };
    let mut complete = false;
    for _ in 0..6 {
        let auth = authorization
            .as_ref()
            .map(|v| format!("Proxy-Authorization: {v}\r\n"))
            .unwrap_or_default();
        stream.write_all(format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n{auth}\r\n").as_bytes()).await?;
        let response = read_response(
            &mut stream,
            if engine.is_some() {
                96 * 1024
            } else {
                16 * 1024
            },
        )
        .await?;
        if response.status == 200 {
            if method == "kerberos" {
                if let Some(token) = response.challenge(scheme)? {
                    let (output, done) = engine.as_mut().unwrap().step(token).await?;
                    if !output.is_empty() || !done {
                        return Err(failure("Proxy chưa hoàn tất xác thực Kerberos hai chiều"));
                    }
                    complete = true;
                }
                if !complete {
                    return Err(failure(
                        "Thiếu bằng chứng xác thực Kerberos hai chiều từ proxy",
                    ));
                }
            } else if method == "ntlm" && !complete {
                return Err(failure("Proxy bỏ qua hoặc chưa hoàn tất NTLM"));
            }
            return Ok(stream);
        }
        if response.status != 407 || engine.is_none() {
            return Err(failure(format!(
                "Proxy từ chối CONNECT (trạng thái {})",
                response.status
            )));
        }
        let token = response.challenge(scheme)?.ok_or_else(|| {
            failure(format!(
                "Proxy không cung cấp {scheme}; không hạ cấp phương thức xác thực"
            ))
        })?;
        discard_body(&mut stream, &response).await?;
        if complete {
            return Err(failure("Proxy từ chối thông tin xác thực"));
        }
        let (output, done) = engine.as_mut().unwrap().step(token).await?;
        if output.is_empty() {
            return Err(failure("Token xác thực proxy rỗng"));
        }
        complete = done;
        authorization = Some(format!("{scheme} {}", BASE64.encode(output)));
    }
    Err(failure("Quá số lượt xác thực proxy"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_model::ProxyKind;
    use tokio::net::TcpListener;

    async fn request(stream: &mut (impl AsyncRead + Unpin)) -> String {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            assert!(bytes.len() < 96 * 1024);
            bytes.push(stream.read_u8().await.unwrap());
        }
        String::from_utf8(bytes).unwrap()
    }

    #[tokio::test]
    async fn verified_tls_accepts_private_ca_and_preserves_tunnel_bytes() {
        tls_case(true, "localhost", true).await;
        tls_case(false, "localhost", false).await;
        tls_case(true, "wrong.example", false).await;
    }

    async fn tls_case(trust: bool, server_name: &str, success: bool) {
        let certified = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let pem = certified.cert.pem();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certified.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der())
                    .into(),
            )
            .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            match tokio_rustls::TlsAcceptor::from(Arc::new(config))
                .accept(stream)
                .await
            {
                Ok(mut stream) => {
                    assert!(success);
                    assert!(request(&mut stream)
                        .await
                        .starts_with("CONNECT ssh.example:22 HTTP/1.1\r\n"));
                    stream
                        .write_all(b"HTTP/1.1 200 Established\r\n\r\nSSH-BANNER")
                        .await
                        .unwrap();
                    stream.shutdown().await.unwrap();
                }
                Err(_) => assert!(!success),
            }
        });
        let proxy = ProxyConfig {
            kind: ProxyKind::HttpConnect,
            host: "127.0.0.1".into(),
            port,
            tls: Some(true),
            tls_server_name: Some(server_name.into()),
            tls_ca_pem: trust.then_some(pem),
            ..Default::default()
        };
        let result = connect(&proxy, "ssh.example", 22, &ProxyAuthentication::None).await;
        assert_eq!(result.is_ok(), success);
        if let Ok(mut stream) = result {
            let mut banner = [0; 10];
            stream.read_exact(&mut banner).await.unwrap();
            assert_eq!(&banner, b"SSH-BANNER");
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn ntlm_connect_exchanges_real_challenge_response_on_same_connection() {
        use sspi::ServerRequestFlags;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            assert!(!request(&mut stream).await.contains("Proxy-Authorization:"));
            stream.write_all(b"HTTP/1.1 407 Authentication Required\r\nProxy-Authenticate: Basic realm=test\r\nProxy-Authenticate: NTLM\r\nContent-Length: 4\r\n\r\nbody").await.unwrap();
            let mut server = SspiContext::Ntlm(Ntlm::new());
            let identity = Credentials::AuthIdentity(AuthIdentity {
                username: Username::parse("EXAMPLE\\qa").unwrap(),
                password: "test-only-password".to_owned().into(),
            });
            let mut credentials = server
                .acquire_credentials_handle()
                .with_credential_use(CredentialUse::Inbound)
                .with_auth_data(&identity)
                .execute(&mut server)
                .unwrap()
                .credentials_handle;
            for round in 0..2 {
                let req = request(&mut stream).await;
                let auth = req
                    .lines()
                    .find_map(|s| s.strip_prefix("Proxy-Authorization: NTLM "))
                    .unwrap();
                let mut input = [SecurityBuffer::new(
                    BASE64.decode(auth).unwrap(),
                    BufferType::Token,
                )];
                let mut output = [SecurityBuffer::new(Vec::new(), BufferType::Token)];
                let builder = server
                    .accept_security_context()
                    .with_credentials_handle(&mut credentials)
                    .with_context_requirements(ServerRequestFlags::empty())
                    .with_target_data_representation(DataRepresentation::Native)
                    .with_input(&mut input)
                    .with_output(&mut output);
                let result = server
                    .accept_security_context_impl(builder)
                    .unwrap()
                    .resolve_to_result()
                    .unwrap();
                if round == 0 {
                    assert_eq!(result.status, SecurityStatus::ContinueNeeded);
                    stream.write_all(format!("HTTP/1.1 407 Authentication Required\r\nProxy-Authenticate: NTLM {}\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n0\r\n\r\n",BASE64.encode(&output[0].buffer)).as_bytes()).await.unwrap();
                } else {
                    if matches!(
                        result.status,
                        SecurityStatus::CompleteNeeded | SecurityStatus::CompleteAndContinue
                    ) {
                        server.complete_auth_token(&mut output).unwrap();
                    }
                    assert!(matches!(
                        result.status,
                        SecurityStatus::Ok | SecurityStatus::CompleteNeeded
                    ));
                    stream
                        .write_all(b"HTTP/1.1 200 Established\r\n\r\nSSH-BANNER")
                        .await
                        .unwrap();
                }
            }
        });
        let proxy = ProxyConfig {
            kind: ProxyKind::HttpConnect,
            host: "127.0.0.1".into(),
            port,
            auth_method: Some("ntlm".into()),
            auth_domain: Some("EXAMPLE".into()),
            ..Default::default()
        };
        let mut stream = connect(
            &proxy,
            "ssh.example",
            22,
            &ProxyAuthentication::Password {
                username: "qa",
                password: "test-only-password",
            },
        )
        .await
        .unwrap();
        let mut banner = Vec::new();
        stream.read_to_end(&mut banner).await.unwrap();
        assert_eq!(banner, b"SSH-BANNER");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn advanced_auth_refuses_downgrade_and_ambiguous_response() {
        for header in [
            "Proxy-Authenticate: Basic realm=test\r\nContent-Length: 0",
            "Proxy-Authenticate: NTLM\r\nContent-Length: 0\r\nTransfer-Encoding: chunked",
            "Proxy-Authenticate: NTLM\r\nConnection: close\r\nContent-Length: 0",
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                request(&mut stream).await;
                stream
                    .write_all(
                        format!("HTTP/1.1 407 Authentication Required\r\n{header}\r\n\r\n")
                            .as_bytes(),
                    )
                    .await
                    .unwrap();
                let mut bytes = Vec::new();
                stream.read_to_end(&mut bytes).await.unwrap();
                assert!(bytes.is_empty());
            });
            let proxy = ProxyConfig {
                kind: ProxyKind::HttpConnect,
                host: "127.0.0.1".into(),
                port,
                auth_method: Some("ntlm".into()),
                ..Default::default()
            };
            assert!(connect(
                &proxy,
                "ssh.example",
                22,
                &ProxyAuthentication::Password {
                    username: "qa",
                    password: "never-sent"
                }
            )
            .await
            .is_err());
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn kdc_tcp_is_framed_and_oversized_responses_are_rejected() {
        for length in [4u32, 1024 * 1024 + 1] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut data = [0; 8];
                stream.read_exact(&mut data).await.unwrap();
                assert_eq!(&data, b"\0\0\0\x04TEST");
                stream.write_all(&length.to_be_bytes()).await.unwrap();
                if length == 4 {
                    stream.write_all(b"KDC!").await.unwrap();
                }
            });
            let result = kdc_request(NetworkRequest {
                protocol: NetworkProtocol::Tcp,
                url: format!("tcp://127.0.0.1:{port}").parse().unwrap(),
                data: b"\0\0\0\x04TEST".to_vec(),
            })
            .await;
            if length == 4 {
                assert_eq!(result.unwrap(), b"\0\0\0\x04KDC!");
            } else {
                assert!(result.is_err());
            }
            server.await.unwrap();
        }
    }

    #[test]
    fn rejects_invalid_configuration_without_disclosing_passwords() {
        let mut proxy = ProxyConfig {
            kind: ProxyKind::HttpConnect,
            auth_method: Some("kerberos".into()),
            ..Default::default()
        };
        for url in [
            "http://kdc/",
            "tcp://user:secret@kdc:88",
            "tcp://kdc:88/path",
            "https://kdc/#fragment",
        ] {
            proxy.auth_kdc_url = Some(url.into());
            assert!(auth_method(&proxy).is_err());
        }
        proxy.auth_kdc_url = Some("tcp://kdc.example:88".into());
        assert!(auth_method(&proxy).is_ok());
        proxy.kind = ProxyKind::Socks5;
        assert!(auth_method(&proxy).is_err());
    }

    #[tokio::test]
    async fn kdc_udp_normalizes_the_response_frame_without_prefixing_the_request() {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = socket.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let mut bytes = [0; 32];
            let (count, peer) = socket.recv_from(&mut bytes).await.unwrap();
            assert_eq!(&bytes[..count], b"KDC-REQUEST");
            socket.send_to(b"KDC-REPLY", peer).await.unwrap();
        });
        let result = kdc_request(NetworkRequest {
            protocol: NetworkProtocol::Udp,
            url: format!("udp://127.0.0.1:{port}").parse().unwrap(),
            data: b"KDC-REQUEST".to_vec(),
        })
        .await
        .unwrap();
        assert_eq!(&result[..4], &9u32.to_be_bytes());
        assert_eq!(&result[4..], b"KDC-REPLY");
        server.await.unwrap();
    }
}
