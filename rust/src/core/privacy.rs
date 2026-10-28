//! macOS privacy protection (TCC). Without Full Disk Access, entering some
//! folders makes macOS show a permission prompt for each of them. We let the
//! user grant Full Disk Access up front, or scan without those folders.

use std::path::{Path, PathBuf};

/// Whether the app may read everything. Always true outside macOS.
#[cfg(target_os = "macos")]
pub fn has_full_disk_access() -> bool {
    // Readable only with Full Disk Access; failing to open it never
    // triggers a prompt.
    std::fs::File::open("/Library/Application Support/com.apple.TCC/TCC.db").is_ok()
}

#[cfg(not(target_os = "macos"))]
pub fn has_full_disk_access() -> bool {
    true
}

/// Folders under `home` that trigger a permission prompt without Full Disk
/// Access. Empty outside macOS.
pub fn prompting_folders(home: &Path) -> Vec<PathBuf> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    [
        "Desktop",
        "Documents",
        "Downloads",
        "Pictures/Photos Library.photoslibrary",
        "Music/Music",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Application Support/AddressBook",
        "Library/Calendars",
        "Library/Reminders",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
    ]
    .iter()
    .map(|rel| home.join(rel))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompting_folders_are_macos_only() {
        let folders = prompting_folders(Path::new("/Users/u"));
        if cfg!(target_os = "macos") {
            assert!(folders.contains(&PathBuf::from("/Users/u/Desktop")));
            assert!(folders.iter().all(|f| f.starts_with("/Users/u")));
        } else {
            assert!(folders.is_empty());
            assert!(has_full_disk_access());
        }
    }
}
