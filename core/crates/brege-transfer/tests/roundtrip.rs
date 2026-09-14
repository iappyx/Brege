use std::collections::BTreeSet;
use std::path::Path;

use brege_transfer::{Manifest, Offer, Receiver, TransferError, send_file};
use tokio::io::AsyncWriteExt;

const CHUNK: u32 = 64 * 1024;

fn data(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i * 31 % 251) as u8).collect()
}

async fn offer_for(path: &Path, name: &str) -> (Manifest, Offer) {
    let manifest = Manifest::from_file(path, CHUNK).await.unwrap();
    let offer = Offer {
        id: "t1".into(),
        name: name.into(),
        size: manifest.size,
        chunk_size: CHUNK,
        root_hash: manifest.root(),
    };
    (manifest, offer)
}

async fn run(src: &Path, manifest: &Manifest, rx: &mut Receiver) -> Result<(), TransferError> {
    let (mut a, mut b) = tokio::io::duplex(256 * 1024);
    let have = rx.have().clone();
    let send = async {
        send_file(&mut a, src, manifest, &have, |_| {}).await?;
        a.shutdown().await?;
        drop(a);
        Ok::<_, TransferError>(())
    };
    let (s, r) = tokio::join!(send, rx.receive(&mut b, |_, _| {}));
    s?;
    r
}

#[tokio::test]
async fn transfers_and_verifies_file() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src.bin");
    let bytes = data(CHUNK as usize * 3 + 123);
    tokio::fs::write(&src, &bytes).await.unwrap();
    let (manifest, offer) = offer_for(&src, "../photo.bin").await;

    let dest = dir.path().join("out");
    let mut rx = Receiver::new(offer, dest.clone(), BTreeSet::new()).unwrap();
    run(&src, &manifest, &mut rx).await.unwrap();
    let path = rx.finish().await.unwrap();
    assert_eq!(path, dest.join("photo.bin"));
    assert_eq!(tokio::fs::read(&path).await.unwrap(), bytes);
}

#[tokio::test]
async fn resumes_from_verified_chunks_and_dedupes_names() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src.bin");
    let bytes = data(CHUNK as usize * 4);
    tokio::fs::write(&src, &bytes).await.unwrap();
    let (manifest, offer) = offer_for(&src, "doc.pdf").await;
    let dest = dir.path().join("out");
    tokio::fs::create_dir_all(&dest).await.unwrap();
    tokio::fs::write(dest.join("doc.pdf"), b"existing")
        .await
        .unwrap();

    // A previous attempt left chunks 1 and 3 in the partial file; the sender only has to
    // deliver chunks 0 and 2.
    let mut earlier = bytes.clone();
    earlier[..CHUNK as usize].fill(0);
    earlier[CHUNK as usize * 2..CHUNK as usize * 3].fill(0);
    tokio::fs::write(brege_transfer::part_path(&dest, &offer.id), &earlier)
        .await
        .unwrap();
    let mut rx = Receiver::new(offer.clone(), dest.clone(), [1, 3].into()).unwrap();
    run(&src, &manifest, &mut rx).await.unwrap();
    assert_eq!(rx.have().len(), 4);
    let path = rx.finish().await.unwrap();
    assert_eq!(path, dest.join("doc (1).pdf"));
    assert_eq!(tokio::fs::read(&path).await.unwrap(), bytes);
}

#[tokio::test]
async fn rejects_wrong_root_and_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src.bin");
    tokio::fs::write(&src, data(CHUNK as usize + 5))
        .await
        .unwrap();
    let (manifest, mut offer) = offer_for(&src, "x").await;
    offer.root_hash[0] ^= 1;
    let mut rx = Receiver::new(offer.clone(), dir.path().join("out"), BTreeSet::new()).unwrap();
    assert!(matches!(
        run(&src, &manifest, &mut rx).await,
        Err(TransferError::RootMismatch)
    ));

    offer.root_hash[0] ^= 1;
    let rx = Receiver::new(offer, dir.path().join("out"), [0].into()).unwrap();
    assert!(matches!(
        rx.finish().await,
        Err(TransferError::Incomplete { missing: 1 })
    ));
}

#[tokio::test]
async fn empty_file() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("empty");
    tokio::fs::write(&src, b"").await.unwrap();
    let (manifest, offer) = offer_for(&src, "empty.txt").await;
    let mut rx = Receiver::new(offer, dir.path().join("out"), BTreeSet::new()).unwrap();
    run(&src, &manifest, &mut rx).await.unwrap();
    let path = rx.finish().await.unwrap();
    assert_eq!(tokio::fs::read(path).await.unwrap().len(), 0);
}
