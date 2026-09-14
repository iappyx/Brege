//! `dav_server` file system over the phone's shared folders.

use std::collections::HashMap;
use std::io::SeekFrom;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use brege_core::proto::FsEntry;
use brege_core::{CoreError, DeviceId, FsErrorKind, FsWriter, Node};
use brege_features::files;
use bytes::{Buf, Bytes};
use dav_server::davpath::DavPath;
use dav_server::fs::{
    DavDirEntry, DavFile, DavFileSystem, DavMetaData, FsError, FsFuture, FsResult, FsStream,
    OpenOptions, ReadDirMeta,
};
use futures_util::{FutureExt, stream};

/// Listings and metadata are reused briefly: Finder asks the same questions many times in a row.
const CACHE_TTL: Duration = Duration::from_secs(3);
/// Reads ahead so sequential reads (copying, previews) need few round trips.
const READ_AHEAD: u64 = 4 * 1024 * 1024;
const COPY_CHUNK: u64 = 4 * 1024 * 1024;
/// Finder metadata files live in memory; a request may not make one (or seek) beyond this.
const MAX_META_FILE: usize = 16 * 1024 * 1024;

fn fs_error(e: CoreError) -> FsError {
    match e {
        CoreError::FileSystem(f) => match f.kind {
            FsErrorKind::NotFound => FsError::NotFound,
            FsErrorKind::Forbidden | FsErrorKind::Invalid => FsError::Forbidden,
            FsErrorKind::Exists => FsError::Exists,
            FsErrorKind::Io | FsErrorKind::Unavailable => FsError::GeneralFailure,
        },
        other => {
            tracing::debug!("drive: {other}");
            FsError::GeneralFailure
        }
    }
}

fn path_string(path: &DavPath) -> FsResult<String> {
    let raw = String::from_utf8(path.as_bytes().to_vec()).map_err(|_| FsError::Forbidden)?;
    files::normalize(&raw).map_err(|_| FsError::Forbidden)
}

fn name_of(path: &str) -> &str {
    files::split_parent(path)
        .map(|(_, name)| name)
        .unwrap_or("")
}

#[derive(Debug, Clone)]
struct Meta {
    size: u64,
    modified: SystemTime,
    dir: bool,
}

impl Meta {
    fn from_entry(e: &FsEntry) -> Self {
        Self {
            size: e.size,
            modified: UNIX_EPOCH + Duration::from_millis(e.modified_ms.max(0) as u64),
            dir: e.dir,
        }
    }

    fn dir() -> Self {
        Self {
            size: 0,
            modified: SystemTime::now(),
            dir: true,
        }
    }

    fn file(size: u64) -> Self {
        Self {
            size,
            modified: SystemTime::now(),
            dir: false,
        }
    }
}

impl DavMetaData for Meta {
    fn len(&self) -> u64 {
        self.size
    }

    fn modified(&self) -> FsResult<SystemTime> {
        Ok(self.modified)
    }

    fn is_dir(&self) -> bool {
        self.dir
    }
}

#[derive(Debug)]
struct Entry {
    name: String,
    meta: Meta,
}

impl DavDirEntry for Entry {
    fn name(&self) -> Vec<u8> {
        self.name.as_bytes().to_vec()
    }

    fn metadata(&self) -> FsFuture<'_, Box<dyn DavMetaData>> {
        let meta: Box<dyn DavMetaData> = Box::new(self.meta.clone());
        async move { Ok(meta) }.boxed()
    }
}

#[derive(Default)]
struct Cache {
    listings: HashMap<String, (Instant, Vec<FsEntry>)>,
    stats: HashMap<String, (Instant, FsEntry)>,
}

impl Cache {
    fn listing(&self, path: &str) -> Option<Vec<FsEntry>> {
        self.listings
            .get(path)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, e)| e.clone())
    }

    fn stat(&self, path: &str) -> Option<FsEntry> {
        if let Some((at, e)) = self.stats.get(path)
            && at.elapsed() < CACHE_TTL
        {
            return Some(e.clone());
        }
        let (parent, name) = files::split_parent(path)?;
        self.listing(parent)?.into_iter().find(|e| e.name == name)
    }

    /// Forgets a path, everything below it and its parent listing.
    fn invalidate(&mut self, path: &str) {
        let below = format!("{path}/");
        self.listings
            .retain(|k, _| k != path && !k.starts_with(&below));
        self.stats
            .retain(|k, _| k != path && !k.starts_with(&below));
        if let Some((parent, _)) = files::split_parent(path) {
            self.listings.remove(parent);
        }
    }
}

/// Finder metadata files kept in memory on the Mac.
#[derive(Default)]
struct LocalMeta {
    files: HashMap<String, Vec<u8>>,
}

#[derive(Clone)]
pub struct PhoneFs {
    node: Node,
    phone: DeviceId,
    cache: Arc<Mutex<Cache>>,
    local: Arc<Mutex<LocalMeta>>,
}

impl PhoneFs {
    pub fn new(node: Node, phone: DeviceId) -> Self {
        Self {
            node,
            phone,
            cache: Arc::default(),
            local: Arc::default(),
        }
    }

    async fn stat(&self, path: &str) -> FsResult<Meta> {
        if path == "/" {
            return Ok(Meta::dir());
        }
        if files::is_mac_metadata(name_of(path)) {
            if path == "/.metadata_never_index" {
                return Ok(Meta::file(0)); // keeps the Mac's search index off the phone
            }
            return self
                .local
                .lock()
                .unwrap()
                .files
                .get(path)
                .map(|d| Meta::file(d.len() as u64))
                .ok_or(FsError::NotFound);
        }
        if let Some(e) = self.cache.lock().unwrap().stat(path) {
            return Ok(Meta::from_entry(&e));
        }
        let entry = self
            .node
            .fs_stat(self.phone, path)
            .await
            .map_err(fs_error)?;
        self.cache
            .lock()
            .unwrap()
            .stats
            .insert(path.to_string(), (Instant::now(), entry.clone()));
        Ok(Meta::from_entry(&entry))
    }

    async fn list(&self, path: &str) -> FsResult<Vec<FsEntry>> {
        if let Some(entries) = self.cache.lock().unwrap().listing(path) {
            return Ok(entries);
        }
        let entries = self
            .node
            .fs_list(self.phone, path)
            .await
            .map_err(fs_error)?;
        self.cache
            .lock()
            .unwrap()
            .listings
            .insert(path.to_string(), (Instant::now(), entries.clone()));
        Ok(entries)
    }

    fn invalidate(&self, path: &str) {
        self.cache.lock().unwrap().invalidate(path);
    }
}

impl DavFileSystem for PhoneFs {
    fn open<'a>(
        &'a self,
        path: &'a DavPath,
        options: OpenOptions,
    ) -> FsFuture<'a, Box<dyn DavFile>> {
        async move {
            let path = path_string(path)?;
            if files::is_mac_metadata(name_of(&path)) {
                let mut local = self.local.lock().unwrap();
                let exists = local.files.contains_key(&path) || path == "/.metadata_never_index";
                if options.write {
                    if options.create_new && exists {
                        return Err(FsError::Exists);
                    }
                    if !exists && !options.create && !options.create_new {
                        return Err(FsError::NotFound);
                    }
                    if options.truncate || !exists {
                        local.files.insert(path.clone(), Vec::new());
                    }
                } else if !exists {
                    return Err(FsError::NotFound);
                }
                let data = local.files.get(&path).cloned().unwrap_or_default();
                return Ok(Box::new(MemFile {
                    fs: self.clone(),
                    path,
                    data,
                    pos: 0,
                    dirty: false,
                }) as Box<dyn DavFile>);
            }

            if options.write {
                let existing = self.stat(&path).await;
                if options.create_new && existing.is_ok() {
                    return Err(FsError::Exists);
                }
                if !options.create && !options.create_new && existing.is_err() {
                    return Err(FsError::NotFound);
                }
                // A file is never written over a folder.
                if existing.as_ref().is_ok_and(|meta| meta.dir) {
                    return Err(FsError::Forbidden);
                }
                // Uploads replace a whole file. Ranges and appends (PATCH, Content-Range) into an
                // existing file are refused rather than written over its start.
                if existing.is_ok() && !options.truncate {
                    return Err(FsError::NotImplemented);
                }
                return Ok(
                    Box::new(PhoneFile::writer(self.clone(), path, true, options.size))
                        as Box<dyn DavFile>,
                );
            }

            let meta = self.stat(&path).await?;
            if meta.dir {
                return Err(FsError::Forbidden);
            }
            Ok(Box::new(PhoneFile::reader(self.clone(), path, meta)) as Box<dyn DavFile>)
        }
        .boxed()
    }

    fn read_dir<'a>(
        &'a self,
        path: &'a DavPath,
        _meta: ReadDirMeta,
    ) -> FsFuture<'a, FsStream<Box<dyn DavDirEntry>>> {
        async move {
            let path = path_string(path)?;
            let entries = self.list(&path).await?;
            let items: Vec<FsResult<Box<dyn DavDirEntry>>> = entries
                .into_iter()
                .filter(|e| !files::is_mac_metadata(&e.name) && !files::is_upload_temp(&e.name))
                .map(|e| {
                    Ok(Box::new(Entry {
                        meta: Meta::from_entry(&e),
                        name: e.name,
                    }) as Box<dyn DavDirEntry>)
                })
                .collect();
            Ok(Box::pin(stream::iter(items)) as FsStream<Box<dyn DavDirEntry>>)
        }
        .boxed()
    }

    fn metadata<'a>(&'a self, path: &'a DavPath) -> FsFuture<'a, Box<dyn DavMetaData>> {
        async move {
            let path = path_string(path)?;
            Ok(Box::new(self.stat(&path).await?) as Box<dyn DavMetaData>)
        }
        .boxed()
    }

    fn create_dir<'a>(&'a self, path: &'a DavPath) -> FsFuture<'a, ()> {
        async move {
            let path = path_string(path)?;
            self.node
                .fs_mkdir(self.phone, &path)
                .await
                .map_err(fs_error)?;
            self.invalidate(&path);
            Ok(())
        }
        .boxed()
    }

    fn remove_dir<'a>(&'a self, path: &'a DavPath) -> FsFuture<'a, ()> {
        self.remove_file(path)
    }

    fn remove_file<'a>(&'a self, path: &'a DavPath) -> FsFuture<'a, ()> {
        async move {
            let path = path_string(path)?;
            if files::is_mac_metadata(name_of(&path)) {
                return self
                    .local
                    .lock()
                    .unwrap()
                    .files
                    .remove(&path)
                    .map(|_| ())
                    .ok_or(FsError::NotFound);
            }
            self.node
                .fs_delete(self.phone, &path)
                .await
                .map_err(fs_error)?;
            let prefix = format!("{path}/");
            self.local
                .lock()
                .unwrap()
                .files
                .retain(|k, _| !k.starts_with(&prefix));
            self.invalidate(&path);
            Ok(())
        }
        .boxed()
    }

    fn rename<'a>(&'a self, from: &'a DavPath, to: &'a DavPath) -> FsFuture<'a, ()> {
        async move {
            let from = path_string(from)?;
            let to = path_string(to)?;
            if files::is_mac_metadata(name_of(&from)) {
                let mut local = self.local.lock().unwrap();
                let data = local.files.remove(&from).ok_or(FsError::NotFound)?;
                local.files.insert(to, data);
                return Ok(());
            }
            self.node
                .fs_rename(self.phone, &from, &to)
                .await
                .map_err(fs_error)?;
            self.invalidate(&from);
            self.invalidate(&to);
            Ok(())
        }
        .boxed()
    }

    fn copy<'a>(&'a self, from: &'a DavPath, to: &'a DavPath) -> FsFuture<'a, ()> {
        async move {
            let from = path_string(from)?;
            let to = path_string(to)?;
            let meta = self.stat(&from).await?;
            if meta.dir {
                return Err(FsError::NotImplemented);
            }
            // The phone has no copy primitive; stream the file through the Mac.
            let mut writer = self
                .node
                .fs_write(self.phone, &to, true)
                .await
                .map_err(fs_error)?;
            let mut offset = 0;
            while offset < meta.size {
                let chunk = self
                    .node
                    .fs_read(self.phone, &from, offset, COPY_CHUNK)
                    .await
                    .map_err(fs_error)?;
                if chunk.is_empty() {
                    break;
                }
                writer.write(&chunk).await.map_err(fs_error)?;
                offset += chunk.len() as u64;
            }
            writer.finish().await.map_err(fs_error)?;
            self.invalidate(&to);
            Ok(())
        }
        .boxed()
    }
}

/// A file on the phone, opened either for reading (with read-ahead) or for one sequential upload.
struct PhoneFile {
    fs: PhoneFs,
    path: String,
    pos: u64,
    // reading
    meta: Meta,
    buffer: Bytes,
    buffer_offset: u64,
    // writing
    write: bool,
    /// Size the client announced (Content-Length, or Finder's X-Expected-Entity-Length).
    expected: Option<u64>,
    truncate: bool,
    writer: Option<FsWriter>,
    written: u64,
    finished: bool,
}

impl std::fmt::Debug for PhoneFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PhoneFile")
            .field("path", &self.path)
            .field("write", &self.write)
            .finish()
    }
}

impl PhoneFile {
    fn reader(fs: PhoneFs, path: String, meta: Meta) -> Self {
        Self {
            fs,
            path,
            pos: 0,
            meta,
            buffer: Bytes::new(),
            buffer_offset: 0,
            write: false,
            expected: None,
            truncate: false,
            writer: None,
            written: 0,
            finished: false,
        }
    }

    fn writer(fs: PhoneFs, path: String, truncate: bool, expected: Option<u64>) -> Self {
        Self {
            expected,
            fs,
            path,
            pos: 0,
            meta: Meta::file(0),
            buffer: Bytes::new(),
            buffer_offset: 0,
            write: true,
            truncate,
            writer: None,
            written: 0,
            finished: false,
        }
    }

    async fn ensure_writer(&mut self) -> FsResult<()> {
        if self.writer.is_none() && !self.finished {
            let writer = self
                .fs
                .node
                .fs_write(self.fs.phone, &self.path, self.truncate)
                .await
                .map_err(fs_error)?;
            self.writer = Some(writer);
        }
        Ok(())
    }
}

impl DavFile for PhoneFile {
    fn metadata(&mut self) -> FsFuture<'_, Box<dyn DavMetaData>> {
        async move {
            let meta = if self.write {
                Meta::file(self.written)
            } else {
                self.meta.clone()
            };
            Ok(Box::new(meta) as Box<dyn DavMetaData>)
        }
        .boxed()
    }

    fn write_buf(&mut self, mut buf: Box<dyn Buf + Send>) -> FsFuture<'_, ()> {
        async move {
            let bytes = buf.copy_to_bytes(buf.remaining());
            self.write_bytes(bytes).await
        }
        .boxed()
    }

    fn write_bytes(&mut self, buf: Bytes) -> FsFuture<'_, ()> {
        async move {
            if !self.write || self.finished {
                return Err(FsError::Forbidden);
            }
            self.ensure_writer().await?;
            let writer = self.writer.as_mut().expect("writer created");
            writer.write(&buf).await.map_err(fs_error)?;
            self.written += buf.len() as u64;
            self.pos += buf.len() as u64;
            Ok(())
        }
        .boxed()
    }

    fn read_bytes(&mut self, count: usize) -> FsFuture<'_, Bytes> {
        async move {
            if self.write {
                return Err(FsError::Forbidden);
            }
            let end = self.buffer_offset + self.buffer.len() as u64;
            if self.pos < self.buffer_offset || self.pos >= end {
                if self.pos >= self.meta.size {
                    return Ok(Bytes::new());
                }
                let length = (count as u64).max(READ_AHEAD);
                let data = self
                    .fs
                    .node
                    .fs_read(self.fs.phone, &self.path, self.pos, length)
                    .await
                    .map_err(fs_error)?;
                self.buffer = Bytes::from(data);
                self.buffer_offset = self.pos;
            }
            let start = (self.pos - self.buffer_offset) as usize;
            let take = count.min(self.buffer.len() - start);
            let out = self.buffer.slice(start..start + take);
            self.pos += take as u64;
            Ok(out)
        }
        .boxed()
    }

    fn seek(&mut self, pos: SeekFrom) -> FsFuture<'_, u64> {
        async move {
            let size = if self.write {
                self.written
            } else {
                self.meta.size
            };
            let target = match pos {
                SeekFrom::Start(p) => p as i64,
                SeekFrom::End(d) => size as i64 + d,
                SeekFrom::Current(d) => self.pos as i64 + d,
            };
            if target < 0 {
                return Err(FsError::GeneralFailure);
            }
            // Uploads are strictly sequential.
            if self.write && target as u64 != self.pos {
                return Err(FsError::NotImplemented);
            }
            self.pos = target as u64;
            Ok(self.pos)
        }
        .boxed()
    }

    fn flush(&mut self) -> FsFuture<'_, ()> {
        async move {
            if !self.write || self.finished {
                return Ok(());
            }
            // A body that ended early is not the file: dropping the writer aborts the upload, so
            // the phone keeps the original.
            if self.expected.is_some_and(|size| size != self.written) {
                self.writer = None;
                self.finished = true;
                return Err(FsError::GeneralFailure);
            }
            // An empty PUT still has to create the file.
            self.ensure_writer().await?;
            let writer = self.writer.take().expect("writer created");
            self.finished = true;
            let entry = writer.finish().await.map_err(fs_error)?;
            self.written = entry.size;
            self.fs.invalidate(&self.path);
            Ok(())
        }
        .boxed()
    }
}

/// In-memory Finder metadata file.
struct MemFile {
    fs: PhoneFs,
    path: String,
    data: Vec<u8>,
    pos: usize,
    dirty: bool,
}

impl std::fmt::Debug for MemFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemFile").field("path", &self.path).finish()
    }
}

impl DavFile for MemFile {
    fn metadata(&mut self) -> FsFuture<'_, Box<dyn DavMetaData>> {
        let meta: Box<dyn DavMetaData> = Box::new(Meta::file(self.data.len() as u64));
        async move { Ok(meta) }.boxed()
    }

    fn write_buf(&mut self, mut buf: Box<dyn Buf + Send>) -> FsFuture<'_, ()> {
        let bytes = buf.copy_to_bytes(buf.remaining());
        self.write_bytes(bytes)
    }

    fn write_bytes(&mut self, buf: Bytes) -> FsFuture<'_, ()> {
        let end = match self.pos.checked_add(buf.len()) {
            Some(end) if end <= MAX_META_FILE => end,
            _ => return async move { Err(FsError::TooLarge) }.boxed(),
        };
        if self.data.len() < end {
            self.data.resize(end, 0);
        }
        self.data[self.pos..end].copy_from_slice(&buf);
        self.pos = end;
        self.dirty = true;
        async move { Ok(()) }.boxed()
    }

    fn read_bytes(&mut self, count: usize) -> FsFuture<'_, Bytes> {
        let start = self.pos.min(self.data.len());
        let end = (start + count).min(self.data.len());
        self.pos = end;
        let out = Bytes::copy_from_slice(&self.data[start..end]);
        async move { Ok(out) }.boxed()
    }

    fn seek(&mut self, pos: SeekFrom) -> FsFuture<'_, u64> {
        let target = match pos {
            SeekFrom::Start(p) => i64::try_from(p).ok(),
            SeekFrom::End(d) => (self.data.len() as i64).checked_add(d),
            SeekFrom::Current(d) => (self.pos as i64).checked_add(d),
        };
        let result = match target {
            Some(t) if t < 0 => Err(FsError::GeneralFailure),
            Some(t) if t as u64 <= MAX_META_FILE as u64 => {
                self.pos = t as usize;
                Ok(t as u64)
            }
            _ => Err(FsError::TooLarge),
        };
        async move { result }.boxed()
    }

    fn flush(&mut self) -> FsFuture<'_, ()> {
        if self.dirty {
            self.fs
                .local
                .lock()
                .unwrap()
                .files
                .insert(self.path.clone(), self.data.clone());
            self.dirty = false;
        }
        async move { Ok(()) }.boxed()
    }
}
