//! Cleanup suggestions: rules that recognise space which can safely be
//! reclaimed (caches, build output, trash) or is worth a second look
//! (very large files).

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::protect::{ProtectList, Protection};
use super::tree::{NodeId, NodeKind, Tree};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Category {
    Cache,
    BuildOutput,
    Trash,
    Logs,
    Downloads,
    Backups,
    LargeOldFile,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Safety {
    /// Regenerated automatically when needed; removing it loses nothing.
    Safe,
    /// Probably not needed, but the user should take a look first.
    Review,
}

#[derive(Debug, Clone)]
pub struct Suggestion {
    pub node: NodeId,
    pub path: PathBuf,
    pub size: u64,
    pub title: String,
    pub reason: String,
    pub category: Category,
    pub safety: Safety,
    pub removal: Removal,
}

/// Well-known folders (caches, trash) smaller than this are not worth
/// the user's attention.
const MIN_SIZE: u64 = 50 * 1024 * 1024;
/// Project build output is everywhere; only bigger chunks are listed.
const MIN_BUILD_OUTPUT: u64 = 100 * 1024 * 1024;
/// Single files at least this big are worth a look, whatever they are.
const LARGE_FILE: u64 = 1024 * 1024 * 1024;

/// How a suggested directory is cleaned up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Removal {
    /// The directory itself goes to the trash.
    Whole,
    /// The directory stays (apps or the OS expect it), its contents go.
    Contents,
    /// The directory is the trash: its contents are deleted for good.
    EmptyTrash,
}

/// A directory at a fixed location relative to the home directory.
struct HomeRule {
    rel: &'static str,
    removal: Removal,
    title: &'static str,
    reason: &'static str,
    category: Category,
    safety: Safety,
}

/// A directory recognised by its name, wherever it lives. Only matched when
/// `marker` (a sibling file, if any) exists, so we do not flag a random
/// folder that happens to be called "build".
struct NameRule {
    name: &'static str,
    marker: Option<&'static str>,
    title: &'static str,
    reason: &'static str,
    category: Category,
    safety: Safety,
}

use Category::*;
use Removal::*;
use Safety::*;

#[cfg(target_os = "macos")]
const HOME_RULES: &[HomeRule] = &[
    HomeRule { rel: ".Trash", removal: EmptyTrash, title: "Trash", reason: "Files in the Trash still take up space until it is emptied.", category: Trash, safety: Review },
    HomeRule { rel: "Library/Developer/Xcode/DerivedData", removal: Contents, title: "Xcode DerivedData", reason: "Xcode build intermediates. Xcode rebuilds them when needed.", category: BuildOutput, safety: Safe },
    HomeRule { rel: "Library/Developer/Xcode/iOS DeviceSupport", removal: Contents, title: "iOS device support files", reason: "Debug symbols for connected devices. Downloaded again when you connect a device.", category: Cache, safety: Safe },
    HomeRule { rel: "Library/Developer/Xcode/Archives", removal: Contents, title: "Xcode archives", reason: "Old app archives. Keep the ones you may need to symbolicate crash reports.", category: BuildOutput, safety: Review },
    HomeRule { rel: "Library/Developer/CoreSimulator/Caches", removal: Contents, title: "Simulator caches", reason: "Caches for the iOS Simulator, recreated automatically.", category: Cache, safety: Safe },
    HomeRule { rel: "Library/Developer/CoreSimulator/Devices", removal: Whole, title: "iOS Simulator devices", reason: "Simulator devices and their apps. Remove unused ones with `xcrun simctl delete unavailable`.", category: Cache, safety: Review },
    HomeRule { rel: "Library/Caches", removal: Contents, title: "App caches", reason: "Apps store temporary data here and recreate it when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "Library/Logs", removal: Contents, title: "Logs", reason: "Old log files from apps and the system.", category: Logs, safety: Safe },
    HomeRule { rel: "Library/Application Support/MobileSync/Backup", removal: Whole, title: "iPhone and iPad backups", reason: "Local device backups. Remove old ones if you back up to iCloud.", category: Backups, safety: Review },
    HomeRule { rel: "Library/Containers/com.docker.docker/Data", removal: Whole, title: "Docker data", reason: "Docker images and volumes. Prefer `docker system prune` to clean up.", category: Cache, safety: Review },
];

#[cfg(target_os = "windows")]
const HOME_RULES: &[HomeRule] = &[
    HomeRule { rel: "AppData/Local/Temp", removal: Contents, title: "Temporary files", reason: "Temporary files left behind by apps and installers.", category: Cache, safety: Safe },
    HomeRule { rel: "AppData/Local/Microsoft/Windows/INetCache", removal: Contents, title: "Internet cache", reason: "Cached web content, downloaded again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "AppData/Local/CrashDumps", removal: Contents, title: "Crash dumps", reason: "Memory dumps from crashed apps.", category: Logs, safety: Safe },
    HomeRule { rel: "AppData/Local/Docker", removal: Whole, title: "Docker data", reason: "Docker images and volumes. Prefer `docker system prune` to clean up.", category: Cache, safety: Review },
];

// On Android "home" is shared storage (/storage/emulated/0).
#[cfg(target_os = "android")]
const HOME_RULES: &[HomeRule] = &[
    HomeRule { rel: "DCIM/.thumbnails", removal: Contents, title: "Photo thumbnails", reason: "Small previews of your photos. The gallery recreates them when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "Pictures/.thumbnails", removal: Contents, title: "Picture thumbnails", reason: "Small previews of your pictures. Recreated when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "Android/media/com.whatsapp/WhatsApp/Media/.Statuses", removal: Contents, title: "WhatsApp statuses", reason: "Statuses you viewed, kept for a day.", category: Cache, safety: Safe },
];

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "android")))]
const HOME_RULES: &[HomeRule] = &[
    HomeRule { rel: ".local/share/Trash/files", removal: EmptyTrash, title: "Trash", reason: "Files in the Trash still take up space until it is emptied.", category: Trash, safety: Review },
];

/// Cross-platform developer and package manager caches.
const COMMON_HOME_RULES: &[HomeRule] = &[
    HomeRule { rel: ".cache", removal: Contents, title: "Tool caches", reason: "Command line tools keep downloads and caches here (pip, uv, Hugging Face, ...). They fetch them again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".pnpm-store", removal: Whole, title: "pnpm store", reason: "Downloaded npm packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "Library/pnpm/store", removal: Whole, title: "pnpm store", reason: "Downloaded npm packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".yarn/berry/cache", removal: Whole, title: "Yarn cache", reason: "Downloaded npm packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".bun/install/cache", removal: Whole, title: "Bun cache", reason: "Downloaded packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "go/pkg/mod", removal: Whole, title: "Go module cache", reason: "Downloaded Go modules, fetched again when needed. Prefer `go clean -modcache`.", category: Cache, safety: Safe },
    HomeRule { rel: ".nuget/packages", removal: Whole, title: "NuGet cache", reason: "Downloaded .NET packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".npm/_cacache", removal: Whole, title: "npm cache", reason: "Downloaded npm packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".gradle/caches", removal: Whole, title: "Gradle cache", reason: "Downloaded dependencies and build caches for Gradle.", category: Cache, safety: Safe },
    HomeRule { rel: ".cargo/registry/cache", removal: Whole, title: "Cargo download cache", reason: "Downloaded Rust crates, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".pub-cache", removal: Whole, title: "Dart pub cache", reason: "Downloaded Dart and Flutter packages, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: ".m2/repository", removal: Whole, title: "Maven repository", reason: "Downloaded Java dependencies, fetched again when needed.", category: Cache, safety: Safe },
    HomeRule { rel: "Downloads", removal: Contents, title: "Downloads", reason: "Installers and files you downloaded. Often no longer needed.", category: Downloads, safety: Review },
];

const NAME_RULES: &[NameRule] = &[
    NameRule { name: "node_modules", marker: Some("package.json"), title: "node_modules", reason: "JavaScript dependencies. Restore with `npm install`.", category: BuildOutput, safety: Safe },
    NameRule { name: "target", marker: Some("Cargo.toml"), title: "Rust build output", reason: "Compiled Rust artifacts. Rebuilt by `cargo build`.", category: BuildOutput, safety: Safe },
    NameRule { name: "build", marker: Some("pubspec.yaml"), title: "Flutter build output", reason: "Compiled Flutter artifacts. Rebuilt by `flutter build`.", category: BuildOutput, safety: Safe },
    NameRule { name: ".dart_tool", marker: Some("pubspec.yaml"), title: "Dart tool cache", reason: "Generated by the Dart tooling, recreated by `flutter pub get`.", category: BuildOutput, safety: Safe },
    NameRule { name: "Pods", marker: Some("Podfile"), title: "CocoaPods", reason: "iOS dependencies. Restore with `pod install`.", category: BuildOutput, safety: Safe },
    NameRule { name: ".next", marker: Some("package.json"), title: "Next.js build output", reason: "Rebuilt by `next build`.", category: BuildOutput, safety: Safe },
    NameRule { name: ".gradle", marker: Some("settings.gradle"), title: "Gradle project cache", reason: "Recreated on the next Gradle build.", category: BuildOutput, safety: Safe },
    NameRule { name: ".venv", marker: None, title: "Python virtualenv", reason: "Python environment. Recreate it from requirements if you still use the project.", category: BuildOutput, safety: Review },
    NameRule { name: "__pycache__", marker: None, title: "Python bytecode cache", reason: "Recreated automatically by Python.", category: BuildOutput, safety: Safe },
];

pub fn suggest(tree: &Tree, home: Option<&Path>, protect: &ProtectList) -> Vec<Suggestion> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut out = Vec::new();
    let mut stack = vec![Tree::ROOT];
    while let Some(id) = stack.pop() {
        let Some(node) = tree.get(id) else { continue };
        if node.size < MIN_SIZE.min(LARGE_FILE) || node.kind == NodeKind::Aggregate {
            continue;
        }
        let path = tree.path(id);
        let protection = protect.check(&path);
        if protection == Protection::Protected {
            continue;
        }

        if node.kind == NodeKind::File {
            if node.size >= LARGE_FILE {
                let days = if node.modified > 0 { (now - node.modified) / 86400 } else { -1 };
                out.push(Suggestion {
                    node: id,
                    size: node.size,
                    title: node.name.to_string(),
                    reason: match days {
                        d if d < 0 => "Very large file.".to_string(),
                        0 => "Very large file, changed today.".to_string(),
                        1 => "Very large file, last changed yesterday.".to_string(),
                        d => format!("Very large file, last changed {d} days ago."),
                    },
                    category: LargeOldFile,
                    safety: Review,
                    removal: Whole,
                    path,
                });
            }
            continue;
        }

        // A directory containing something protected can't be suggested as a
        // whole, but its other children still can.
        if protection == Protection::None {
            if let Some(s) = match_dir(id, &path, &node.name, node.size, home) {
                let min = if s.category == BuildOutput { MIN_BUILD_OUTPUT } else { MIN_SIZE };
                if s.size >= min {
                    out.push(s);
                }
                // Never look inside a match: no nested duplicates.
                continue;
            }
        }
        stack.extend(node.children.iter().copied());
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.size));
    out
}

/// How removing `path` should be done: some well-known folders must be
/// emptied rather than removed themselves.
pub fn removal_for(path: &Path, home: Option<&Path>) -> Removal {
    let Some(rel) = home.and_then(|h| path.strip_prefix(h).ok()) else { return Whole };
    HOME_RULES
        .iter()
        .chain(COMMON_HOME_RULES)
        .find(|r| rel == Path::new(r.rel))
        .map_or(Whole, |r| r.removal)
}

fn match_dir(id: NodeId, path: &Path, name: &str, size: u64, home: Option<&Path>) -> Option<Suggestion> {
    let make = |title: &str, reason: &str, category, safety, removal| Suggestion {
        node: id,
        path: path.to_path_buf(),
        size,
        title: title.to_string(),
        reason: reason.to_string(),
        category,
        safety,
        removal,
    };
    if let Some(rel) = home.and_then(|h| path.strip_prefix(h).ok()) {
        for r in HOME_RULES.iter().chain(COMMON_HOME_RULES) {
            if rel == Path::new(r.rel) {
                return Some(make(r.title, r.reason, r.category, r.safety, r.removal));
            }
        }
    }
    for r in NAME_RULES {
        if r.name != name {
            continue;
        }
        let ok = match (r.marker, path.parent()) {
            (None, _) => true,
            (Some(m), Some(parent)) => parent.join(m).exists(),
            (Some(_), None) => false,
        };
        if ok {
            return Some(make(r.title, r.reason, r.category, r.safety, Whole));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::scan::{scan, ScanOptions, ScanProgress};
    use std::fs;

    fn write(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![1u8; bytes]).unwrap();
    }

    #[test]
    fn well_known_folders_are_emptied_not_removed() {
        let home = Path::new("/home/u");
        assert_eq!(removal_for(&home.join("Downloads"), Some(home)), Contents);
        assert_eq!(removal_for(&home.join("Downloads/x.zip"), Some(home)), Whole);
        assert_eq!(removal_for(&home.join(".npm/_cacache"), Some(home)), Whole);
        assert_eq!(removal_for(Path::new("/elsewhere/Downloads"), Some(home)), Whole);
    }

    #[test]
    fn finds_build_output_and_respects_protection() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        write(&home.join("code/app/package.json"), 10);
        write(&home.join("code/app/node_modules/x/big.bin"), 101 * 1024 * 1024);
        write(&home.join("code/lib/Cargo.toml"), 10);
        write(&home.join("code/lib/target/debug/big.bin"), 101 * 1024 * 1024);
        // Named "target" but not a Rust project: must not be flagged.
        write(&home.join("code/other/target/big.bin"), 101 * 1024 * 1024);
        write(&home.join(".npm/_cacache/big.bin"), 51 * 1024 * 1024);

        let tree = scan(home, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        let mut protect = ProtectList::default();
        let found = suggest(&tree, Some(home), &protect);
        let paths: Vec<_> = found.iter().map(|s| s.path.clone()).collect();
        assert!(paths.contains(&home.join("code/app/node_modules")));
        assert!(paths.contains(&home.join("code/lib/target")));
        assert!(paths.contains(&home.join(".npm/_cacache")));
        assert!(!paths.contains(&home.join("code/other/target")));
        // Nested matches are not reported separately.
        assert!(!paths.iter().any(|p| p.starts_with(home.join("code/app/node_modules/x"))));

        protect.add(home.join("code/lib")).unwrap();
        let found = suggest(&tree, Some(home), &protect);
        assert!(!found.iter().any(|s| s.path.starts_with(home.join("code/lib"))));

        // Protecting something inside a cache stops the cache as a whole from
        // being suggested.
        protect.add(home.join(".npm/_cacache/big.bin")).unwrap();
        let found = suggest(&tree, Some(home), &protect);
        assert!(!found.iter().any(|s| s.path == home.join(".npm/_cacache")));
    }
}
