//! On-disk cache of scan results, so the app can show the last scan
//! instantly on startup and rescans can skip unchanged directories.

use std::fs;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use super::tree::Tree;

/// Bump whenever the serialized layout of [`Tree`] changes.
const MAGIC: &[u8; 8] = b"SPCMAN01";

/// Cache file for scans of `root` inside `cache_dir`.
pub fn file_for(cache_dir: &Path, root: &Path) -> PathBuf {
    // FNV-1a: stable across Rust versions, unlike `DefaultHasher`.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in root.as_os_str().as_encoded_bytes() {
        h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    cache_dir.join(format!("scan-{h:016x}.bin"))
}

pub fn save(file: &Path, tree: &Tree) -> anyhow::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = file.with_extension("bin.tmp");
    {
        let mut w = BufWriter::new(fs::File::create(&tmp)?);
        w.write_all(MAGIC)?;
        let mut enc = lz4_flex::frame::FrameEncoder::new(w);
        bincode::serialize_into(&mut enc, tree)?;
        enc.finish()?.flush()?;
    }
    fs::rename(tmp, file)?;
    Ok(())
}

/// Loads a cached tree, or `None` when it is missing, stale or corrupt.
pub fn load(file: &Path) -> Option<Tree> {
    let mut r = BufReader::new(fs::File::open(file).ok()?);
    let mut magic = [0u8; 8];
    r.read_exact(&mut magic).ok()?;
    if &magic != MAGIC {
        return None;
    }
    bincode::deserialize_from(lz4_flex::frame::FrameDecoder::new(r)).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::scan::{scan, scan_with_cache, ScanOptions, ScanProgress};
    use std::sync::atomic::Ordering;

    #[test]
    fn roundtrip_and_incremental_rescan() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("root");
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("a/b/big.bin"), vec![1u8; 2 * 1024 * 1024]).unwrap();
        fs::write(root.join("a/small.txt"), b"hi").unwrap();

        let tree = scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        let file = file_for(&tmp.path().join("cache"), &root);
        save(&file, &tree).unwrap();
        let loaded = load(&file).unwrap();
        assert_eq!(loaded.nodes.len(), tree.nodes.len());
        assert_eq!(loaded.root().unwrap().size, tree.root().unwrap().size);

        // Add a file in a new directory; the rescan must see it while still
        // reporting everything else from the cache.
        fs::create_dir_all(root.join("c")).unwrap();
        fs::write(root.join("c/new.bin"), vec![1u8; 3 * 1024 * 1024]).unwrap();
        let progress = ScanProgress::default();
        let again = scan_with_cache(&root, &ScanOptions::default(), &progress, Some(&loaded)).unwrap();
        assert!(again.find(&root.join("c/new.bin")).is_some());
        assert!(again.find(&root.join("a/b/big.bin")).is_some());
        assert_eq!(again.root().unwrap().file_count, 3);
        assert_eq!(progress.files.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn rejects_garbage() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("x.bin");
        fs::write(&file, b"not a cache").unwrap();
        assert!(load(&file).is_none());
    }
}
