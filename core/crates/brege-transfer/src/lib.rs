//! Verified, resumable file transfer.
//!
//! A file is split into fixed-size chunks, each hashed with BLAKE3. The root hash is
//! `BLAKE3(size_le || chunk_size_le || h_0 || … || h_n)` and travels in the `TransferOffer`.
//!
//! Wire format of a FILE stream after its `FileStreamHeader`:
//! 1. `n × 32` bytes of chunk hashes (checked against the root before any data is written);
//! 2. repeated `u32 LE chunk index` followed by that chunk's bytes, for every chunk the
//!    receiver does not already have; the sender then finishes the stream.

use std::collections::BTreeSet;
use std::io::SeekFrom;
use std::path::{Path, PathBuf};

use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt};

pub const DEFAULT_CHUNK_SIZE: u32 = 1024 * 1024;
const MAX_CHUNK_SIZE: u32 = 16 * 1024 * 1024;
/// Caps the hash list a peer can make the receiver read (8 MB), and with the default chunk size
/// the file size (256 GB).
const MAX_CHUNKS: u64 = 1 << 18;

#[derive(Debug, thiserror::Error)]
pub enum TransferError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("chunk hash list does not match the offered root hash")]
    RootMismatch,
    #[error("chunk {0} failed verification")]
    ChunkMismatch(u32),
    #[error("protocol violation: {0}")]
    Protocol(&'static str),
    #[error("the partially received file is gone")]
    PartMissing,
    #[error("transfer incomplete: {missing} chunks missing")]
    Incomplete { missing: u32 },
}

/// Size, chunking and hashes of one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub size: u64,
    pub chunk_size: u32,
    pub chunk_hashes: Vec<[u8; 32]>,
}

impl Manifest {
    pub async fn from_file(path: &Path, chunk_size: u32) -> Result<Self, TransferError> {
        validate_chunk_size(chunk_size)?;
        let mut file = File::open(path).await?;
        let size = file.metadata().await?.len();
        validate_size(size, chunk_size)?;
        let mut chunk_hashes = Vec::with_capacity(chunk_count(size, chunk_size) as usize);
        let mut buf = vec![0u8; chunk_size as usize];
        loop {
            let n = read_full(&mut file, &mut buf).await?;
            if n == 0 {
                break;
            }
            chunk_hashes.push(*blake3::hash(&buf[..n]).as_bytes());
        }
        Ok(Self {
            size,
            chunk_size,
            chunk_hashes,
        })
    }

    pub fn root(&self) -> [u8; 32] {
        root_hash(self.size, self.chunk_size, &self.chunk_hashes)
    }

    pub fn chunk_count(&self) -> u32 {
        chunk_count(self.size, self.chunk_size)
    }

    fn chunk_len(&self, index: u32) -> usize {
        let start = u64::from(index) * u64::from(self.chunk_size);
        (self.size - start).min(u64::from(self.chunk_size)) as usize
    }
}

/// The parts of a `TransferOffer` the engine needs.
#[derive(Debug, Clone)]
pub struct Offer {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub chunk_size: u32,
    pub root_hash: [u8; 32],
}

pub fn root_hash(size: u64, chunk_size: u32, chunk_hashes: &[[u8; 32]]) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(&size.to_le_bytes());
    hasher.update(&chunk_size.to_le_bytes());
    for h in chunk_hashes {
        hasher.update(h);
    }
    *hasher.finalize().as_bytes()
}

pub fn chunk_count(size: u64, chunk_size: u32) -> u32 {
    size.div_ceil(u64::from(chunk_size)) as u32
}

fn validate_chunk_size(chunk_size: u32) -> Result<(), TransferError> {
    if chunk_size == 0 || chunk_size > MAX_CHUNK_SIZE {
        return Err(TransferError::Protocol("invalid chunk size"));
    }
    Ok(())
}

fn validate_size(size: u64, chunk_size: u32) -> Result<(), TransferError> {
    if size.div_ceil(u64::from(chunk_size)) > MAX_CHUNKS {
        return Err(TransferError::Protocol("file too large"));
    }
    Ok(())
}

/// Checks the size, chunking and id of an offer from a peer.
pub fn validate_offer(offer: &Offer) -> Result<(), TransferError> {
    validate_chunk_size(offer.chunk_size)?;
    validate_size(offer.size, offer.chunk_size)?;
    if !valid_id(&offer.id) {
        return Err(TransferError::Protocol("invalid transfer id"));
    }
    Ok(())
}

/// Transfer ids name the partial file, so only plain ids are allowed (senders use random hex).
pub fn valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Where the partially received file of transfer `id` lives.
pub fn part_path(dest_dir: &Path, id: &str) -> PathBuf {
    dest_dir.join(format!(".{id}.brege-part"))
}

/// Sends the hash list and every chunk not in `have`. Does not finish the stream.
pub async fn send_file<W: AsyncWrite + Unpin>(
    out: &mut W,
    path: &Path,
    manifest: &Manifest,
    have: &BTreeSet<u32>,
    mut on_progress: impl FnMut(u64),
) -> Result<(), TransferError> {
    let mut hashes = Vec::with_capacity(manifest.chunk_hashes.len() * 32);
    manifest
        .chunk_hashes
        .iter()
        .for_each(|h| hashes.extend_from_slice(h));
    out.write_all(&hashes).await?;

    let mut file = File::open(path).await?;
    let mut buf = vec![0u8; manifest.chunk_size as usize];
    let mut sent = 0u64;
    for index in 0..manifest.chunk_count() {
        let len = manifest.chunk_len(index);
        if have.contains(&index) {
            continue;
        }
        file.seek(SeekFrom::Start(
            u64::from(index) * u64::from(manifest.chunk_size),
        ))
        .await?;
        file.read_exact(&mut buf[..len]).await?;
        if *blake3::hash(&buf[..len]).as_bytes() != manifest.chunk_hashes[index as usize] {
            // The file changed after the offer was made.
            return Err(TransferError::ChunkMismatch(index));
        }
        out.write_all(&index.to_le_bytes()).await?;
        out.write_all(&buf[..len]).await?;
        sent += len as u64;
        on_progress(sent);
    }
    out.flush().await?;
    Ok(())
}

/// Receiver-side state for one transfer; survives restarts via `have`.
#[derive(Debug)]
pub struct Receiver {
    offer: Offer,
    dest_dir: PathBuf,
    have: BTreeSet<u32>,
}

impl Receiver {
    /// `have` are chunk indices already verified in a previous attempt (from the store).
    pub fn new(
        offer: Offer,
        dest_dir: PathBuf,
        have: BTreeSet<u32>,
    ) -> Result<Self, TransferError> {
        validate_offer(&offer)?;
        Ok(Self {
            offer,
            dest_dir,
            have,
        })
    }

    pub fn have(&self) -> &BTreeSet<u32> {
        &self.have
    }

    pub fn part_path(&self) -> PathBuf {
        part_path(&self.dest_dir, &self.offer.id)
    }

    /// Reads a FILE stream to its end, writing verified chunks into the part file.
    /// `on_chunk` is called after each chunk is durably written, so callers can persist resume state.
    pub async fn receive<R: AsyncRead + Unpin>(
        &mut self,
        input: &mut R,
        mut on_chunk: impl FnMut(u32, u64),
    ) -> Result<(), TransferError> {
        let count = chunk_count(self.offer.size, self.offer.chunk_size);
        let mut hash_bytes = vec![0u8; count as usize * 32];
        input.read_exact(&mut hash_bytes).await?;
        let hashes: Vec<[u8; 32]> = hash_bytes.as_chunks::<32>().0.to_vec();
        if root_hash(self.offer.size, self.offer.chunk_size, &hashes) != self.offer.root_hash {
            return Err(TransferError::RootMismatch);
        }
        let manifest = Manifest {
            size: self.offer.size,
            chunk_size: self.offer.chunk_size,
            chunk_hashes: hashes,
        };

        tokio::fs::create_dir_all(&self.dest_dir).await?;
        // Chunks from an earlier attempt are only still there if the partial file is.
        if !self.have.is_empty()
            && !tokio::fs::try_exists(self.part_path())
                .await
                .unwrap_or(false)
        {
            return Err(TransferError::PartMissing);
        }
        let mut part = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(self.part_path())
            .await?;
        part.set_len(self.offer.size).await?;

        let mut buf = vec![0u8; self.offer.chunk_size as usize];
        let mut index_bytes = [0u8; 4];
        let mut received = 0u64;
        loop {
            match input.read_exact(&mut index_bytes).await {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(e.into()),
            }
            let index = u32::from_le_bytes(index_bytes);
            if index >= count {
                return Err(TransferError::Protocol("chunk index out of range"));
            }
            let len = manifest.chunk_len(index);
            input.read_exact(&mut buf[..len]).await?;
            if *blake3::hash(&buf[..len]).as_bytes() != manifest.chunk_hashes[index as usize] {
                return Err(TransferError::ChunkMismatch(index));
            }
            part.seek(SeekFrom::Start(
                u64::from(index) * u64::from(self.offer.chunk_size),
            ))
            .await?;
            part.write_all(&buf[..len]).await?;
            part.sync_data().await?;
            self.have.insert(index);
            received += len as u64;
            on_chunk(index, received);
        }
        Ok(())
    }

    /// Renames the part file into place once every chunk is verified. Returns the final path.
    pub async fn finish(self) -> Result<PathBuf, TransferError> {
        let count = chunk_count(self.offer.size, self.offer.chunk_size);
        let missing = count.saturating_sub(self.have.len() as u32);
        if missing > 0 {
            return Err(TransferError::Incomplete { missing });
        }
        if count == 0 {
            // Empty file: `receive` may not have created the part file.
            tokio::fs::create_dir_all(&self.dest_dir).await?;
            File::create(self.part_path()).await?;
        }
        let dest = unique_destination(&self.dest_dir, &self.offer.name).await;
        tokio::fs::rename(self.part_path(), &dest).await?;
        Ok(dest)
    }
}

/// Strips path components and control characters from a peer-supplied file name.
pub fn sanitize_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let cleaned: String = base
        .chars()
        .filter(|c| !c.is_control() && *c != ':')
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.').to_string();
    if cleaned.is_empty() {
        "file".to_string()
    } else {
        cleaned
    }
}

async fn unique_destination(dir: &Path, name: &str) -> PathBuf {
    let name = sanitize_file_name(name);
    let candidate = dir.join(&name);
    if !tokio::fs::try_exists(&candidate).await.unwrap_or(false) {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
        _ => (name.clone(), String::new()),
    };
    for n in 1.. {
        let candidate = dir.join(format!("{stem} ({n}){ext}"));
        if !tokio::fs::try_exists(&candidate).await.unwrap_or(false) {
            return candidate;
        }
    }
    unreachable!()
}

async fn read_full(file: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = file.read(&mut buf[filled..]).await?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_names() {
        assert_eq!(sanitize_file_name("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_file_name("C:\\Users\\x\\photo.jpg"), "photo.jpg");
        assert_eq!(sanitize_file_name(".hidden"), "hidden");
        assert_eq!(sanitize_file_name("  "), "file");
        assert_eq!(sanitize_file_name("a\u{0}b.txt"), "ab.txt");
    }

    #[test]
    fn rejects_unsafe_offers() {
        let offer = |id: &str, size: u64, chunk_size: u32| Offer {
            id: id.into(),
            name: "x".into(),
            size,
            chunk_size,
            root_hash: [0; 32],
        };
        assert!(validate_offer(&offer("0123abcd", 10, 4)).is_ok());
        assert!(validate_offer(&offer("/../escaped", 10, 4)).is_err());
        assert!(validate_offer(&offer("", 10, 4)).is_err());
        assert!(validate_offer(&offer("a.b", 10, 4)).is_err());
        assert!(validate_offer(&offer("ok", (1 << 32) * 4 + 4, 4)).is_err());
        assert!(validate_offer(&offer("ok", u64::MAX, 1)).is_err());
    }

    #[tokio::test]
    async fn missing_part_file_is_not_filled_with_zeros() {
        let dir = std::env::temp_dir().join(format!("brege-part-{}", std::process::id()));
        let data = b"AAAABBBB";
        let hashes = [
            *blake3::hash(b"AAAA").as_bytes(),
            *blake3::hash(b"BBBB").as_bytes(),
        ];
        let offer = Offer {
            id: "resume".into(),
            name: "x.bin".into(),
            size: data.len() as u64,
            chunk_size: 4,
            root_hash: root_hash(8, 4, &hashes),
        };
        let mut receiver = Receiver::new(offer, dir.clone(), BTreeSet::from([0])).unwrap();
        let mut stream = hashes.concat();
        stream.extend_from_slice(&1u32.to_le_bytes());
        stream.extend_from_slice(b"BBBB");
        let result = receiver.receive(&mut stream.as_slice(), |_, _| {}).await;
        assert!(matches!(result, Err(TransferError::PartMissing)));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn chunk_counts() {
        assert_eq!(chunk_count(0, 4), 0);
        assert_eq!(chunk_count(4, 4), 1);
        assert_eq!(chunk_count(5, 4), 2);
    }
}
