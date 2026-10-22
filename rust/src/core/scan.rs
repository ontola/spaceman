//! Parallel filesystem scanner.
//!
//! Walks a directory tree using rayon's work-stealing pool, measuring the
//! space each entry actually occupies on disk. Symlinks are never followed,
//! other filesystems (mount points) are skipped and hard-linked files are
//! only counted once.
//!
//! When a previous scan of the same root is available, directories whose
//! modification stamp has not changed reuse their cached file listing, so
//! a rescan only has to `stat` directories instead of every file. Changes
//! to a file's size that do not touch its directory (e.g. a growing log
//! file) are only picked up by a full scan.

use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use rayon::prelude::*;

use super::tree::{Node, NodeId, NodeKind, Tree};

#[derive(Debug, Clone)]
pub struct ScanOptions {
    /// Files smaller than this are folded into one aggregate entry per directory.
    pub min_file_size: u64,
    /// Stay on the filesystem of the root directory.
    pub same_filesystem: bool,
    /// Directories not to enter, e.g. privacy-protected folders that would
    /// make macOS show a permission prompt.
    pub skip: Vec<PathBuf>,
}

impl Default for ScanOptions {
    fn default() -> Self {
        Self { min_file_size: 1024 * 1024, same_filesystem: true, skip: Vec::new() }
    }
}

/// Live counters, readable from another thread while a scan runs.
#[derive(Debug, Default)]
pub struct ScanProgress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    pub cancel: AtomicBool,
}

#[derive(Debug, thiserror::Error)]
pub enum ScanError {
    #[error("cannot read {0}: {1}")]
    Root(PathBuf, std::io::Error),
    #[error("{0} is not a directory")]
    NotADirectory(PathBuf),
}

struct Ctx<'a> {
    opts: &'a ScanOptions,
    progress: &'a ScanProgress,
    root_dev: u64,
    /// Hard-linked files already counted. Windows has no cheap inode, so
    /// hard links are counted per link there.
    #[cfg(unix)]
    seen_inodes: std::sync::Mutex<std::collections::HashSet<(u64, u64)>>,
    previous: Option<&'a Tree>,
    /// Directories whose skipped children differ from the previous scan;
    /// their cached listing is incomplete or too big, so read them again.
    skip_changed: Vec<PathBuf>,
}

/// Intermediate owned tree, built in parallel and flattened afterwards.
struct DirTree {
    name: Box<str>,
    modified: i64,
    stamp: u64,
    size: u64,
    file_count: u64,
    files: Vec<(Box<str>, u64, i64)>,
    small_size: u64,
    small_count: u64,
    dirs: Vec<DirTree>,
}

pub fn scan(root: &Path, opts: &ScanOptions, progress: &ScanProgress) -> Result<Tree, ScanError> {
    scan_with_cache(root, opts, progress, None)
}

/// Like [`scan`], but reuses unchanged directories from `previous`.
pub fn scan_with_cache(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    previous: Option<&Tree>,
) -> Result<Tree, ScanError> {
    let meta = fs::symlink_metadata(root).map_err(|e| ScanError::Root(root.to_path_buf(), e))?;
    if !meta.is_dir() {
        return Err(ScanError::NotADirectory(root.to_path_buf()));
    }
    let ctx = Ctx {
        opts,
        progress,
        root_dev: device(&meta),
        #[cfg(unix)]
        seen_inodes: Default::default(),
        previous: previous.filter(|p| p.root_path == root && p.root().is_some()),
        skip_changed: previous
            .map(|p| {
                p.skipped
                    .iter()
                    .filter(|d| !opts.skip.contains(d))
                    .chain(opts.skip.iter().filter(|d| !p.skipped.contains(d)))
                    .filter_map(|d| d.parent().map(Path::to_path_buf))
                    .collect()
            })
            .unwrap_or_default(),
    };
    let cached = ctx.previous.map(|_| Tree::ROOT);
    let dir = walk(root, String::new().into_boxed_str(), &meta, cached, &ctx);
    let scanned_at = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut tree = Tree {
        root_path: root.to_path_buf(),
        scanned_at,
        skipped: opts.skip.clone(),
        partial: progress.cancel.load(Ordering::Relaxed),
        nodes: Vec::new(),
    };
    flatten(dir, None, &mut tree);
    Ok(tree)
}

fn walk(path: &Path, name: Box<str>, meta: &Metadata, cached: Option<NodeId>, ctx: &Ctx) -> DirTree {
    let mut out = DirTree {
        name,
        modified: mtime(meta),
        stamp: stamp(meta),
        size: disk_size(meta),
        file_count: 0,
        files: Vec::new(),
        small_size: 0,
        small_count: 0,
        dirs: Vec::new(),
    };
    ctx.progress.dirs.fetch_add(1, Ordering::Relaxed);
    if cancelled(ctx) {
        // Not read: make sure the next scan reads it instead of trusting
        // this empty listing.
        out.stamp = 0;
        return out;
    }

    let subdirs = match (ctx.previous, cached) {
        (Some(prev), Some(id))
            if out.stamp != 0
                && prev.nodes[id as usize].stamp == out.stamp
                && !ctx.skip_changed.iter().any(|d| d == path) =>
        {
            reuse_listing(path, prev, id, &mut out, ctx)
        }
        _ => read_listing(path, &mut out, ctx),
    };

    out.dirs = subdirs
        .into_par_iter()
        .map(|(p, n, m, c)| walk(&p, n, &m, c, ctx))
        .collect();
    for d in &out.dirs {
        out.size += d.size;
        out.file_count += d.file_count;
    }
    out
}

type Subdir = (PathBuf, Box<str>, Metadata, Option<NodeId>);

/// Lists a directory from disk, recording its files in `out` and returning
/// the subdirectories to descend into.
fn cancelled(ctx: &Ctx) -> bool {
    ctx.progress.cancel.load(Ordering::Relaxed)
}

fn read_listing(path: &Path, out: &mut DirTree, ctx: &Ctx) -> Vec<Subdir> {
    let entries = match fs::read_dir(path) {
        Ok(e) => e,
        Err(_) => {
            ctx.progress.errors.fetch_add(1, Ordering::Relaxed);
            return Vec::new();
        }
    };
    // Cached children by name, so changed directories can still reuse
    // their unchanged subdirectories.
    let cached_dirs = cached_subdirs(ctx, path);

    let mut subdirs = Vec::new();
    for entry in entries.flatten() {
        if cancelled(ctx) {
            out.stamp = 0;
            break;
        }
        // symlink_metadata: never follow links.
        let Ok(meta) = entry.path().symlink_metadata() else {
            ctx.progress.errors.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        let name: Box<str> = entry.file_name().to_string_lossy().into();
        let ft = meta.file_type();
        if ft.is_dir() {
            if ctx.opts.same_filesystem && device(&meta) != ctx.root_dev {
                continue;
            }
            if !ctx.opts.skip.is_empty() && ctx.opts.skip.contains(&entry.path()) {
                continue;
            }
            let cached = cached_dirs.as_ref().and_then(|m| m.get(&*name).copied());
            subdirs.push((entry.path(), name, meta, cached));
        } else if ft.is_symlink() {
            continue;
        } else {
            if is_duplicate_hardlink(&meta, ctx) {
                continue;
            }
            add_file(out, name, disk_size(&meta), mtime(&meta), ctx);
        }
    }
    subdirs
}

/// Takes the file listing of an unchanged directory from the cache. Its
/// subdirectories are still visited, since their contents may have changed.
fn reuse_listing(path: &Path, prev: &Tree, id: NodeId, out: &mut DirTree, ctx: &Ctx) -> Vec<Subdir> {
    let mut subdirs = Vec::new();
    for &c in &prev.nodes[id as usize].children {
        if cancelled(ctx) {
            out.stamp = 0;
            break;
        }
        let n = &prev.nodes[c as usize];
        if n.removed {
            continue;
        }
        match n.kind {
            NodeKind::File => add_file(out, n.name.clone(), n.size, n.modified, ctx),
            NodeKind::Aggregate => {
                ctx.progress.files.fetch_add(n.file_count, Ordering::Relaxed);
                ctx.progress.bytes.fetch_add(n.size, Ordering::Relaxed);
                out.size += n.size;
                out.file_count += n.file_count;
                out.small_size += n.size;
                out.small_count += n.file_count;
            }
            NodeKind::Dir => {
                let p = path.join(&*n.name);
                // Removed after the last scan (e.g. moved to trash by us).
                let Ok(meta) = p.symlink_metadata() else { continue };
                if meta.is_dir() {
                    subdirs.push((p, n.name.clone(), meta, Some(c)));
                }
            }
        }
    }
    subdirs
}

fn add_file(out: &mut DirTree, name: Box<str>, size: u64, modified: i64, ctx: &Ctx) {
    ctx.progress.files.fetch_add(1, Ordering::Relaxed);
    ctx.progress.bytes.fetch_add(size, Ordering::Relaxed);
    out.size += size;
    out.file_count += 1;
    if size >= ctx.opts.min_file_size {
        out.files.push((name, size, modified));
    } else {
        out.small_size += size;
        out.small_count += 1;
    }
}

fn cached_subdirs<'a>(ctx: &Ctx<'a>, path: &Path) -> Option<std::collections::HashMap<&'a str, NodeId>> {
    let prev = ctx.previous?;
    let id = prev.find(path)?;
    Some(
        prev.nodes[id as usize]
            .children
            .iter()
            .filter(|c| prev.nodes[**c as usize].kind == NodeKind::Dir && !prev.nodes[**c as usize].removed)
            .map(|c| (&*prev.nodes[*c as usize].name, *c))
            .collect(),
    )
}

fn flatten(dir: DirTree, parent: Option<u32>, tree: &mut Tree) -> u32 {
    let id = tree.nodes.len() as u32;
    tree.nodes.push(Node {
        name: dir.name,
        parent,
        kind: NodeKind::Dir,
        size: dir.size,
        file_count: dir.file_count,
        modified: dir.modified,
        stamp: dir.stamp,
        children: Vec::with_capacity(dir.dirs.len() + dir.files.len() + 1),
        removed: false,
    });
    let mut children = Vec::with_capacity(dir.dirs.len() + dir.files.len() + 1);
    for (name, size, modified) in dir.files {
        children.push(tree.nodes.len() as u32);
        tree.nodes.push(Node {
            name,
            parent: Some(id),
            kind: NodeKind::File,
            size,
            file_count: 1,
            modified,
            stamp: 0,
            children: Vec::new(),
            removed: false,
        });
    }
    if dir.small_count > 0 {
        children.push(tree.nodes.len() as u32);
        tree.nodes.push(Node {
            name: format!("{} smaller files", dir.small_count).into(),
            parent: Some(id),
            kind: NodeKind::Aggregate,
            size: dir.small_size,
            file_count: dir.small_count,
            modified: 0,
            stamp: 0,
            children: Vec::new(),
            removed: false,
        });
    }
    for sub in dir.dirs {
        children.push(flatten(sub, Some(id), tree));
    }
    tree.nodes[id as usize].children = children;
    id
}

fn mtime(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn stamp(meta: &Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

#[cfg(unix)]
fn disk_size(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    // st_blocks is always in 512-byte units. This reflects sparse and
    // compressed files correctly, unlike the apparent length.
    meta.blocks() * 512
}

#[cfg(not(unix))]
fn disk_size(meta: &Metadata) -> u64 {
    meta.len()
}

#[cfg(unix)]
fn device(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.dev()
}

#[cfg(not(unix))]
fn device(_meta: &Metadata) -> u64 {
    0
}

#[cfg(unix)]
fn is_duplicate_hardlink(meta: &Metadata, ctx: &Ctx) -> bool {
    use std::os::unix::fs::MetadataExt;
    if meta.nlink() <= 1 {
        return false;
    }
    !ctx.seen_inodes.lock().unwrap().insert((meta.dev(), meta.ino()))
}

#[cfg(not(unix))]
fn is_duplicate_hardlink(_meta: &Metadata, _ctx: &Ctx) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![1u8; bytes]).unwrap();
    }

    #[test]
    fn scans_sizes_and_structure() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("a/big.bin"), 2 * 1024 * 1024);
        write(&root.join("a/small.txt"), 10);
        write(&root.join("b/c/tiny.txt"), 10);

        let progress = ScanProgress::default();
        let tree = scan(root, &ScanOptions::default(), &progress).unwrap();
        let r = tree.root().unwrap();
        assert_eq!(r.file_count, 3);
        assert!(r.size >= 2 * 1024 * 1024);

        let a = tree.find(&root.join("a")).unwrap();
        let big = tree.find(&root.join("a/big.bin")).unwrap();
        assert_eq!(tree.get(big).unwrap().kind, NodeKind::File);
        // small.txt is folded into an aggregate entry.
        assert!(tree.find(&root.join("a/small.txt")).is_none());
        let kinds: Vec<_> = tree.get(a).unwrap().children.iter().map(|c| tree.nodes[*c as usize].kind).collect();
        assert!(kinds.contains(&NodeKind::Aggregate));
        assert_eq!(tree.path(big), root.join("a/big.bin"));
        assert_eq!(progress.files.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn remove_updates_ancestors() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("x/y/big.bin"), 2 * 1024 * 1024);
        let mut tree = scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        let before = tree.root().unwrap().size;
        let y = tree.find(&root.join("x/y")).unwrap();
        let y_size = tree.get(y).unwrap().size;
        tree.remove(y);
        assert_eq!(tree.root().unwrap().size, before - y_size);
        assert!(tree.find(&root.join("x/y")).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_followed() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("real/big.bin"), 2 * 1024 * 1024);
        std::os::unix::fs::symlink(root.join("real"), root.join("link")).unwrap();
        let tree = scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        assert_eq!(tree.root().unwrap().file_count, 1);
        assert!(tree.find(&root.join("link")).is_none());
    }
}
