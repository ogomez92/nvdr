use std::fs;
use std::io::{self, ErrorKind};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

pub type TlsConn = TlsStream<TcpStream>;

#[derive(Debug)]
struct PinnedVerifier {
    /// If `Some`, only this lowercase hex SHA-256 fingerprint is accepted.
    required: Option<String>,
    /// TOFU cache key ("host:port") if we should learn-and-store.
    tofu_key: Option<String>,
    cache_path: Option<PathBuf>,
    insecure: bool,
    schemes: Vec<SignatureScheme>,
}

impl PinnedVerifier {
    fn new(
        required: Option<String>,
        tofu_key: Option<String>,
        cache_path: Option<PathBuf>,
        insecure: bool,
    ) -> Self {
        Self {
            required,
            tofu_key,
            cache_path,
            insecure,
            schemes: vec![
                SignatureScheme::RSA_PKCS1_SHA256,
                SignatureScheme::RSA_PKCS1_SHA384,
                SignatureScheme::RSA_PKCS1_SHA512,
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::ECDSA_NISTP521_SHA512,
                SignatureScheme::ED25519,
            ],
        }
    }
}

impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let fp = sha256_hex(end_entity.as_ref());
        if self.insecure {
            eprintln!("nvdr: [insecure] accepting cert fingerprint {fp}");
            return Ok(ServerCertVerified::assertion());
        }
        if let Some(req) = &self.required {
            if req.eq_ignore_ascii_case(&fp) {
                return Ok(ServerCertVerified::assertion());
            }
            return Err(rustls::Error::General(format!(
                "server cert fingerprint mismatch: expected {req}, got {fp}"
            )));
        }
        if let (Some(key), Some(path)) = (&self.tofu_key, &self.cache_path) {
            match load_pin(path, key) {
                Ok(Some(stored)) => {
                    if stored.eq_ignore_ascii_case(&fp) {
                        return Ok(ServerCertVerified::assertion());
                    }
                    // Use a machine-readable error so main.rs can spot a
                    // mismatch and prompt the user instead of asking them to
                    // hand-edit the file.
                    return Err(rustls::Error::General(format!(
                        "PIN_MISMATCH host={key} stored={stored} got={fp} path={}",
                        path.display()
                    )));
                }
                Ok(None) => {
                    eprintln!(
                        "nvdr: [TOFU] first connection to {key}, pinning fingerprint {fp}\n\
                         (cached in {})",
                        path.display()
                    );
                    if let Err(e) = store_pin(path, key, &fp) {
                        eprintln!("nvdr: warning, failed to persist pin: {e}");
                    }
                    return Ok(ServerCertVerified::assertion());
                }
                Err(e) => {
                    return Err(rustls::Error::General(format!(
                        "reading pin cache {}: {e}",
                        path.display()
                    )));
                }
            }
        }
        Err(rustls::Error::General(
            "no cert fingerprint pin configured".into(),
        ))
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes.clone()
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut s = String::with_capacity(digest.len() * 2);
    for b in digest {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn load_pin(path: &std::path::Path, key: &str) -> io::Result<Option<String>> {
    let data = match fs::read_to_string(path) {
        Ok(d) => d,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    for line in data.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once(char::is_whitespace) {
            if k == key {
                return Ok(Some(v.trim().to_string()));
            }
        }
    }
    Ok(None)
}

pub fn store_pin(path: &std::path::Path, key: &str, fp: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existing = fs::read_to_string(path).unwrap_or_default();
    let mut out = String::new();
    let mut replaced = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        match trimmed.split_once(char::is_whitespace) {
            Some((k, _)) if k == key => {
                out.push_str(&format!("{key} {fp}\n"));
                replaced = true;
            }
            _ => {
                out.push_str(line);
                out.push('\n');
            }
        }
    }
    if !replaced {
        out.push_str(&format!("{key} {fp}\n"));
    }
    fs::write(path, out)
}

pub fn default_pin_path() -> Option<PathBuf> {
    dirs::config_dir().map(|p| p.join("nvdr").join("known_hosts"))
}

pub async fn connect(
    host: &str,
    port: u16,
    fingerprint: Option<String>,
    insecure: bool,
    pin_path: Option<PathBuf>,
) -> Result<TlsConn> {
    let tcp = TcpStream::connect((host, port))
        .await
        .with_context(|| format!("TCP connect to {host}:{port}"))?;
    tcp.set_nodelay(true).ok();
    // SO_KEEPALIVE — best-effort
    let sock = socket2::SockRef::from(&tcp);
    let _ = sock.set_keepalive(true);

    let tofu_key = if fingerprint.is_none() && !insecure {
        Some(format!("{host}:{port}"))
    } else {
        None
    };
    let verifier = Arc::new(PinnedVerifier::new(
        fingerprint,
        tofu_key,
        pin_path,
        insecure,
    ));

    let config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();

    let connector = TlsConnector::from(Arc::new(config));
    // Server name is meaningless with our pinning verifier but rustls needs
    // *something*. Use the host string; fall back to a placeholder for IPs.
    let server_name = ServerName::try_from(host.to_string())
        .unwrap_or_else(|_| ServerName::try_from("localhost").unwrap());
    let stream = connector
        .connect(server_name, tcp)
        .await
        .map_err(|e| anyhow!("TLS handshake: {e}"))?;
    Ok(stream)
}

