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
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use rayon::prelude::*;

use super::live::{self, LiveNode, LiveTree};
use super::tree::{unix_now, Node, NodeId, NodeKind, Tree};

#[derive(Debug, Clone)]
pub struct ScanOptions {
    /// Files smaller than this are folded into one aggregate entry per directory.
    pub min_file_size: u64,
    /// Stay on the filesystem of the root directory.
    pub same_filesystem: bool,
    /// Directories not to enter, e.g. privacy-protected folders that would
    /// make macOS show a permission prompt.
    pub skip: Vec<PathBuf>,
    /// Keep a live view of the top folders in [`ScanProgress::live`].
    pub live: bool,
}

impl Default for ScanOptions {
    fn default() -> Self {
        Self { min_file_size: 1024 * 1024, same_filesystem: true, skip: Vec::new(), live: false }
    }
}

/// Live counters, readable from another thread while a scan runs.
#[derive(Debug, Default)]
pub struct ScanProgress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    /// Folders that could not be listed, up to [`MAX_UNREADABLE`].
    pub unreadable: std::sync::Mutex<Vec<PathBuf>>,
    pub cancel: AtomicBool,
    /// The scan so far, when [`ScanOptions::live`] is set.
    pub live: LiveTree,
}

/// How many unreadable folders a scan remembers by path.
pub const MAX_UNREADABLE: usize = 200;

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
    let at = Place { depth: 0, live: None };
    let dir = walk(root, String::new().into_boxed_str(), &meta, cached, &at, &ctx);
    let mut tree = Tree {
        root_path: root.to_path_buf(),
        scanned_at: unix_now(),
        skipped: opts.skip.clone(),
        partial: progress.cancel.load(Ordering::Relaxed),
        unreadable: {
            let mut u = progress.unreadable.lock().unwrap().clone();
            u.sort();
            u
        },
        nodes: Vec::new(),
    };
    flatten(dir, None, &mut tree);
    Ok(tree)
}

/// Where a directory sits: its depth, and the live node its sizes count
/// towards (its own or the nearest ancestor's).
struct Place<'a> {
    depth: usize,
    live: Option<&'a Arc<LiveNode>>,
}

fn walk(path: &Path, name: Box<str>, meta: &Metadata, cached: Option<NodeId>, at: &Place, ctx: &Ctx) -> DirTree {
    let own_live = (ctx.opts.live && at.depth <= live::DEPTH).then(|| ctx.progress.live.add(at.live, name.clone()));
    let live = own_live.as_ref().or(at.live);
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
    let out = walk_inner(path, out, cached, live, at.depth, ctx);
    if let Some(n) = own_live {
        n.done.store(true, Ordering::Relaxed);
    }
    out
}

fn walk_inner(
    path: &Path,
    mut out: DirTree,
    cached: Option<NodeId>,
    live: Option<&Arc<LiveNode>>,
    depth: usize,
    ctx: &Ctx,
) -> DirTree {
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

    if let Some(l) = live {
        l.own_bytes.fetch_add(out.size, Ordering::Relaxed);
        l.own_files.fetch_add(out.file_count, Ordering::Relaxed);
    }
    let at = Place { depth: depth + 1, live };
    out.dirs = subdirs
        .into_par_iter()
        .map(|(p, n, m, c)| walk(&p, n, &m, c, &at, ctx))
        .collect();
    for d in &out.dirs {
        out.size += d.size;
        out.file_count += d.file_count;
    }
    out
}

/// A subdirectory still to visit: its path, name, metadata and the node
/// for it in the previous scan, if any.
type Subdir = (PathBuf, Box<str>, Metadata, Option<NodeId>);

fn cancelled(ctx: &Ctx) -> bool {
    ctx.progress.cancel.load(Ordering::Relaxed)
}

/// Lists a directory from disk, recording its files in `out` and returning
/// the subdirectories to descend into.
fn read_listing(path: &Path, out: &mut DirTree, ctx: &Ctx) -> Vec<Subdir> {
    let entries = match fs::read_dir(path) {
        Ok(e) => e,
        Err(_) => {
            ctx.progress.errors.fetch_add(1, Ordering::Relaxed);
            let mut unreadable = ctx.progress.unreadable.lock().unwrap();
            if unreadable.len() < MAX_UNREADABLE {
                unreadable.push(path.to_path_buf());
            }
            // No stamp: never reuse this empty listing, so the next scan
            // tries (and reports) it again.
            out.stamp = 0;
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
        // Never follows links. On Windows this comes straight from the
        // directory listing, so files don't have to be opened one by one.
        let Ok(meta) = entry.metadata() else {
            ctx.progress.errors.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        let name: Box<str> = entry.file_name().to_string_lossy().into();
        let ft = meta.file_type();
        if ft.is_dir() {
            // NTFS updates a folder's timestamps in its parent's listing
            // lazily, and rescans trust them. Ask the folder itself.
            #[cfg(windows)]
            let Ok(meta) = entry.path().symlink_metadata() else {
                ctx.progress.errors.fetch_add(1, Ordering::Relaxed);
                continue;
            };
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

/// Appends `dir` and everything below it to `tree`; returns its id.
fn flatten(dir: DirTree, parent: Option<NodeId>, tree: &mut Tree) -> NodeId {
    let id = tree.nodes.len() as NodeId;
    tree.nodes.push(Node {
        name: dir.name,
        parent,
        kind: NodeKind::Dir,
        size: dir.size,
        file_count: dir.file_count,
        modified: dir.modified,
        stamp: dir.stamp,
        // Filled in below, once the children have their ids.
        children: Vec::new(),
        removed: false,
    });
    let mut children = Vec::with_capacity(dir.dirs.len() + dir.files.len() + 1);
    for (name, size, modified) in dir.files {
        children.push(tree.nodes.len() as NodeId);
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
        children.push(tree.nodes.len() as NodeId);
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

fn since_epoch(meta: &Metadata) -> Option<std::time::Duration> {
    meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()
}

/// Modification time in seconds, 0 when unknown.
fn mtime(meta: &Metadata) -> i64 {
    since_epoch(meta).map_or(0, |d| d.as_secs() as i64)
}

/// Modification time in nanoseconds, 0 when unknown.
fn stamp(meta: &Metadata) -> u64 {
    since_epoch(meta).map_or(0, |d| d.as_nanos() as u64)
}

#[cfg(unix)]
fn disk_size(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    // st_blocks is always in 512-byte units. This reflects sparse and
    // compressed files correctly, unlike the apparent length.
    meta.blocks() * 512
}

#[cfg(windows)]
fn disk_size(meta: &Metadata) -> u64 {
    use std::os::windows::fs::MetadataExt;
    const OFFLINE: u32 = 0x1000;
    const RECALL_ON_OPEN: u32 = 0x4_0000;
    const RECALL_ON_DATA_ACCESS: u32 = 0x40_0000;
    // Cloud files (OneDrive, Dropbox, ...) that are not downloaded take
    // no space on this disk.
    if meta.file_attributes() & (OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS) != 0 {
        return 0;
    }
    // Whole 4 KiB clusters, like "Size on disk" in Explorer.
    meta.len().next_multiple_of(4096)
}

#[cfg(not(any(unix, windows)))]
fn disk_size(meta: &Metadata) -> u64 {
    meta.len()
}

#[cfg(unix)]
fn device(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.dev()
}

/// Windows mounts other volumes on folders as reparse points, which the
/// scan skips like links, so everything it enters is on one volume.
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

    #[test]
    fn root_must_be_a_readable_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("f");
        write(&file, 1);
        let p = ScanProgress::default();
        assert!(matches!(scan(&file, &ScanOptions::default(), &p), Err(ScanError::NotADirectory(_))));
        let missing = tmp.path().join("missing");
        let err = scan(&missing, &ScanOptions::default(), &p).unwrap_err();
        assert!(matches!(err, ScanError::Root(..)));
        assert!(err.to_string().starts_with("cannot read "));
    }

    #[test]
    fn skipped_folders_are_left_out_and_remembered() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("private/x"), 10);
        write(&root.join("public/y"), 10);
        let opts = ScanOptions { skip: vec![root.join("private")], ..Default::default() };
        let tree = scan(root, &opts, &ScanProgress::default()).unwrap();
        assert!(tree.find(&root.join("private")).is_none());
        assert!(tree.find(&root.join("public")).is_some());
        assert_eq!(tree.skipped, vec![root.join("private")]);
        assert_eq!(tree.root().unwrap().file_count, 1);
    }

    #[test]
    fn min_file_size_decides_what_is_listed() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("a.txt"), 10);
        write(&root.join("b.txt"), 10);
        let opts = ScanOptions { min_file_size: 0, ..Default::default() };
        let tree = scan(root, &opts, &ScanProgress::default()).unwrap();
        assert!(tree.find(&root.join("a.txt")).is_some());
        let kids = tree.sorted_children(Tree::ROOT);
        assert!(kids.iter().all(|c| tree.nodes[*c as usize].kind == NodeKind::File));

        // With the default, both go into one bucket named after the count.
        let tree = scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        let kids = tree.sorted_children(Tree::ROOT);
        assert_eq!(kids.len(), 1);
        let bucket = tree.get(kids[0]).unwrap();
        assert_eq!(bucket.kind, NodeKind::Aggregate);
        assert_eq!(&*bucket.name, "2 smaller files");
        assert_eq!(bucket.file_count, 2);
    }

    #[test]
    fn rescan_notices_removed_files_and_folders() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("a/big.bin"), 2 * 1024 * 1024);
        write(&root.join("b/big.bin"), 2 * 1024 * 1024);
        let first = scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        fs::remove_file(root.join("a/big.bin")).unwrap();
        fs::remove_dir_all(root.join("b")).unwrap();
        let again = scan_with_cache(root, &ScanOptions::default(), &ScanProgress::default(), Some(&first)).unwrap();
        assert!(again.find(&root.join("a/big.bin")).is_none());
        assert!(again.find(&root.join("b")).is_none());
        assert_eq!(again.root().unwrap().file_count, 0);
    }

    #[test]
    fn a_cache_of_another_root_is_ignored() {
        let tmp = tempfile::tempdir().unwrap();
        write(&tmp.path().join("one/x/big.bin"), 2 * 1024 * 1024);
        write(&tmp.path().join("two/y"), 10);
        let one = scan(&tmp.path().join("one"), &ScanOptions::default(), &ScanProgress::default()).unwrap();
        let two_root = tmp.path().join("two");
        let two = scan_with_cache(&two_root, &ScanOptions::default(), &ScanProgress::default(), Some(&one)).unwrap();
        assert_eq!(two.root().unwrap().file_count, 1);
        assert!(two.find(&two_root.join("x")).is_none());
    }

    #[test]
    fn live_view_follows_the_scan() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("a/b/c/d/deep.bin"), 2 * 1024 * 1024);
        let progress = ScanProgress::default();
        let opts = ScanOptions { live: true, ..Default::default() };
        let tree = scan(root, &opts, &progress).unwrap();
        let (live, pending) = progress.live.snapshot(root).unwrap();
        assert_eq!(live.root().unwrap().size, tree.root().unwrap().size);
        // Folders up to live::DEPTH get a node; deeper ones count towards it.
        assert!(live.find(&root.join("a/b/c")).is_some());
        assert!(live.find(&root.join("a/b/c/d")).is_none());
        assert!(pending.iter().all(|p| !p));
    }

    #[cfg(unix)]
    #[test]
    fn hard_links_are_counted_once() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        write(&root.join("a/big.bin"), 2 * 1024 * 1024);
        fs::create_dir_all(root.join("b")).unwrap();
        fs::hard_link(root.join("a/big.bin"), root.join("b/same.bin")).unwrap();
        let tree = scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        assert_eq!(tree.root().unwrap().file_count, 1);
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_folders_are_reported() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let locked = root.join("locked");
        write(&locked.join("x"), 10);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        // Root can read anything, so there is nothing to test then.
        let readable = fs::read_dir(&locked).is_ok();
        let progress = ScanProgress::default();
        let tree = scan(root, &ScanOptions::default(), &progress);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        if readable {
            return;
        }
        let tree = tree.unwrap();
        assert_eq!(tree.unreadable, vec![locked.clone()]);
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        // Never trusted from the cache: the next scan tries again.
        let id = tree.find(&locked).unwrap();
        assert_eq!(tree.nodes[id as usize].stamp, 0);
    }
}
