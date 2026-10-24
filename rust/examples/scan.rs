//! Benchmark the scanner from the command line:
//! `cargo run --release --example scan -- <dir> [cache-file]`
//!
//! With a cache file, the second run reuses unchanged directories. With
//! `LIVE=1`, a live view is kept and snapshotted twice a second, like the app.
//! Like the app, folders seen twice through macOS firmlinks are counted once,
//! unless `FIRMLINKS_TWICE=1` is set.

use std::path::PathBuf;
use std::time::Instant;

use rust_lib_spaceman::core::{cache, firmlinks, scan};

fn main() {
    let mut args = std::env::args().skip(1);
    let root = PathBuf::from(args.next().expect("usage: scan <dir> [cache-file]"));
    let cache_file = args.next().map(PathBuf::from);
    let previous = cache_file.as_deref().and_then(cache::load);

    let live = std::env::var_os("LIVE").is_some();
    let duplicates =
        if std::env::var_os("FIRMLINKS_TWICE").is_some() { Vec::new() } else { firmlinks::duplicates(&root) };
    let opts = scan::ScanOptions { live, duplicates, ..Default::default() };
    let progress = scan::ScanProgress::default();
    let done = std::sync::atomic::AtomicBool::new(false);
    let start = Instant::now();
    let tree = std::thread::scope(|s| {
        if live {
            s.spawn(|| {
                let mut snapshots = 0;
                while !done.load(std::sync::atomic::Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    let t = Instant::now();
                    if let Some((tree, _)) = progress.live.snapshot(&root) {
                        snapshots += 1;
                        eprintln!("snapshot {snapshots}: {} nodes in {:?}", tree.nodes.len(), t.elapsed());
                    }
                }
            });
        }
        let tree = scan::scan_with_cache(&root, &opts, &progress, previous.as_ref()).unwrap();
        done.store(true, std::sync::atomic::Ordering::Relaxed);
        tree
    });
    let elapsed = start.elapsed();
    let r = tree.root().unwrap();
    println!(
        "{} files, {} dirs, {:.2} GB on disk, {} nodes kept, {} errors, {:?}{}",
        r.file_count,
        progress.dirs.load(std::sync::atomic::Ordering::Relaxed),
        r.size as f64 / 1e9,
        tree.nodes.len(),
        progress.errors.load(std::sync::atomic::Ordering::Relaxed),
        elapsed,
        if previous.is_some() { " (incremental)" } else { "" },
    );
    if let Some(f) = cache_file {
        let t = Instant::now();
        cache::save(&f, &tree).unwrap();
        println!("cache saved in {:?} ({} KB)", t.elapsed(), std::fs::metadata(&f).unwrap().len() / 1024);
    }
}
