//! The API exposed to Flutter through flutter_rust_bridge.
//!
//! The scanned tree lives in Rust; Dart only asks for the handful of nodes
//! it is currently displaying, so even huge disks stay responsive.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// The running scan so far, shown while there is no `tree` yet.
    live: Option<Live>,
    protect: ProtectList,
    cache_dir: Option<PathBuf>,
}

#[flutter_rust_bridge::frb(ignore)]
struct Live {
    tree: Tree,
    /// Per node: still being scanned.
    pending: Vec<bool>,
}

impl State {
    /// The tree to show: the finished scan, or else the one in progress.
    fn shown(&self) -> Option<(&Tree, &[bool])> {
        match (&self.tree, &self.live) {
            (Some(t), _) => Some((t, &[])),
            (None, Some(l)) => Some((&l.tree, &l.pending)),
            _ => None,
        }
    }
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
    /// Still being scanned: the size is still growing and the contents are
    /// not known yet.
    pub scanning: bool,
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
    /// A new view of the scan so far is available: refetch what is shown.
    pub live: bool,
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

/// How far a removal is. The last one carries the report.
pub struct DeleteProgress {
    /// Items of the selection handled so far, and in total.
    pub done: i64,
    pub total: i64,
    pub freed: i64,
    /// Files removed so far and the files in the selection, as far as the
    /// scan knows; moves the bar within one big folder.
    pub files_done: i64,
    pub files_total: i64,
    /// What is being removed now.
    pub current: String,
    pub report: Option<DeleteReport>,
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
    let update = |done: bool, error: Option<String>, live: bool| ScanUpdate {
        files: progress.files.load(Ordering::Relaxed) as i64,
        dirs: progress.dirs.load(Ordering::Relaxed) as i64,
        bytes: progress.bytes.load(Ordering::Relaxed) as i64,
        errors: progress.errors.load(Ordering::Relaxed) as i64,
        elapsed_ms: start.elapsed().as_millis() as i64,
        done,
        partial: progress.cancel.load(Ordering::Relaxed),
        error,
        live,
    };
    let root = PathBuf::from(&root);
    // Show results as they come in, unless there is a scan to show already.
    let show_live = {
        let mut state = STATE.write().unwrap();
        // A scan of another folder is no use here.
        if state.tree.as_ref().is_some_and(|t| t.root_path != root) {
            state.tree = None;
        }
        state.tree.is_none()
    };

    let finished = std::sync::atomic::AtomicBool::new(false);
    let result = std::thread::scope(|s| {
        s.spawn(|| {
            let mut ticks = 0u32;
            while !finished.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(100));
                ticks += 1;
                // A fresh live view every half second; sizes grow in steps
                // the eye can follow and rows do not reshuffle constantly.
                let live = show_live && ticks.is_multiple_of(5) && publish_live(&root, &progress);
                if sink.add(update(false, None, live)).is_err() {
                    // Dart stopped listening: nobody wants this scan anymore.
                    progress.cancel.store(true, Ordering::Relaxed);
                }
            }
        });
        let previous = if full { None } else { previous_scan(&root) };
        let mut opts = ScanOptions { live: show_live, ..Default::default() };
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
            state.live = None;
            // A stopped rescan is worse than the complete scan before it.
            let keep_old = tree.partial
                && state.tree.as_ref().is_some_and(|t| t.root_path == tree.root_path && !t.partial);
            if !keep_old {
                state.tree = Some(tree);
                save = true;
            }
            None
        }
        Err(e) => {
            STATE.write().unwrap().live = None;
            Some(e.to_string())
        }
    };
    {
        let mut running = RUNNING.lock().unwrap();
        if running.as_ref().is_some_and(|p| Arc::ptr_eq(p, &progress)) {
            *running = None;
        }
    }
    // Tell the UI first; writing a cache of millions of entries takes a while.
    let _ = sink.add(update(true, error, false));
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

/// Makes the scan so far what the UI shows. False when there is nothing yet.
fn publish_live(root: &Path, progress: &ScanProgress) -> bool {
    let Some((tree, pending)) = progress.live.snapshot(root) else { return false };
    let mut state = STATE.write().unwrap();
    if state.tree.is_some() {
        return false;
    }
    state.live = Some(Live { tree, pending });
    true
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
    let (tree, pending) = state.shown()?;
    tree.root().map(|_| view(tree, pending, &state.protect, Tree::ROOT))
}

/// Children of a node, largest first.
#[flutter_rust_bridge::frb(sync)]
pub fn children(id: u32) -> Vec<NodeView> {
    let state = STATE.read().unwrap();
    let Some((tree, pending)) = state.shown() else { return vec![] };
    tree.sorted_children(id).into_iter().map(|c| view(tree, pending, &state.protect, c)).collect()
}

/// The chain of nodes from the scan root down to `id`, for breadcrumbs.
#[flutter_rust_bridge::frb(sync)]
pub fn breadcrumbs(id: u32) -> Vec<NodeView> {
    let state = STATE.read().unwrap();
    let Some((tree, pending)) = state.shown() else { return vec![] };
    tree.ancestors(id).into_iter().map(|c| view(tree, pending, &state.protect, c)).collect()
}

pub fn suggestions() -> Vec<SuggestionView> {
    let state = STATE.read().unwrap();
    let Some(tree) = state.tree.as_ref() else { return vec![] };
    let home = home();
    rules::suggest(tree, home.as_deref(), &state.protect)
        .into_iter()
        .map(|s| suggestion_view(tree, &state.protect, s))
        .collect()
}

fn suggestion_view(tree: &Tree, protect: &ProtectList, s: rules::Suggestion) -> SuggestionView {
    SuggestionView {
        node: view(tree, &[], protect, s.node),
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
    }
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
    let (tree, pending) = state.shown()?;
    let id = tree.find(Path::new(&path))?;
    Some(view(tree, pending, &state.protect, id))
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

static DELETE_CANCEL: AtomicBool = AtomicBool::new(false);

/// Moves paths to the trash (or deletes them when `permanent` is set, or on
/// platforms without a trash). Protected paths are always refused.
///
/// Well-known folders such as the caches folder or Downloads are emptied
/// instead of removed, and the trash itself is emptied for good.
pub fn delete_paths(paths: Vec<String>, permanent: bool) -> DeleteReport {
    delete_inner(&STATE, home().as_deref(), &DELETE_CANCEL, paths, permanent, &mut |_| {})
}

/// Like [`delete_paths`], streaming progress about ten times a second. The
/// last update carries the report. [`cancel_delete`] stops after the file
/// being removed; what is gone by then stays gone.
pub fn delete_paths_with_progress(paths: Vec<String>, permanent: bool, sink: StreamSink<DeleteProgress>) {
    let mut last = Instant::now();
    let report = delete_inner(&STATE, home().as_deref(), &DELETE_CANCEL, paths, permanent, &mut |p| {
        // Item boundaries always; file by file at most every 100 ms.
        if p.at_item_start || last.elapsed() >= Duration::from_millis(100) {
            last = Instant::now();
            let _ = sink.add(p.to_view(None));
        }
    });
    let _ = sink.add(DeleteProgress {
        done: report.deleted.len() as i64 + report.failed.len() as i64,
        total: 0,
        freed: report.freed,
        files_done: 0,
        files_total: 0,
        current: String::new(),
        report: Some(report),
    });
}

/// Stops a running [`delete_paths_with_progress`].
#[flutter_rust_bridge::frb(sync)]
pub fn cancel_delete() {
    DELETE_CANCEL.store(true, Ordering::Relaxed);
}

#[flutter_rust_bridge::frb(ignore)]
struct Progress {
    done: usize,
    total: usize,
    freed: i64,
    files_done: u64,
    files_total: u64,
    current: PathBuf,
    at_item_start: bool,
}

impl Progress {
    fn to_view(&self, report: Option<DeleteReport>) -> DeleteProgress {
        DeleteProgress {
            done: self.done as i64,
            total: self.total as i64,
            freed: self.freed,
            files_done: self.files_done as i64,
            files_total: self.files_total as i64,
            current: self.current.to_string_lossy().into_owned(),
            report,
        }
    }
}

/// Removes `paths`, reporting to `on` as it goes. Works on `state` rather
/// than the global one, and takes `home` and the `cancel` flag as given, so
/// tests can run it in isolation.
fn delete_inner(
    state: &RwLock<State>,
    home: Option<&Path>,
    cancel: &AtomicBool,
    paths: Vec<String>,
    permanent: bool,
    on: &mut dyn FnMut(&Progress),
) -> DeleteReport {
    cancel.store(false, Ordering::Relaxed);
    let mut report = DeleteReport { deleted: vec![], freed: 0, failed: vec![] };
    let mut progress = Progress {
        done: 0,
        total: paths.len(),
        freed: 0,
        files_done: 0,
        files_total: {
            let state = state.read().unwrap();
            state.tree.as_ref().map_or(0, |t| {
                paths.iter().filter_map(|p| t.find(Path::new(p))).map(|id| t.nodes[id as usize].file_count).sum()
            })
        },
        current: PathBuf::new(),
        at_item_start: true,
    };
    // Empty the trash before moving anything else into it, or we would
    // permanently delete what the user just meant to trash.
    let mut paths = paths;
    paths.sort_by_key(|p| rules::removal_for(Path::new(p), home) != Removal::EmptyTrash);
    for p in paths {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let path = PathBuf::from(&p);
        progress.current = path.clone();
        progress.at_item_start = true;
        on(&progress);
        progress.done += 1;
        // Already gone (removed outside SpaceMan, or twice in one selection):
        // that is what the user wanted, so it is not a failure.
        if std::fs::symlink_metadata(&path).is_err() {
            report.deleted.push(p);
            continue;
        }
        // Validate under a short read lock, but never hold the lock while
        // touching the disk: the UI reads the tree synchronously.
        if let Err(e) = check_deletable(&state.read().unwrap(), home, &path) {
            report.failed.push(FailedDelete { path: p, reason: format!("{e:#}") });
            continue;
        }
        let removal = rules::removal_for(&path, home);
        let targets: Vec<PathBuf> = match removal {
            Removal::Whole => vec![path.clone()],
            Removal::Contents | Removal::EmptyTrash => match std::fs::read_dir(&path) {
                Ok(entries) => entries.flatten().map(|e| e.path()).collect(),
                Err(e) => {
                    report.failed.push(FailedDelete { path: p, reason: e.to_string() });
                    continue;
                }
            },
        };
        let permanent = permanent || removal == Removal::EmptyTrash;
        let mut any_failed = None;
        for target in targets {
            if cancel.load(Ordering::Relaxed) {
                any_failed = Some("stopped".to_string());
                break;
            }
            {
                let state = state.read().unwrap();
                // Emptying the caches folder must not wipe our own scan cache.
                let ours = state.cache_dir.as_deref() == Some(target.as_path());
                if ours || state.protect.blocks_delete(&target) {
                    continue;
                }
            }
            let files_before = progress.files_done;
            let result = remove_from_disk(&target, permanent, cancel, &mut || {
                progress.files_done += 1;
                progress.at_item_start = false;
                on(&progress);
            });
            match result {
                Ok(()) => {
                    let mut state = state.write().unwrap();
                    if let Some(tree) = state.tree.as_mut() {
                        if let Some(id) = tree.find(&target) {
                            let n = &tree.nodes[id as usize];
                            report.freed += n.size as i64;
                            // A move to the trash is one step for all its files.
                            progress.files_done = progress.files_done.max(files_before + n.file_count);
                            tree.remove(id);
                        }
                    }
                    progress.freed = report.freed;
                    progress.at_item_start = false;
                    on(&progress);
                }
                // Files in use (e.g. a running app's cache) may refuse to
                // move; skip them and keep going.
                Err(e) => any_failed = Some(format!("{}: {e:#}", target.display())),
            }
        }
        if any_failed.is_none() && removal != Removal::Whole {
            // Small files are not tracked one by one; drop their bucket too.
            let mut state = state.write().unwrap();
            if let Some(tree) = state.tree.as_mut() {
                report.freed += remove_small_files(tree, &path);
            }
        }
        match any_failed {
            Some(reason) => report.failed.push(FailedDelete { path: p, reason }),
            None => report.deleted.push(p),
        }
    }
    if !report.deleted.is_empty() || report.freed > 0 {
        let state = state.read().unwrap();
        if let Some(tree) = state.tree.as_ref() {
            save_cache(state.cache_dir.as_deref(), tree);
        }
    }
    report
}

/// Drops the small-files bucket of the folder at `path` from the tree, and
/// returns how many bytes it held.
fn remove_small_files(tree: &mut Tree, path: &Path) -> i64 {
    let buckets: Vec<NodeId> = tree
        .find(path)
        .map(|id| tree.sorted_children(id))
        .unwrap_or_default()
        .into_iter()
        .filter(|c| tree.nodes[*c as usize].kind == NodeKind::Aggregate)
        .collect();
    let mut freed = 0;
    for b in buckets {
        freed += tree.nodes[b as usize].size as i64;
        tree.remove(b);
    }
    freed
}

/// Checks that `path` may be deleted at all.
fn check_deletable(state: &State, home: Option<&Path>, path: &Path) -> anyhow::Result<()> {
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
    if home == Some(path) {
        bail!("refusing to delete the home folder");
    }
    Ok(())
}

/// `on_file` is called for every file removed permanently.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn remove_from_disk(path: &Path, permanent: bool, cancel: &AtomicBool, on_file: &mut dyn FnMut()) -> anyhow::Result<()> {
    if permanent {
        return remove_permanently(path, cancel, on_file);
    }
    trash::delete(path).context("moving to trash")
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn remove_from_disk(path: &Path, _permanent: bool, cancel: &AtomicBool, on_file: &mut dyn FnMut()) -> anyhow::Result<()> {
    remove_permanently(path, cancel, on_file)
}

/// Removes a file or a whole folder, file by file so progress can be shown
/// and a stop takes effect quickly. Never follows links.
fn remove_permanently(path: &Path, cancel: &AtomicBool, on_file: &mut dyn FnMut()) -> anyhow::Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        std::fs::remove_file(path)?;
        on_file();
        return Ok(());
    }
    for entry in std::fs::read_dir(path)? {
        if cancel.load(Ordering::Relaxed) {
            bail!("stopped");
        }
        remove_permanently(&entry?.path(), cancel, on_file)?;
    }
    std::fs::remove_dir(path)?;
    Ok(())
}

fn home() -> Option<PathBuf> {
    // Apps on Android have no home folder; shared storage is what the user
    // thinks of as "the phone".
    if cfg!(target_os = "android") {
        return Some(
            std::env::var_os("EXTERNAL_STORAGE")
                .filter(|v| !v.is_empty())
                .map_or_else(|| PathBuf::from("/storage/emulated/0"), PathBuf::from),
        );
    }
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn view(tree: &Tree, pending: &[bool], protect: &ProtectList, id: NodeId) -> NodeView {
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
        scanning: pending.get(id as usize).copied().unwrap_or(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![1u8; bytes]).unwrap();
    }

    const MB: usize = 1024 * 1024;

    /// A scanned folder with a state around it, as the app has after a scan.
    struct Fixture {
        tmp: tempfile::TempDir,
        state: RwLock<State>,
        cancel: AtomicBool,
    }

    impl Fixture {
        /// `files` are created under `root` before it is scanned.
        fn new(files: &[(&str, usize)]) -> Self {
            let tmp = tempfile::tempdir().unwrap();
            let root = tmp.path().join("root");
            fs::create_dir_all(&root).unwrap();
            for (f, size) in files {
                write(&root.join(f), *size);
            }
            let tree = scan::scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
            let state = State {
                tree: Some(tree),
                live: None,
                protect: ProtectList::load(tmp.path().join("config/protected.json")),
                cache_dir: Some(tmp.path().join("cache")),
            };
            Self { tmp, state: RwLock::new(state), cancel: AtomicBool::new(false) }
        }

        fn root(&self) -> PathBuf {
            self.tmp.path().join("root")
        }

        fn path(&self, rel: &str) -> String {
            self.root().join(rel).to_string_lossy().into_owned()
        }

        fn delete(&self, rels: &[&str], home: Option<&Path>) -> DeleteReport {
            let paths = rels.iter().map(|r| self.path(r)).collect();
            delete_inner(&self.state, home, &self.cancel, paths, true, &mut |_| {})
        }

        fn root_size(&self) -> u64 {
            self.state.read().unwrap().tree.as_ref().unwrap().root().unwrap().size
        }
    }

    #[test]
    fn permanent_removal_counts_files() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        fs::create_dir_all(dir.join("a/b")).unwrap();
        for f in ["x", "a/y", "a/b/z"] {
            fs::write(dir.join(f), b"1").unwrap();
        }
        let mut files = 0;
        remove_permanently(&dir, &AtomicBool::new(false), &mut || files += 1).unwrap();
        assert_eq!(files, 3);
        assert!(!dir.exists());
    }

    #[test]
    fn permanent_removal_stops_when_cancelled() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        write(&dir.join("a/x"), 1);
        let err = remove_permanently(&dir, &AtomicBool::new(true), &mut || {}).unwrap_err();
        assert_eq!(err.to_string(), "stopped");
        assert!(dir.join("a/x").exists());
    }

    #[test]
    fn deletes_and_updates_the_tree_and_cache() {
        let f = Fixture::new(&[("a/big.bin", 2 * MB), ("b/big.bin", 2 * MB)]);
        let before = f.root_size();
        let report = f.delete(&["a"], None);
        assert_eq!(report.deleted, vec![f.path("a")]);
        assert!(report.failed.is_empty());
        assert!(report.freed >= 2 * MB as i64);
        assert!(!f.root().join("a").exists());
        assert!(f.root().join("b/big.bin").exists());
        assert_eq!(f.root_size(), before - report.freed as u64);
        // The cache is written with the item gone, so the next start agrees.
        let cached = cache::load(&cache::file_for(&f.tmp.path().join("cache"), &f.root())).unwrap();
        assert!(cached.find(&f.root().join("a")).is_none());
        assert!(cached.find(&f.root().join("b")).is_some());
    }

    #[test]
    fn refuses_protected_items_and_their_folders() {
        let f = Fixture::new(&[("keep/photo.jpg", 10), ("other/x", 10)]);
        f.state.write().unwrap().protect.add(f.root().join("keep/photo.jpg")).unwrap();
        let report = f.delete(&["keep", "keep/photo.jpg"], None);
        assert!(report.deleted.is_empty());
        assert_eq!(report.failed.len(), 2);
        assert!(report.failed.iter().all(|e| e.reason.contains("do not touch")));
        assert!(f.root().join("keep/photo.jpg").exists());
    }

    #[test]
    fn refuses_the_root_the_home_folder_and_anything_outside() {
        let f = Fixture::new(&[("home/x", 10)]);
        let outside = f.tmp.path().join("elsewhere");
        write(&outside.join("x"), 10);
        let home = f.root().join("home");
        let mut paths = vec![f.root().to_string_lossy().into_owned(), f.path("home")];
        paths.push(outside.to_string_lossy().into_owned());
        let report = delete_inner(&f.state, Some(&home), &f.cancel, paths, true, &mut |_| {});
        let reasons: Vec<_> = report.failed.iter().map(|e| e.reason.as_str()).collect();
        assert_eq!(
            reasons,
            [
                "refusing to delete the scanned folder itself",
                "refusing to delete the home folder",
                "item is outside the scanned folder"
            ]
        );
        assert!(home.join("x").exists() && outside.join("x").exists());
    }

    #[test]
    fn refuses_everything_without_a_scan() {
        let f = Fixture::new(&[("a", 10)]);
        f.state.write().unwrap().tree = None;
        let report = f.delete(&["a"], None);
        assert_eq!(report.failed[0].reason, "no scan loaded");
        assert!(f.root().join("a").exists());
    }

    #[test]
    fn missing_items_count_as_deleted() {
        let f = Fixture::new(&[("a", 10)]);
        let report = f.delete(&["gone"], None);
        assert_eq!(report.deleted, vec![f.path("gone")]);
        assert_eq!(report.freed, 0);
    }

    #[test]
    fn well_known_folders_are_emptied_but_kept() {
        // The scan root plays the home folder, so "Downloads" is the
        // well-known one that must be emptied rather than removed.
        let f = Fixture::new(&[("Downloads/setup.dmg", 2 * MB), ("Downloads/a.txt", 10), ("Downloads/b.txt", 10)]);
        let home = f.root();
        let paths = vec![f.path("Downloads")];
        let report = delete_inner(&f.state, Some(&home), &f.cancel, paths, true, &mut |_| {});
        assert_eq!(report.deleted, vec![f.path("Downloads")]);
        assert!(f.root().join("Downloads").is_dir());
        assert_eq!(fs::read_dir(f.root().join("Downloads")).unwrap().count(), 0);
        // The big file and the small-files bucket are both gone from the tree.
        let state = f.state.read().unwrap();
        let tree = state.tree.as_ref().unwrap();
        let downloads = tree.find(&f.root().join("Downloads")).unwrap();
        assert!(tree.sorted_children(downloads).is_empty());
        assert_eq!(tree.get(downloads).unwrap().file_count, 0);
    }

    #[test]
    fn emptying_a_folder_leaves_protected_items_and_our_cache() {
        let f = Fixture::new(&[(".cache/app/x.bin", 2 * MB), (".cache/keep/y.bin", 2 * MB)]);
        let home = f.root();
        {
            let mut state = f.state.write().unwrap();
            state.protect.add(f.root().join(".cache/keep")).unwrap();
            // Pretend the app keeps its own cache inside the emptied folder.
            state.cache_dir = Some(f.root().join(".cache/app"));
        }
        // Protected inside: the folder itself is refused as a whole...
        let paths = vec![f.path(".cache")];
        let report = delete_inner(&f.state, Some(&home), &f.cancel, paths, true, &mut |_| {});
        assert_eq!(report.failed.len(), 1);
        // ...but once allowed, its contents go except for our cache.
        f.state.write().unwrap().protect.remove(&f.root().join(".cache/keep")).unwrap();
        let paths = vec![f.path(".cache")];
        let report = delete_inner(&f.state, Some(&home), &f.cancel, paths, true, &mut |_| {});
        assert!(report.failed.is_empty());
        assert!(f.root().join(".cache/app/x.bin").exists());
        assert!(!f.root().join(".cache/keep").exists());
    }

    #[test]
    fn a_stopped_removal_reports_what_is_left() {
        let f = Fixture::new(&[("a/x", 10), ("b/y", 10)]);
        // delete_inner clears the flag when it starts, so stop from the
        // first progress report.
        let paths = vec![f.path("a"), f.path("b")];
        let mut seen = 0;
        let report = delete_inner(&f.state, None, &f.cancel, paths, true, &mut |_| {
            seen += 1;
            f.cancel.store(true, Ordering::Relaxed);
        });
        assert_eq!(seen, 1);
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].reason, "stopped");
        assert!(f.root().join("b/y").exists());
    }

    #[test]
    fn progress_counts_items_and_files() {
        let f = Fixture::new(&[("a/x", 10), ("a/y", 10), ("b/z", 10)]);
        let paths = vec![f.path("a"), f.path("b")];
        let mut updates = Vec::new();
        delete_inner(&f.state, None, &f.cancel, paths, true, &mut |p| {
            updates.push((p.done, p.total, p.files_done, p.files_total))
        });
        let last = *updates.last().unwrap();
        assert_eq!(last, (2, 2, 3, 3));
        assert_eq!(updates[0], (0, 2, 0, 3));
    }

    #[test]
    fn view_reports_protection_and_kind() {
        let f = Fixture::new(&[("a/big.bin", 2 * MB), ("a/small.txt", 10), ("b/x", 10)]);
        let mut state = f.state.write().unwrap();
        state.protect.add(f.root().join("a/big.bin")).unwrap();
        let tree = state.tree.as_ref().unwrap();
        let protect = &state.protect;
        let at = |rel: &str| view(tree, &[], protect, tree.find(&f.root().join(rel)).unwrap());

        let root = view(tree, &[], protect, Tree::ROOT);
        assert_eq!(root.name, f.root().to_string_lossy());
        assert!(matches!(root.protection, ProtectionState::ContainsProtected));
        assert!(matches!(at("a").protection, ProtectionState::ContainsProtected));
        assert!(matches!(at("a/big.bin").protection, ProtectionState::Protected));
        assert!(matches!(at("a/big.bin").kind, EntryKind::File));
        assert!(!at("a/big.bin").has_children);
        assert!(matches!(at("b").protection, ProtectionState::None));
        assert!(at("b").has_children);

        // The small-files bucket of a folder that merely contains something
        // protected is not protected itself.
        let a = tree.find(&f.root().join("a")).unwrap();
        let bucket = *tree.sorted_children(a).iter().find(|c| tree.nodes[**c as usize].kind == NodeKind::Aggregate).unwrap();
        let v = view(tree, &[], protect, bucket);
        assert!(matches!(v.kind, EntryKind::SmallFiles));
        assert!(matches!(v.protection, ProtectionState::None));
        assert_eq!(v.path, f.path("a"));
    }

    #[test]
    fn view_marks_pending_nodes_as_scanning() {
        let f = Fixture::new(&[("a/x", 10)]);
        let state = f.state.read().unwrap();
        let tree = state.tree.as_ref().unwrap();
        let pending = vec![true];
        assert!(view(tree, &pending, &state.protect, Tree::ROOT).scanning);
        // Nodes beyond the pending list are not scanning.
        let a = tree.find(&f.root().join("a")).unwrap();
        assert!(!view(tree, &pending, &state.protect, a).scanning);
    }

    #[test]
    fn shows_the_finished_scan_over_the_live_one() {
        let mut state = State::default();
        assert!(state.shown().is_none());
        let live = Tree { root_path: "/live".into(), ..Default::default() };
        state.live = Some(Live { tree: live, pending: vec![true] });
        let (t, pending) = state.shown().unwrap();
        assert_eq!(t.root_path, Path::new("/live"));
        assert_eq!(pending, &[true]);
        state.tree = Some(Tree { root_path: "/done".into(), ..Default::default() });
        let (t, pending) = state.shown().unwrap();
        assert_eq!(t.root_path, Path::new("/done"));
        assert!(pending.is_empty());
    }

    #[test]
    fn suggestions_map_to_views() {
        let f = Fixture::new(&[("proj/Cargo.toml", 10), ("proj/target/big.bin", 101 * MB)]);
        let state = f.state.read().unwrap();
        let tree = state.tree.as_ref().unwrap();
        let found = rules::suggest(tree, None, &state.protect);
        assert_eq!(found.len(), 1);
        let v = suggestion_view(tree, &state.protect, found.into_iter().next().unwrap());
        assert_eq!(v.node.path, f.path("proj/target"));
        assert_eq!(v.title, "Rust build output");
        assert!(v.safe);
        assert!(matches!(v.category, SuggestionCategory::BuildOutput));
        assert!(matches!(v.removal, RemovalMode::Whole));
    }

    #[test]
    fn remove_small_files_drops_only_the_bucket() {
        let f = Fixture::new(&[("a/big.bin", 2 * MB), ("a/s1", 10), ("a/s2", 10)]);
        let mut state = f.state.write().unwrap();
        let tree = state.tree.as_mut().unwrap();
        let a = tree.find(&f.root().join("a")).unwrap();
        let before = tree.get(a).unwrap().size;
        let freed = remove_small_files(tree, &f.root().join("a"));
        assert!(freed > 0);
        assert_eq!(tree.get(a).unwrap().size, before - freed as u64);
        assert_eq!(tree.sorted_children(a).len(), 1);
        assert_eq!(remove_small_files(tree, &f.root().join("missing")), 0);
    }

    /// The functions Dart calls, on the global state. The only test that
    /// touches it, so tests running in parallel do not get in each other's way.
    #[test]
    fn bridge_functions_work_on_the_loaded_scan() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("root");
        write(&root.join("a/big.bin"), 2 * MB);
        write(&root.join("a/b/c.bin"), 2 * MB);
        let root_str = root.to_string_lossy().into_owned();
        let p = |rel: &str| root.join(rel).to_string_lossy().into_owned();

        configure(p("../config"), p("../cache"));
        assert!(load_cached_scan(root_str.clone()).is_none());
        let tree = scan::scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        save_cache(Some(&tmp.path().join("cache")), &tree);
        assert_eq!(load_cached_scan(root_str.clone()), Some(tree.scanned_at));
        assert_eq!(scanned_at(), Some(tree.scanned_at));
        assert!(previous_scan(&root).is_some());

        let top = root_node().unwrap();
        assert_eq!(top.name, root_str);
        assert_eq!(top.file_count, 2);
        let kids = children(top.id);
        assert_eq!(kids.len(), 1);
        assert_eq!(kids[0].path, p("a"));
        let c = node_at(p("a/b/c.bin")).unwrap();
        let crumbs: Vec<_> = breadcrumbs(c.id).into_iter().map(|n| n.path).collect();
        assert_eq!(crumbs, [root_str.clone(), p("a"), p("a/b"), p("a/b/c.bin")]);
        assert!(node_at(p("missing")).is_none());
        assert!(unreadable_folders().is_empty());
        assert!(suggestions().is_empty());
        let disk = disk_space(root_str.clone()).unwrap();
        assert!(disk.total >= disk.free && disk.free > 0);

        protect_path(p("a/b")).unwrap();
        assert_eq!(protected_paths(), [p("a/b")]);
        assert!(matches!(node_at(p("a")).unwrap().protection, ProtectionState::ContainsProtected));
        let report = delete_paths(vec![p("a")], true);
        assert_eq!(report.failed.len(), 1);
        unprotect_path(p("a/b")).unwrap();
        assert!(protected_paths().is_empty());
        let report = delete_paths(vec![p("a/b")], true);
        assert_eq!(report.deleted, [p("a/b")]);
        assert!(node_at(p("a/b")).is_none());
        assert_eq!(root_node().unwrap().file_count, 1);
        cancel_delete();
        cancel_scan();
    }
}
