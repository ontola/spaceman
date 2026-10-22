//! The API exposed to Flutter through flutter_rust_bridge.
//!
//! The scanned tree lives in Rust; Dart only asks for the handful of nodes
//! it is currently displaying, so even huge disks stay responsive.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, LazyLock, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::{bail, Context};

use crate::core::cache;
use crate::core::privacy;
use crate::core::protect::{ProtectList, Protection};
use crate::core::rules::{self, Category, Removal, Safety};
use crate::core::scan::{self, ScanOptions, ScanProgress};
use crate::core::tree::{NodeId, NodeKind, Tree};
use crate::frb_generated::StreamSink;

#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct State {
    tree: Option<Tree>,
    protect: ProtectList,
    cache_dir: Option<PathBuf>,
}

static STATE: LazyLock<RwLock<State>> = LazyLock::new(Default::default);
static RUNNING: LazyLock<Mutex<Option<Arc<ScanProgress>>>> = LazyLock::new(Default::default);

pub enum EntryKind {
    Dir,
    File,
    /// Many small files in one directory, shown as a single entry.
    SmallFiles,
}

pub enum ProtectionState {
    None,
    Protected,
    ContainsProtected,
}

pub struct NodeView {
    pub id: u32,
    pub name: String,
    pub path: String,
    /// Bytes on disk, including everything inside.
    pub size: i64,
    pub file_count: i64,
    pub kind: EntryKind,
    /// Seconds since the Unix epoch, 0 when unknown.
    pub modified: i64,
    pub protection: ProtectionState,
    pub has_children: bool,
}

pub struct ScanUpdate {
    pub files: i64,
    pub dirs: i64,
    pub bytes: i64,
    pub errors: i64,
    pub elapsed_ms: i64,
    pub done: bool,
    /// The scan was stopped early. If there was no earlier scan to show,
    /// what was scanned so far is shown instead.
    pub partial: bool,
    /// Set when the scan failed.
    pub error: Option<String>,
}

pub enum SuggestionCategory {
    Cache,
    BuildOutput,
    Trash,
    Logs,
    Downloads,
    Backups,
    LargeOldFile,
}

pub enum RemovalMode {
    /// The item itself is moved to the trash.
    Whole,
    /// The folder is kept and its contents are moved to the trash.
    Contents,
    /// The folder is the trash; its contents are deleted for good.
    EmptyTrash,
}

pub struct SuggestionView {
    pub node: NodeView,
    pub removal: RemovalMode,
    pub title: String,
    pub reason: String,
    pub category: SuggestionCategory,
    /// True when the item is regenerated automatically and safe to remove.
    pub safe: bool,
}

pub struct DiskSpace {
    pub total: i64,
    pub free: i64,
}

pub struct FailedDelete {
    pub path: String,
    pub reason: String,
}

pub struct DeleteReport {
    pub deleted: Vec<String>,
    pub freed: i64,
    pub failed: Vec<FailedDelete>,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Loads settings (the protect list) from `config_dir`, and keeps scan
/// caches in `cache_dir`.
#[flutter_rust_bridge::frb(sync)]
pub fn configure(config_dir: String, cache_dir: String) {
    let mut state = STATE.write().unwrap();
    state.protect = ProtectList::load(PathBuf::from(config_dir).join("protected.json"));
    state.cache_dir = Some(PathBuf::from(cache_dir));
}

/// Loads the cached result of an earlier scan of `root`, so it can be shown
/// right away. Returns the time of that scan (seconds since the epoch).
pub fn load_cached_scan(root: String) -> Option<i64> {
    let root = PathBuf::from(root);
    let file = cache::file_for(STATE.read().unwrap().cache_dir.as_ref()?, &root);
    let tree = cache::load(&file).filter(|t| t.root_path == root)?;
    let at = tree.scanned_at;
    STATE.write().unwrap().tree = Some(tree);
    Some(at)
}

/// Time of the scan currently loaded, in seconds since the epoch.
#[flutter_rust_bridge::frb(sync)]
pub fn scanned_at() -> Option<i64> {
    STATE.read().unwrap().tree.as_ref().map(|t| t.scanned_at)
}

/// Whether the app can read everything without macOS permission prompts.
#[flutter_rust_bridge::frb(sync)]
pub fn has_full_disk_access() -> bool {
    privacy::has_full_disk_access()
}

#[flutter_rust_bridge::frb(sync)]
pub fn home_dir() -> Option<String> {
    home().map(|p| p.to_string_lossy().into_owned())
}

#[flutter_rust_bridge::frb(sync)]
pub fn disk_space(path: String) -> Option<DiskSpace> {
    let total = fs2::total_space(&path).ok()?;
    let free = fs2::available_space(&path).ok()?;
    Some(DiskSpace { total: total as i64, free: free as i64 })
}

/// Scans `root`, streaming progress roughly ten times per second. The last
/// update has `done` set. Starting a new scan cancels a running one.
///
/// Unless `full` is set, directories that did not change since the loaded
/// (or cached) scan are taken from it instead of being read again.
///
/// With `skip_prompting_folders`, folders that would make macOS ask for
/// permission (Desktop, Documents, ...) are left out.
pub fn scan_dir(root: String, full: bool, skip_prompting_folders: bool, sink: StreamSink<ScanUpdate>) {
    let progress = Arc::new(ScanProgress::default());
    if let Some(old) = RUNNING.lock().unwrap().replace(progress.clone()) {
        old.cancel.store(true, Ordering::Relaxed);
    }
    let start = Instant::now();
    let update = |done: bool, error: Option<String>| ScanUpdate {
        files: progress.files.load(Ordering::Relaxed) as i64,
        dirs: progress.dirs.load(Ordering::Relaxed) as i64,
        bytes: progress.bytes.load(Ordering::Relaxed) as i64,
        errors: progress.errors.load(Ordering::Relaxed) as i64,
        elapsed_ms: start.elapsed().as_millis() as i64,
        done,
        partial: progress.cancel.load(Ordering::Relaxed),
        error,
    };

    let finished = std::sync::atomic::AtomicBool::new(false);
    let result = std::thread::scope(|s| {
        s.spawn(|| {
            while !finished.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(100));
                if sink.add(update(false, None)).is_err() {
                    // Dart stopped listening: nobody wants this scan anymore.
                    progress.cancel.store(true, Ordering::Relaxed);
                }
            }
        });
        let root = PathBuf::from(&root);
        let previous = if full { None } else { previous_scan(&root) };
        let mut opts = ScanOptions::default();
        if skip_prompting_folders {
            if let Some(h) = home() {
                opts.skip = privacy::prompting_folders(&h);
            }
        }
        let r = scan::scan_with_cache(&root, &opts, &progress, previous.as_ref());
        finished.store(true, Ordering::Relaxed);
        r
    });

    let mut save = false;
    let error = match result {
        Ok(tree) => {
            let mut state = STATE.write().unwrap();
            // A stopped rescan is worse than the complete scan before it.
            let keep_old = tree.partial
                && state.tree.as_ref().is_some_and(|t| t.root_path == tree.root_path && !t.partial);
            if !keep_old {
                state.tree = Some(tree);
                save = true;
            }
            None
        }
        Err(e) => Some(e.to_string()),
    };
    {
        let mut running = RUNNING.lock().unwrap();
        if running.as_ref().is_some_and(|p| Arc::ptr_eq(p, &progress)) {
            *running = None;
        }
    }
    // Tell the UI first; writing a cache of millions of entries takes a while.
    let _ = sink.add(update(true, error));
    if save {
        // Partial trees are safe to cache: folders the scan did not finish
        // carry no stamp, so the next scan reads them. Only a read lock is
        // held, so the UI keeps browsing meanwhile.
        std::thread::spawn(|| {
            let state = STATE.read().unwrap();
            if let Some(tree) = state.tree.as_ref() {
                save_cache(state.cache_dir.as_deref(), tree);
            }
        });
    }
}

/// The scan to reuse unchanged directories from. Read from the cache file
/// (which is kept in sync with the loaded tree) rather than borrowing the
/// in-memory tree, so the UI never waits on a lock while a scan runs.
fn previous_scan(root: &Path) -> Option<Tree> {
    let dir = STATE.read().unwrap().cache_dir.clone()?;
    cache::load(&cache::file_for(&dir, root)).filter(|t| t.root_path == root)
}

fn save_cache(cache_dir: Option<&Path>, tree: &Tree) {
    let Some(dir) = cache_dir else { return };
    if let Err(e) = cache::save(&cache::file_for(dir, &tree.root_path), tree) {
        eprintln!("could not save scan cache: {e:#}");
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cancel_scan() {
    if let Some(p) = RUNNING.lock().unwrap().as_ref() {
        p.cancel.store(true, Ordering::Relaxed);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn root_node() -> Option<NodeView> {
    let state = STATE.read().unwrap();
    let tree = state.tree.as_ref()?;
    tree.root().map(|_| view(tree, &state.protect, Tree::ROOT))
}

/// Children of a node, largest first.
#[flutter_rust_bridge::frb(sync)]
pub fn children(id: u32) -> Vec<NodeView> {
    let state = STATE.read().unwrap();
    let Some(tree) = state.tree.as_ref() else { return vec![] };
    tree.sorted_children(id).into_iter().map(|c| view(tree, &state.protect, c)).collect()
}

/// The chain of nodes from the scan root down to `id`, for breadcrumbs.
#[flutter_rust_bridge::frb(sync)]
pub fn breadcrumbs(id: u32) -> Vec<NodeView> {
    let state = STATE.read().unwrap();
    let Some(tree) = state.tree.as_ref() else { return vec![] };
    tree.ancestors(id).into_iter().map(|c| view(tree, &state.protect, c)).collect()
}

pub fn suggestions() -> Vec<SuggestionView> {
    let state = STATE.read().unwrap();
    let Some(tree) = state.tree.as_ref() else { return vec![] };
    let home = home();
    rules::suggest(tree, home.as_deref(), &state.protect)
        .into_iter()
        .map(|s| SuggestionView {
            node: view(tree, &state.protect, s.node),
            removal: match s.removal {
                Removal::Whole => RemovalMode::Whole,
                Removal::Contents => RemovalMode::Contents,
                Removal::EmptyTrash => RemovalMode::EmptyTrash,
            },
            title: s.title,
            reason: s.reason,
            category: match s.category {
                Category::Cache => SuggestionCategory::Cache,
                Category::BuildOutput => SuggestionCategory::BuildOutput,
                Category::Trash => SuggestionCategory::Trash,
                Category::Logs => SuggestionCategory::Logs,
                Category::Downloads => SuggestionCategory::Downloads,
                Category::Backups => SuggestionCategory::Backups,
                Category::LargeOldFile => SuggestionCategory::LargeOldFile,
            },
            safe: s.safety == Safety::Safe,
        })
        .collect()
}

/// Folders the current scan could not read, at most a couple hundred.
#[flutter_rust_bridge::frb(sync)]
pub fn unreadable_folders() -> Vec<String> {
    let state = STATE.read().unwrap();
    state
        .tree
        .as_ref()
        .map(|t| t.unreadable.iter().map(|p| p.to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

/// The scanned item at `path`, if the current scan has it.
#[flutter_rust_bridge::frb(sync)]
pub fn node_at(path: String) -> Option<NodeView> {
    let state = STATE.read().unwrap();
    let tree = state.tree.as_ref()?;
    let id = tree.find(Path::new(&path))?;
    Some(view(tree, &state.protect, id))
}

#[flutter_rust_bridge::frb(sync)]
pub fn protected_paths() -> Vec<String> {
    let state = STATE.read().unwrap();
    state.protect.paths().iter().map(|p| p.to_string_lossy().into_owned()).collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn protect_path(path: String) -> anyhow::Result<()> {
    STATE.write().unwrap().protect.add(PathBuf::from(path)).context("saving protect list")
}

#[flutter_rust_bridge::frb(sync)]
pub fn unprotect_path(path: String) -> anyhow::Result<()> {
    STATE.write().unwrap().protect.remove(Path::new(&path)).context("saving protect list")
}

/// Moves paths to the trash (or deletes them when `permanent` is set, or on
/// platforms without a trash). Protected paths are always refused.
///
/// Well-known folders such as the caches folder or Downloads are emptied
/// instead of removed, and the trash itself is emptied for good.
pub fn delete_paths(paths: Vec<String>, permanent: bool) -> DeleteReport {
    let mut report = DeleteReport { deleted: vec![], freed: 0, failed: vec![] };
    let home = home();
    // Empty the trash before moving anything else into it, or we would
    // permanently delete what the user just meant to trash.
    let mut paths = paths;
    paths.sort_by_key(|p| rules::removal_for(Path::new(p), home.as_deref()) != Removal::EmptyTrash);
    for p in paths {
        let path = PathBuf::from(&p);
        // Already gone (removed outside SpaceMan, or twice in one selection):
        // that is what the user wanted, so it is not a failure.
        if std::fs::symlink_metadata(&path).is_err() {
            report.deleted.push(p);
            continue;
        }
        // Validate under a short read lock, but never hold the lock while
        // touching the disk: the UI reads the tree synchronously.
        if let Err(e) = check_deletable(&STATE.read().unwrap(), &path) {
            report.failed.push(FailedDelete { path: p, reason: format!("{e:#}") });
            continue;
        }
        let targets: Vec<PathBuf> = match rules::removal_for(&path, home.as_deref()) {
            Removal::Whole => vec![path.clone()],
            Removal::Contents | Removal::EmptyTrash => match std::fs::read_dir(&path) {
                Ok(entries) => entries.flatten().map(|e| e.path()).collect(),
                Err(e) => {
                    report.failed.push(FailedDelete { path: p, reason: e.to_string() });
                    continue;
                }
            },
        };
        let permanent = permanent || rules::removal_for(&path, home.as_deref()) == Removal::EmptyTrash;
        let mut any_failed = None;
        for target in targets {
            let state = STATE.read().unwrap();
            // Emptying the caches folder must not wipe our own scan cache.
            let ours = state.cache_dir.as_deref() == Some(target.as_path());
            if ours || state.protect.blocks_delete(&target) {
                continue;
            }
            drop(state);
            match remove_from_disk(&target, permanent) {
                Ok(()) => {
                    let mut state = STATE.write().unwrap();
                    if let Some(tree) = state.tree.as_mut() {
                        if let Some(id) = tree.find(&target) {
                            report.freed += tree.nodes[id as usize].size as i64;
                            tree.remove(id);
                        }
                    }
                }
                // Files in use (e.g. a running app's cache) may refuse to
                // move; skip them and keep going.
                Err(e) => any_failed = Some(format!("{}: {e:#}", target.display())),
            }
        }
        if any_failed.is_none() && rules::removal_for(&path, home.as_deref()) != Removal::Whole {
            // Small files are not tracked one by one; drop their bucket too.
            let mut state = STATE.write().unwrap();
            if let Some(tree) = state.tree.as_mut() {
                let buckets: Vec<NodeId> = tree
                    .find(&path)
                    .map(|id| tree.sorted_children(id))
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|c| tree.nodes[*c as usize].kind == NodeKind::Aggregate)
                    .collect();
                for b in buckets {
                    report.freed += tree.nodes[b as usize].size as i64;
                    tree.remove(b);
                }
            }
        }
        match any_failed {
            Some(reason) => report.failed.push(FailedDelete { path: p, reason }),
            None => report.deleted.push(p),
        }
    }
    if !report.deleted.is_empty() || report.freed > 0 {
        let state = STATE.read().unwrap();
        if let Some(tree) = state.tree.as_ref() {
            save_cache(state.cache_dir.as_deref(), tree);
        }
    }
    report
}

/// Checks that `path` may be deleted at all.
fn check_deletable(state: &State, path: &Path) -> anyhow::Result<()> {
    if state.protect.blocks_delete(path) {
        bail!("this item is marked as do not touch");
    }
    let tree = state.tree.as_ref().context("no scan loaded")?;
    // The tree can lag behind what the user selected (e.g. a rescan that
    // skipped protected folders replaced it), so anything inside the
    // scanned folder may go, even if this scan did not see it.
    if !path.starts_with(&tree.root_path) {
        bail!("item is outside the scanned folder");
    }
    if path == tree.root_path {
        bail!("refusing to delete the scanned folder itself");
    }
    if home().as_deref() == Some(path) {
        bail!("refusing to delete the home folder");
    }
    Ok(())
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn remove_from_disk(path: &Path, permanent: bool) -> anyhow::Result<()> {
    if permanent {
        return remove_permanently(path);
    }
    trash::delete(path).context("moving to trash")
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn remove_from_disk(path: &Path, _permanent: bool) -> anyhow::Result<()> {
    remove_permanently(path)
}

fn remove_permanently(path: &Path) -> anyhow::Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if meta.is_dir() {
        std::fs::remove_dir_all(path)?;
    } else {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

fn home() -> Option<PathBuf> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn view(tree: &Tree, protect: &ProtectList, id: NodeId) -> NodeView {
    let n = &tree.nodes[id as usize];
    let path = tree.path(id);
    let protection = match n.kind {
        // Small-file buckets stand for their directory's loose files; they
        // inherit only an explicit protection of the directory itself.
        NodeKind::Aggregate => match protect.check(&path) {
            Protection::Protected => ProtectionState::Protected,
            _ => ProtectionState::None,
        },
        _ => match protect.check(&path) {
            Protection::None => ProtectionState::None,
            Protection::Protected => ProtectionState::Protected,
            Protection::ContainsProtected => ProtectionState::ContainsProtected,
        },
    };
    NodeView {
        id,
        name: if id == Tree::ROOT { tree.root_path.to_string_lossy().into_owned() } else { n.name.to_string() },
        path: path.to_string_lossy().into_owned(),
        size: n.size as i64,
        file_count: n.file_count as i64,
        kind: match n.kind {
            NodeKind::Dir => EntryKind::Dir,
            NodeKind::File => EntryKind::File,
            NodeKind::Aggregate => EntryKind::SmallFiles,
        },
        modified: n.modified,
        protection,
        has_children: n.kind == NodeKind::Dir && n.children.iter().any(|c| !tree.nodes[*c as usize].removed),
    }
}
