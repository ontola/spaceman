//! On-disk cache of scan results, so the app can show the last scan
//! instantly on startup and rescans can skip unchanged directories.

use std::fs;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use super::tree::Tree;

/// Bump whenever the serialized layout of [`Tree`] changes.
const MAGIC: &[u8; 8] = b"SPCMAN03";

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
    // Unique per writer, so two saves in parallel never share a temp file.
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = file.with_extension(format!("{}-{seq}.tmp", std::process::id()));
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
    fn changed_skip_list_rereads_only_affected_folders() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        fs::create_dir_all(root.join("private")).unwrap();
        fs::write(root.join("private/big.bin"), vec![1u8; 2 * 1024 * 1024]).unwrap();

        let limited = ScanOptions { skip: vec![root.join("private")], ..Default::default() };
        let first = scan_with_cache(&root, &limited, &ScanProgress::default(), None).unwrap();
        assert!(first.find(&root.join("private")).is_none());

        // Now with full access: the skipped folder must show up, even though
        // the root directory itself did not change.
        let full = scan_with_cache(&root, &ScanOptions::default(), &ScanProgress::default(), Some(&first)).unwrap();
        assert!(full.find(&root.join("private/big.bin")).is_some());

        // And back: the folder is left out again.
        let again = scan_with_cache(&root, &limited, &ScanProgress::default(), Some(&full)).unwrap();
        assert!(again.find(&root.join("private")).is_none());
    }

    #[test]
    fn stopped_scan_is_partial_and_completed_next_time() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::write(root.join("a/big.bin"), vec![1u8; 2 * 1024 * 1024]).unwrap();

        let stopped = ScanProgress::default();
        stopped.cancel.store(true, Ordering::Relaxed);
        let partial = scan_with_cache(&root, &ScanOptions::default(), &stopped, None).unwrap();
        assert!(partial.partial);
        assert_eq!(partial.root().unwrap().file_count, 0);

        let full = scan_with_cache(&root, &ScanOptions::default(), &ScanProgress::default(), Some(&partial)).unwrap();
        assert!(!full.partial);
        assert!(full.find(&root.join("a/big.bin")).is_some());
    }

    #[test]
    fn rejects_garbage() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("x.bin");
        fs::write(&file, b"not a cache").unwrap();
        assert!(load(&file).is_none());
    }
}
