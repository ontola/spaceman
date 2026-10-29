//! macOS keeps the user's data on its own APFS volume, mounted at
//! /System/Volumes/Data and "firmlinked" into the read-only system volume:
//! /Users is the same folder as /System/Volumes/Data/Users, on the same
//! device. A scan that contains both would count those folders twice.

use std::path::{Path, PathBuf};

const DATA_VOLUME: &str = "/System/Volumes/Data";

/// Used when /usr/share/firmlinks can not be read (the list of macOS 26).
const BUILT_IN: &str = "/AppleInternal\tAppleInternal
/Applications\tApplications
/Library\tLibrary
/System/Library/Caches\tSystem/Library/Caches
/System/Library/Assets\tSystem/Library/Assets
/System/Library/PreinstalledAssets\tSystem/Library/PreinstalledAssets
/System/Library/AssetsV2\tSystem/Library/AssetsV2
/System/Library/PreinstalledAssetsV2\tSystem/Library/PreinstalledAssetsV2
/System/Library/CoreServices/CoreTypes.bundle/Contents/Library\tSystem/Library/CoreServices/CoreTypes.bundle/Contents/Library
/System/Library/Speech\tSystem/Library/Speech
/Users\tUsers
/Volumes\tVolumes
/cores\tcores
/opt\topt
/pkg\tpkg
/private\tprivate
/usr/local\tusr/local
/usr/libexec/cups\tusr/libexec/cups
/usr/share/snmp\tusr/share/snmp
";

/// The folders under the Data volume that a scan of `root` also reaches
/// through their firmlink, so it should not enter them a second time.
/// Empty outside macOS.
pub fn duplicates(root: &Path) -> Vec<PathBuf> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    let list = std::fs::read_to_string("/usr/share/firmlinks").ok();
    duplicates_in(root, Path::new("/"), Path::new(DATA_VOLUME), list.as_deref().unwrap_or(BUILT_IN))
}

/// [`duplicates`] for a system rooted at `system`, with its Data volume at
/// `data` and `firmlinks` in the format of /usr/share/firmlinks: the
/// firmlink, a tab, and its target relative to the Data volume.
fn duplicates_in(root: &Path, system: &Path, data: &Path, firmlinks: &str) -> Vec<PathBuf> {
    // Scanning the Data volume itself (or a folder in it) sees it once.
    if !data.starts_with(root) || data == root {
        return Vec::new();
    }
    firmlinks
        .lines()
        .filter_map(|line| {
            let (link, target) = line.split_once('\t')?;
            let link = system.join(link.trim().trim_start_matches('/'));
            // Only when the scan also gets there the other way.
            link.starts_with(root).then(|| data.join(target.trim()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "/Users\tUsers\n/System/Library/Caches\tSystem/Library/Caches\n";

    fn dups(root: &str) -> Vec<PathBuf> {
        duplicates_in(Path::new(root), Path::new("/"), Path::new("/System/Volumes/Data"), LIST)
    }

    #[test]
    fn skips_data_volume_copies_seen_through_firmlinks() {
        assert_eq!(
            dups("/"),
            [PathBuf::from("/System/Volumes/Data/Users"), PathBuf::from("/System/Volumes/Data/System/Library/Caches")]
        );
        // /Users is not inside /System, so its Data copy is the only one.
        assert_eq!(dups("/System"), [PathBuf::from("/System/Volumes/Data/System/Library/Caches")]);
        assert!(dups("/System/Volumes/Data").is_empty());
        assert!(dups("/Users").is_empty());
        assert!(dups("/System/Volumes/Data/Users").is_empty());
    }

    #[test]
    fn built_in_list_parses() {
        let d = duplicates_in(Path::new("/"), Path::new("/"), Path::new(DATA_VOLUME), BUILT_IN);
        assert!(d.contains(&PathBuf::from("/System/Volumes/Data/Users")));
        assert!(d.contains(&PathBuf::from("/System/Volumes/Data/usr/local")));
        assert_eq!(d.len(), BUILT_IN.lines().count());
    }
}
