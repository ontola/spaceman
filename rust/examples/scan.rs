//! Benchmark the scanner from the command line:
//! `cargo run --release --example scan -- <dir> [cache-file]`
//!
//! With a cache file, the second run reuses unchanged directories.

use std::path::PathBuf;
use std::time::Instant;

use rust_lib_spaceman::core::{cache, scan};

fn main() {
    let mut args = std::env::args().skip(1);
    let root = PathBuf::from(args.next().expect("usage: scan <dir> [cache-file]"));
    let cache_file = args.next().map(PathBuf::from);
    let previous = cache_file.as_deref().and_then(cache::load);

    let progress = scan::ScanProgress::default();
    let start = Instant::now();
    let tree = scan::scan_with_cache(&root, &Default::default(), &progress, previous.as_ref()).unwrap();
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
