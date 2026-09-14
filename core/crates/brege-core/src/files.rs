//! Phone folders in Finder: the phone serves its shared folders, the Mac reads and
//! writes them. Every operation uses its own FS stream (see `FsRequest` in the protocol).

use std::io::SeekFrom;
use std::sync::Arc;
use std::time::Duration;

use brege_features::files;
use brege_identity::DeviceId;
use brege_proto::StreamType;
use brege_proto::v1::{self as proto, fs_request::Op, fs_response::Error as FsCode};
use brege_transport::{Connection, RecvStream, SendStream, read_msg, write_msg};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

use crate::node::Inner;
use crate::{CoreError, Result};

/// Upper bound for one read request; larger reads are split by the caller.
pub const MAX_READ: u64 = 16 * 1024 * 1024;

/// Error returned by a [`FsBackend`] or by a remote phone.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{kind:?}: {message}")]
pub struct FsFailure {
    pub kind: FsErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsErrorKind {
    NotFound,
    Forbidden,
    Exists,
    Io,
    Unavailable,
    Invalid,
}

impl FsFailure {
    pub fn new(kind: FsErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    fn code(&self) -> FsCode {
        match self.kind {
            FsErrorKind::NotFound => FsCode::NotFound,
            FsErrorKind::Forbidden => FsCode::Forbidden,
            FsErrorKind::Exists => FsCode::Exists,
            FsErrorKind::Io => FsCode::Io,
            FsErrorKind::Unavailable => FsCode::Unavailable,
            FsErrorKind::Invalid => FsCode::Invalid,
        }
    }

    fn from_response(r: &proto::FsResponse) -> Self {
        let kind = match FsCode::try_from(r.error).unwrap_or(FsCode::Io) {
            FsCode::NotFound => FsErrorKind::NotFound,
            FsCode::Forbidden => FsErrorKind::Forbidden,
            FsCode::Exists => FsErrorKind::Exists,
            FsCode::Unavailable => FsErrorKind::Unavailable,
            FsCode::Invalid => FsErrorKind::Invalid,
            FsCode::Io | FsCode::Ok => FsErrorKind::Io,
        };
        Self::new(kind, r.message.clone())
    }
}

impl From<std::io::Error> for FsFailure {
    fn from(e: std::io::Error) -> Self {
        let kind = match e.kind() {
            std::io::ErrorKind::NotFound => FsErrorKind::NotFound,
            std::io::ErrorKind::PermissionDenied => FsErrorKind::Forbidden,
            std::io::ErrorKind::AlreadyExists => FsErrorKind::Exists,
            _ => FsErrorKind::Io,
        };
        Self::new(kind, e.to_string())
    }
}

/// Access to the phone's shared folders, implemented by the Android shell (Storage Access
/// Framework). Paths are already normalised; `/` lists the shared folders themselves.
/// Calls may block; the core runs them on a blocking thread.
pub trait FsBackend: Send + Sync + 'static {
    fn list(&self, path: &str) -> std::result::Result<Vec<proto::FsEntry>, FsFailure>;
    fn stat(&self, path: &str) -> std::result::Result<proto::FsEntry, FsFailure>;
    /// An open, seekable file for reading.
    fn open_read(&self, path: &str) -> std::result::Result<std::fs::File, FsFailure>;
    /// An open file for writing, created if missing.
    fn open_write(
        &self,
        path: &str,
        truncate: bool,
    ) -> std::result::Result<std::fs::File, FsFailure>;
    fn mkdir(&self, path: &str) -> std::result::Result<proto::FsEntry, FsFailure>;
    fn delete(&self, path: &str) -> std::result::Result<(), FsFailure>;
    fn rename(&self, from: &str, to: &str) -> std::result::Result<(), FsFailure>;
}

// --- phone side -------------------------------------------------------------------------------

fn failure_response(f: &FsFailure) -> proto::FsResponse {
    proto::FsResponse {
        error: f.code() as i32,
        message: f.message.clone(),
        ..Default::default()
    }
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> std::result::Result<T, FsFailure> + Send + 'static,
) -> std::result::Result<T, FsFailure> {
    tokio::task::spawn_blocking(f)
        .await
        .unwrap_or_else(|_| Err(FsFailure::new(FsErrorKind::Io, "backend panicked")))
}

/// Serves one FS stream from a paired Mac.
pub(crate) async fn serve(inner: Arc<Inner>, mut send: SendStream, mut recv: RecvStream) {
    let request: proto::FsRequest = match read_msg(&mut recv).await {
        Ok(Some(r)) => r,
        _ => return,
    };
    let backend = inner.fs_backend.read().unwrap().clone();
    let result = match (backend, files::normalize(&request.path)) {
        (None, _) => Err(FsFailure::new(
            FsErrorKind::Unavailable,
            "no folders shared on the phone",
        )),
        (_, Err(_)) => Err(FsFailure::new(FsErrorKind::Invalid, "invalid path")),
        (Some(backend), Ok(path)) => handle(backend, path, request.op, &mut send, &mut recv).await,
    };
    if let Err(failure) = result {
        let _ = write_msg(&mut send, &failure_response(&failure)).await;
    }
    let _ = send.finish();
}

async fn handle(
    backend: Arc<dyn FsBackend>,
    path: String,
    op: Option<Op>,
    send: &mut SendStream,
    recv: &mut RecvStream,
) -> std::result::Result<(), FsFailure> {
    let ok = |r: proto::FsResponse| proto::FsResponse {
        error: FsCode::Ok as i32,
        ..r
    };
    let io = |e: CoreError| FsFailure::new(FsErrorKind::Io, e.to_string());
    match op.ok_or_else(|| FsFailure::new(FsErrorKind::Invalid, "missing operation"))? {
        Op::List(_) => {
            let entries = blocking(move || backend.list(&path)).await?;
            write_msg(
                send,
                &ok(proto::FsResponse {
                    entries,
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| io(e.into()))?;
        }
        Op::Stat(_) => {
            let entry = blocking(move || backend.stat(&path)).await?;
            write_msg(
                send,
                &ok(proto::FsResponse {
                    entry: Some(entry),
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| io(e.into()))?;
        }
        Op::Mkdir(_) => {
            let entry = blocking(move || backend.mkdir(&path)).await?;
            write_msg(
                send,
                &ok(proto::FsResponse {
                    entry: Some(entry),
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| io(e.into()))?;
        }
        Op::Delete(_) => {
            blocking(move || backend.delete(&path)).await?;
            write_msg(send, &ok(proto::FsResponse::default()))
                .await
                .map_err(|e| io(e.into()))?;
        }
        Op::Rename(r) => {
            let to = files::normalize(&r.to)
                .map_err(|_| FsFailure::new(FsErrorKind::Invalid, "invalid target path"))?;
            blocking(move || backend.rename(&path, &to)).await?;
            write_msg(send, &ok(proto::FsResponse::default()))
                .await
                .map_err(|e| io(e.into()))?;
        }
        Op::Read(r) => {
            let file = blocking(move || backend.open_read(&path)).await?;
            let mut file = tokio::fs::File::from_std(file);
            let size = file.metadata().await?.len();
            let offset = r.offset.min(size);
            let length = r.length.min(MAX_READ).min(size - offset);
            file.seek(SeekFrom::Start(offset)).await?;
            write_msg(
                send,
                &ok(proto::FsResponse {
                    length,
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| io(e.into()))?;
            let mut limited = file.take(length);
            tokio::io::copy(&mut limited, send).await?;
        }
        Op::Write(w) => {
            // A replaced file is written next to the original and swapped in only once the Mac
            // has sent all of it: an aborted upload or copy must not destroy the original.
            let upload = if w.truncate {
                let stat = backend.clone();
                let target = path.clone();
                // Never replace a folder with a file.
                if blocking(move || stat.stat(&target))
                    .await
                    .is_ok_and(|e| e.dir)
                {
                    return Err(FsFailure::new(FsErrorKind::Invalid, "is a directory"));
                }
                temporary_sibling(&path)
            } else {
                path.clone()
            };
            let target = upload.clone();
            let opener = backend.clone();
            let file = blocking(move || opener.open_write(&target, w.truncate)).await?;
            let mut file = tokio::fs::File::from_std(file);
            let copied = async {
                tokio::io::copy(recv, &mut file).await?;
                file.flush().await?;
                file.sync_all().await
            }
            .await;
            drop(file);
            if let Err(e) = copied {
                if upload != path {
                    let cleanup = backend.clone();
                    let _ = blocking(move || cleanup.delete(&upload)).await;
                }
                return Err(e.into());
            }
            if upload != path {
                let renamer = backend.clone();
                let (from, target) = (upload.clone(), path.clone());
                if let Err(e) = blocking(move || renamer.rename(&from, &target)).await {
                    let cleanup = backend.clone();
                    let _ = blocking(move || cleanup.delete(&upload)).await;
                    return Err(e);
                }
            }
            let entry = blocking(move || backend.stat(&path)).await?;
            write_msg(
                send,
                &ok(proto::FsResponse {
                    entry: Some(entry),
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| io(e.into()))?;
        }
    }
    Ok(())
}

/// A hidden file in the same folder. Only a plain extension of the target is kept, so the phone
/// picks the right type but a storage provider has no reason to rewrite the name.
fn temporary_sibling(path: &str) -> String {
    let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
    let extension = name
        .rsplit_once('.')
        .map(|(_, ext)| ext)
        .filter(|ext| {
            (1..=10).contains(&ext.len()) && ext.bytes().all(|b| b.is_ascii_alphanumeric())
        })
        .map(|ext| format!(".{ext}"))
        .unwrap_or_default();
    format!(
        "{parent}/{}{}{extension}",
        files::UPLOAD_PREFIX,
        crate::random_hex(4)
    )
}

// --- Mac side ---------------------------------------------------------------------------------

fn connection(inner: &Inner, phone: &DeviceId) -> Result<Connection> {
    inner
        .sessions
        .lock()
        .unwrap()
        .get(phone)
        .map(|s| s.conn.clone())
        .ok_or(CoreError::NotConnected)
}

async fn request(
    inner: &Inner,
    phone: &DeviceId,
    path: &str,
    op: Op,
) -> Result<(SendStream, RecvStream)> {
    let conn = connection(inner, phone)?;
    let (mut send, recv) = conn.open_stream(StreamType::Fs).await?;
    write_msg(
        &mut send,
        &proto::FsRequest {
            path: path.to_string(),
            op: Some(op),
        },
    )
    .await?;
    Ok((send, recv))
}

async fn response(recv: &mut RecvStream) -> Result<proto::FsResponse> {
    let r: proto::FsResponse = read_msg(recv)
        .await?
        .ok_or_else(|| CoreError::InvalidInput("phone closed the file stream".into()))?;
    if r.error != FsCode::Ok as i32 {
        return Err(CoreError::FileSystem(FsFailure::from_response(&r)));
    }
    Ok(r)
}

/// Simple request with no payload in either direction.
async fn call(inner: &Inner, phone: &DeviceId, path: &str, op: Op) -> Result<proto::FsResponse> {
    let (mut send, mut recv) = request(inner, phone, path, op).await?;
    send.finish().map_err(|_| CoreError::NotConnected)?;
    response(&mut recv).await
}

pub(crate) async fn list(
    inner: &Inner,
    phone: &DeviceId,
    path: &str,
) -> Result<Vec<proto::FsEntry>> {
    Ok(call(inner, phone, path, Op::List(proto::FsList {}))
        .await?
        .entries)
}

pub(crate) async fn stat(inner: &Inner, phone: &DeviceId, path: &str) -> Result<proto::FsEntry> {
    call(inner, phone, path, Op::Stat(proto::FsStat {}))
        .await?
        .entry
        .ok_or_else(|| CoreError::InvalidInput("missing entry".into()))
}

pub(crate) async fn mkdir(inner: &Inner, phone: &DeviceId, path: &str) -> Result<proto::FsEntry> {
    call(inner, phone, path, Op::Mkdir(proto::FsMkdir {}))
        .await?
        .entry
        .ok_or_else(|| CoreError::InvalidInput("missing entry".into()))
}

pub(crate) async fn delete(inner: &Inner, phone: &DeviceId, path: &str) -> Result<()> {
    call(inner, phone, path, Op::Delete(proto::FsDelete {}))
        .await
        .map(|_| ())
}

pub(crate) async fn rename(inner: &Inner, phone: &DeviceId, from: &str, to: &str) -> Result<()> {
    call(
        inner,
        phone,
        from,
        Op::Rename(proto::FsRename { to: to.to_string() }),
    )
    .await
    .map(|_| ())
}

pub(crate) async fn read(
    inner: &Inner,
    phone: &DeviceId,
    path: &str,
    offset: u64,
    length: u64,
) -> Result<Vec<u8>> {
    let (mut send, mut recv) = request(
        inner,
        phone,
        path,
        Op::Read(proto::FsRead {
            offset,
            length: length.min(MAX_READ),
        }),
    )
    .await?;
    send.finish().map_err(|_| CoreError::NotConnected)?;
    let r = response(&mut recv).await?;
    // The phone must not make the Mac allocate more than it asked for.
    if r.length > length.min(MAX_READ) {
        return Err(CoreError::InvalidInput(
            "the phone sent more than requested".into(),
        ));
    }
    let mut data = vec![0u8; r.length as usize];
    recv.read_exact(&mut data)
        .await
        .map_err(|_| CoreError::NotConnected)?;
    Ok(data)
}

/// A file being uploaded to the phone. Write chunks, then call [`FsWriter::finish`]. Dropping it
/// without finishing aborts the upload, so the phone keeps the original file.
pub struct FsWriter {
    send: SendStream,
    recv: RecvStream,
    finished: bool,
}

impl Drop for FsWriter {
    fn drop(&mut self) {
        // A dropped stream would otherwise end cleanly and look like a complete upload.
        if !self.finished {
            let _ = self.send.reset(1u32.into());
        }
    }
}

impl FsWriter {
    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        if self.send.write_all(data).await.is_ok() {
            return Ok(());
        }
        // The phone refused the upload (e.g. no permission) and stopped reading: report its
        // reason rather than a lost connection.
        match tokio::time::timeout(Duration::from_secs(2), response(&mut self.recv)).await {
            Ok(Err(e @ CoreError::FileSystem(_))) => Err(e),
            _ => Err(CoreError::NotConnected),
        }
    }

    /// Completes the upload; returns the file's metadata on the phone.
    pub async fn finish(mut self) -> Result<proto::FsEntry> {
        self.finished = true;
        self.send.finish().map_err(|_| CoreError::NotConnected)?;
        response(&mut self.recv)
            .await?
            .entry
            .ok_or_else(|| CoreError::InvalidInput("missing entry".into()))
    }
}

pub(crate) async fn write(
    inner: &Inner,
    phone: &DeviceId,
    path: &str,
    truncate: bool,
) -> Result<FsWriter> {
    let (send, recv) = request(inner, phone, path, Op::Write(proto::FsWrite { truncate })).await?;
    Ok(FsWriter {
        send,
        recv,
        finished: false,
    })
}

#[cfg(test)]
mod tests {
    use super::temporary_sibling;

    #[test]
    fn temporary_names() {
        let name = temporary_sibling("/Docs/Report (final).PDF");
        assert!(name.starts_with("/Docs/.brege-upload-"), "{name}");
        assert!(name.ends_with(".PDF"), "{name}");
        assert_eq!(name.len(), "/Docs/.brege-upload-".len() + 8 + 4);
        for odd in [
            "/Docs/notes",
            "/Docs/a.tar gz",
            "/Docs/x.verylongextension",
            "/Docs/.env.",
        ] {
            let name = temporary_sibling(odd);
            assert_eq!(
                name.len(),
                "/Docs/.brege-upload-".len() + 8,
                "{odd} -> {name}"
            );
        }
    }
}
