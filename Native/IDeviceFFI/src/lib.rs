//! Eider's pairing-mode installer: install an IPA on an iPhone through the phone's own
//! RemotePairing service, with no manifest server.
//!
//! The flow, measured on 2026-11-28 from a Mac to an iPhone 17 Pro on iOS 27.3 over Wi-Fi
//! (192.168.1.50:49152; through LocalDevVPN on the phone itself it is 10.7.0.1:49152):
//! TCP to the RemotePairing port -> pair-verify with an RP pairing file -> TLS-PSK tunnel ->
//! RSD handshake (85 services) -> AFC upload to PublicStaging -> installation_proxy Install.
//!
//! Built on idevice (jkcoxson/idevice, MIT). idevice's own FFI `tunnel_create_rppairing`
//! falls back to a full pair-setup when pair-verify fails, and pair-setup on iOS shows the
//! user a Trust dialog ("awaitingUserConsent" in idevice's remote_pairing/mod.rs). An
//! installer must never do that, so this crate runs pair-verify only and reports a rejected
//! pairing file as an error instead.

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::time::Duration;

use idevice::IdeviceError;
use idevice::RsdService;
use idevice::afc::AfcClient;
use idevice::afc::opcode::AfcFopenMode;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::remote_pairing::errors::RemotePairingError;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use tokio::io::AsyncReadExt;

/// Result codes; mirrored in include/eider_idevice.h.
pub const EIDER_IDEVICE_OK: i32 = 0;
pub const EIDER_IDEVICE_ERR_INVALID_ARGUMENT: i32 = 1;
pub const EIDER_IDEVICE_ERR_PAIRING_FILE: i32 = 2;
pub const EIDER_IDEVICE_ERR_UNREACHABLE: i32 = 3;
pub const EIDER_IDEVICE_ERR_TIMEOUT: i32 = 4;
pub const EIDER_IDEVICE_ERR_PAIRING_REJECTED: i32 = 5;
pub const EIDER_IDEVICE_ERR_TUNNEL: i32 = 6;
pub const EIDER_IDEVICE_ERR_SERVICE: i32 = 7;
pub const EIDER_IDEVICE_ERR_LOCAL_FILE: i32 = 8;
pub const EIDER_IDEVICE_ERR_UPLOAD: i32 = 9;
pub const EIDER_IDEVICE_ERR_INSTALL: i32 = 10;
pub const EIDER_IDEVICE_ERR_UNINSTALL: i32 = 11;
pub const EIDER_IDEVICE_ERR_INTERNAL: i32 = 12;

/// Progress phases passed to the callback.
pub const EIDER_IDEVICE_PHASE_CONNECTING: i32 = 0;
pub const EIDER_IDEVICE_PHASE_UPLOADING: i32 = 1;
pub const EIDER_IDEVICE_PHASE_INSTALLING: i32 = 2;
pub const EIDER_IDEVICE_PHASE_FINISHED: i32 = 3;

/// The name this host gives the device. Only pair-setup shows it, and pair-setup never runs.
const SENDING_HOST: &str = "Eider";
/// AFC's own largest write; idevice and libimobiledevice use the same 1 MiB.
const UPLOAD_CHUNK: usize = 1024 * 1024;
const PUBLIC_STAGING: &str = "PublicStaging";
const AFC_SERVICE: &str = "com.apple.afc.shim.remote";
const INSTALL_SERVICE: &str = "com.apple.mobile.installation_proxy.shim.remote";

pub type ProgressCallback =
    Option<extern "C" fn(context: *mut c_void, phase: i32, done: i64, total: i64)>;

struct Failure {
    code: i32,
    message: String,
}

impl Failure {
    fn new(code: i32, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    /// Classifies an error from connecting, pairing or the tunnel.
    fn from_connect(error: IdeviceError) -> Self {
        match error {
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyFailed) => Self::new(
                EIDER_IDEVICE_ERR_PAIRING_REJECTED,
                "the iPhone did not accept this pairing file (pair-verify failed)",
            ),
            IdeviceError::RemotePairing(other) => {
                Self::new(EIDER_IDEVICE_ERR_PAIRING_REJECTED, format!("pairing: {other}"))
            }
            IdeviceError::Socket(e) => Self::new(EIDER_IDEVICE_ERR_UNREACHABLE, e.to_string()),
            IdeviceError::Timeout => Self::new(EIDER_IDEVICE_ERR_TIMEOUT, "timed out"),
            other => Self::new(EIDER_IDEVICE_ERR_TUNNEL, other.to_string()),
        }
    }
}

type Outcome<T> = Result<T, Failure>;

struct Progress {
    callback: ProgressCallback,
    context: *mut c_void,
}

impl Progress {
    fn report(&self, phase: i32, done: i64, total: i64) {
        if let Some(callback) = self.callback {
            callback(self.context, phase, done, total);
        }
    }
}

/// A connected tunnel and the RSD handshake made through it.
struct Session {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
}

async fn with_timeout<T>(
    limit: Duration,
    what: &str,
    future: impl Future<Output = Outcome<T>>,
) -> Outcome<T> {
    match tokio::time::timeout(limit, future).await {
        Ok(result) => result,
        Err(_) => Err(Failure::new(
            EIDER_IDEVICE_ERR_TIMEOUT,
            format!("{what} took longer than {} ms", limit.as_millis()),
        )),
    }
}

/// TCP connect -> pair-verify (never pair-setup) -> TLS-PSK tunnel -> RSD handshake.
async fn open_session(address: SocketAddr, pairing: &mut RpPairingFile) -> Outcome<Session> {
    let stream = tokio::net::TcpStream::connect(address)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_UNREACHABLE, format!("connect {address}: {e}")))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), SENDING_HOST);
    client.attempt_pair_verify().await.map_err(Failure::from_connect)?;
    client.validate_pairing(pairing).await.map_err(Failure::from_connect)?;

    let tunnel_port = client.create_tcp_listener().await.map_err(Failure::from_connect)?;
    let mut tunnel_address = address;
    tunnel_address.set_port(tunnel_port);
    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_address).await.map_err(|e| {
        Failure::new(EIDER_IDEVICE_ERR_TUNNEL, format!("tunnel connect {tunnel_address}: {e}"))
    })?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key())
        .await
        .map_err(Failure::from_connect)?;

    let parse = |s: &str| -> Outcome<IpAddr> {
        s.parse()
            .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_TUNNEL, format!("tunnel address {s}: {e}")))
    };
    let client_ip = parse(&tunnel.info.client_address)?;
    let server_ip = parse(&tunnel.info.server_address)?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    // idevice's FFI uses the same cap (fix(tunnel): set MSS to 8192, 2026-10-19).
    adapter.set_mss(mtu.min(8192).saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_TUNNEL, format!("RSD connect: {e}")))?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_TUNNEL, format!("RSD handshake: {e}")))?;
    Ok(Session { adapter, handshake })
}

fn require_services(handshake: &RsdHandshake) -> Outcome<()> {
    for name in [AFC_SERVICE, INSTALL_SERVICE] {
        if !handshake.services.contains_key(name) {
            return Err(Failure::new(
                EIDER_IDEVICE_ERR_SERVICE,
                format!("the iPhone does not offer {name} through this tunnel"),
            ));
        }
    }
    Ok(())
}

async fn upload(
    session: &mut Session,
    ipa: &PathBuf,
    remote_path: &str,
    progress: &Progress,
) -> Outcome<()> {
    let upload_error = |what: &str, e: IdeviceError| {
        Failure::new(EIDER_IDEVICE_ERR_UPLOAD, format!("{what}: {e}"))
    };
    let mut file = tokio::fs::File::open(ipa)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_LOCAL_FILE, format!("{}: {e}", ipa.display())))?;
    let total = file
        .metadata()
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_LOCAL_FILE, format!("{}: {e}", ipa.display())))?
        .len() as i64;

    let mut afc = AfcClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| upload_error("AFC connect", e))?;
    if afc.get_file_info(PUBLIC_STAGING).await.is_err() {
        afc.mk_dir(PUBLIC_STAGING).await.map_err(|e| upload_error("create PublicStaging", e))?;
    }
    let mut remote = afc
        .open(remote_path, AfcFopenMode::WrOnly)
        .await
        .map_err(|e| upload_error("open on device", e))?;

    let mut buffer = vec![0u8; UPLOAD_CHUNK];
    let mut sent: i64 = 0;
    progress.report(EIDER_IDEVICE_PHASE_UPLOADING, 0, total);
    loop {
        let n = file
            .read(&mut buffer)
            .await
            .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_LOCAL_FILE, format!("read IPA: {e}")))?;
        if n == 0 {
            break;
        }
        remote.write_entire(&buffer[..n]).await.map_err(|e| upload_error("write", e))?;
        sent += n as i64;
        progress.report(EIDER_IDEVICE_PHASE_UPLOADING, sent, total);
    }
    remote.close().await.map_err(|e| upload_error("close", e))?;
    Ok(())
}

async fn install(
    address: SocketAddr,
    mut pairing: RpPairingFile,
    connect_limit: Duration,
    ipa: PathBuf,
    bundle_id: String,
    progress: &Progress,
) -> Outcome<()> {
    progress.report(EIDER_IDEVICE_PHASE_CONNECTING, 0, 0);
    let mut session =
        with_timeout(connect_limit, "connecting", open_session(address, &mut pairing)).await?;
    require_services(&session.handshake)?;

    // One staging name per bundle id, so a failed install leaves at most one stale file.
    let remote_path = format!("{PUBLIC_STAGING}/{bundle_id}.ipa");
    upload(&mut session, &ipa, &remote_path, progress).await?;

    let mut proxy = InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_SERVICE, format!("installation_proxy: {e}")))?;
    let options = plist::Value::Dictionary(
        [("CFBundleIdentifier".to_string(), plist::Value::String(bundle_id.clone()))]
            .into_iter()
            .collect(),
    );
    progress.report(EIDER_IDEVICE_PHASE_INSTALLING, 0, 100);
    let report = |(percent, _): (u64, ())| async move {
        progress.report(EIDER_IDEVICE_PHASE_INSTALLING, percent as i64, 100);
    };
    let result = proxy
        .install_with_callback(remote_path.clone(), Some(options), report, ())
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_INSTALL, e.to_string()));

    // installd normally consumes the staged file; remove it if it is still there.
    if let Ok(mut afc) = AfcClient::connect_rsd(&mut session.adapter, &mut session.handshake).await {
        let _ = afc.remove(&remote_path).await;
    }
    result?;
    progress.report(EIDER_IDEVICE_PHASE_FINISHED, 100, 100);
    Ok(())
}

async fn uninstall(
    address: SocketAddr,
    mut pairing: RpPairingFile,
    connect_limit: Duration,
    bundle_id: String,
) -> Outcome<()> {
    let mut session =
        with_timeout(connect_limit, "connecting", open_session(address, &mut pairing)).await?;
    let mut proxy = InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_SERVICE, format!("installation_proxy: {e}")))?;
    proxy
        .uninstall(bundle_id, None)
        .await
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_UNINSTALL, e.to_string()))
}

async fn check(address: SocketAddr, mut pairing: RpPairingFile, limit: Duration) -> Outcome<()> {
    let session = with_timeout(limit, "connecting", open_session(address, &mut pairing)).await?;
    require_services(&session.handshake)
}

// MARK: - C boundary

unsafe fn c_string(pointer: *const c_char, what: &str) -> Outcome<String> {
    if pointer.is_null() {
        return Err(Failure::new(EIDER_IDEVICE_ERR_INVALID_ARGUMENT, format!("{what} is NULL")));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| Failure::new(EIDER_IDEVICE_ERR_INVALID_ARGUMENT, format!("{what} is not UTF-8")))
}

unsafe fn parse_common(
    host: *const c_char,
    port: u16,
    pairing: *const u8,
    pairing_len: usize,
) -> Outcome<(SocketAddr, RpPairingFile)> {
    let host = unsafe { c_string(host, "host") }?;
    let ip: IpAddr = host.parse().map_err(|_| {
        Failure::new(EIDER_IDEVICE_ERR_INVALID_ARGUMENT, format!("host {host:?} is not an IP address"))
    })?;
    if pairing.is_null() || pairing_len == 0 {
        return Err(Failure::new(EIDER_IDEVICE_ERR_PAIRING_FILE, "no pairing file"));
    }
    let bytes = unsafe { std::slice::from_raw_parts(pairing, pairing_len) };
    // The parse error names only the missing field; it never echoes key bytes.
    let file = RpPairingFile::from_bytes(bytes)
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_PAIRING_FILE, e.to_string()))?;
    Ok((SocketAddr::new(ip, port), file))
}

/// The tunnel, RSD and installation futures are large and block_on polls them on the stack of
/// the thread running it. On a GCD worker thread (512 KB) eider_idevice_check overflowed the
/// stack guard (SIGBUS, measured 2026-11-28 in swift test), so every call runs on a thread of
/// its own with this much stack, and the runtime's workers get the same.
const THREAD_STACK: usize = 16 * 1024 * 1024;

fn runtime() -> Outcome<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(THREAD_STACK)
        .enable_io()
        .enable_time()
        .build()
        .map_err(|e| Failure::new(EIDER_IDEVICE_ERR_INTERNAL, format!("runtime: {e}")))
}

/// Lets the caller's pointers (progress context, C strings) cross to the operation's thread;
/// the caller blocks until that thread is joined, so they outlive it.
struct AssertSend<T>(T);
unsafe impl<T> Send for AssertSend<T> {}

/// Runs `body` on a thread with a large stack and waits for it, turns a panic into an error,
/// and writes the message.
fn finish(out_message: *mut *mut c_char, body: impl FnOnce() -> Outcome<()>) -> i32 {
    let body = AssertSend(body);
    let joined = std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("eider-idevice".into())
            .stack_size(THREAD_STACK)
            .spawn_scoped(scope, move || {
                let body = body;
                catch_unwind(AssertUnwindSafe(body.0))
            })
            .map(|handle| handle.join())
    });
    let outcome = match joined {
        Ok(Ok(Ok(outcome))) => outcome,
        Ok(_) => Err(Failure::new(EIDER_IDEVICE_ERR_INTERNAL, "internal panic")),
        Err(e) => Err(Failure::new(EIDER_IDEVICE_ERR_INTERNAL, format!("thread: {e}"))),
    };
    match outcome {
        Ok(()) => EIDER_IDEVICE_OK,
        Err(failure) => {
            if !out_message.is_null() {
                let text = CString::new(failure.message.replace('\0', " "))
                    .unwrap_or_else(|_| CString::new("error").unwrap());
                unsafe { *out_message = text.into_raw() };
            }
            failure.code
        }
    }
}

fn block_on(future: impl Future<Output = Outcome<()>>) -> Outcome<()> {
    let runtime = runtime()?;
    let result = runtime.block_on(future);
    // The tunnel's adapter task may still be draining; do not wait on it.
    runtime.shutdown_timeout(Duration::from_millis(500));
    result
}

/// See include/eider_idevice.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eider_idevice_check(
    host: *const c_char,
    port: u16,
    pairing: *const u8,
    pairing_len: usize,
    timeout_ms: u32,
    out_message: *mut *mut c_char,
) -> i32 {
    finish(out_message, || {
        let (address, file) = unsafe { parse_common(host, port, pairing, pairing_len) }?;
        block_on(check(address, file, Duration::from_millis(timeout_ms.into())))
    })
}

/// See include/eider_idevice.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eider_idevice_install(
    host: *const c_char,
    port: u16,
    pairing: *const u8,
    pairing_len: usize,
    connect_timeout_ms: u32,
    ipa_path: *const c_char,
    bundle_id: *const c_char,
    progress: ProgressCallback,
    context: *mut c_void,
    out_message: *mut *mut c_char,
) -> i32 {
    finish(out_message, || {
        let (address, file) = unsafe { parse_common(host, port, pairing, pairing_len) }?;
        let ipa = PathBuf::from(unsafe { c_string(ipa_path, "ipa_path") }?);
        let bundle_id = unsafe { c_string(bundle_id, "bundle_id") }?;
        if bundle_id.is_empty() || bundle_id.contains('/') {
            return Err(Failure::new(EIDER_IDEVICE_ERR_INVALID_ARGUMENT, "bad bundle id"));
        }
        let progress = Progress { callback: progress, context };
        let limit = Duration::from_millis(connect_timeout_ms.into());
        block_on(install(address, file, limit, ipa, bundle_id, &progress))
    })
}

/// See include/eider_idevice.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eider_idevice_uninstall(
    host: *const c_char,
    port: u16,
    pairing: *const u8,
    pairing_len: usize,
    connect_timeout_ms: u32,
    bundle_id: *const c_char,
    out_message: *mut *mut c_char,
) -> i32 {
    finish(out_message, || {
        let (address, file) = unsafe { parse_common(host, port, pairing, pairing_len) }?;
        let bundle_id = unsafe { c_string(bundle_id, "bundle_id") }?;
        if bundle_id.is_empty() {
            return Err(Failure::new(EIDER_IDEVICE_ERR_INVALID_ARGUMENT, "bad bundle id"));
        }
        let limit = Duration::from_millis(connect_timeout_ms.into());
        block_on(uninstall(address, file, limit, bundle_id))
    })
}

/// See include/eider_idevice.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eider_idevice_free_string(message: *mut c_char) {
    if !message.is_null() {
        drop(unsafe { CString::from_raw(message) });
    }
}

/// See include/eider_idevice.h.
#[unsafe(no_mangle)]
pub extern "C" fn eider_idevice_version() -> *const c_char {
    concat!(
        "eider-idevice ",
        env!("CARGO_PKG_VERSION"),
        " (idevice c8fff6d7fb2690eaeb591ce510754effa7b1e19b)\0"
    )
    .as_ptr()
    .cast()
}
