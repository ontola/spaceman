//! The "do not touch" list: paths the user never wants suggested or deleted.
//!
//! Protection applies to the path itself and everything below it. Deleting
//! an ancestor of a protected path is refused too, since it would take the
//! protected path with it.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protection {
    None,
    /// The path itself, or one of its ancestors, is protected.
    Protected,
    /// Something inside this directory is protected.
    ContainsProtected,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ProtectList {
    paths: Vec<PathBuf>,
    #[serde(skip)]
    file: Option<PathBuf>,
}

impl ProtectList {
    /// Loads the list from `file`, starting empty when it does not exist yet.
    pub fn load(file: PathBuf) -> Self {
        let mut list: ProtectList = fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        list.file = Some(file);
        list
    }

    pub fn paths(&self) -> &[PathBuf] {
        &self.paths
    }

    pub fn add(&mut self, path: PathBuf) -> std::io::Result<()> {
        if !self.paths.contains(&path) {
            self.paths.push(path);
            self.paths.sort();
        }
        self.save()
    }

    pub fn remove(&mut self, path: &Path) -> std::io::Result<()> {
        self.paths.retain(|p| p != path);
        self.save()
    }

    pub fn check(&self, path: &Path) -> Protection {
        let mut result = Protection::None;
        for p in &self.paths {
            if path.starts_with(p) {
                return Protection::Protected;
            }
            if p.starts_with(path) {
                result = Protection::ContainsProtected;
            }
        }
        result
    }

    /// True when deleting `path` would touch something protected.
    pub fn blocks_delete(&self, path: &Path) -> bool {
        self.check(path) != Protection::None
    }

    fn save(&self) -> std::io::Result<()> {
        let Some(file) = &self.file else { return Ok(()) };
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        // Write atomically so a crash never leaves a truncated list behind.
        let tmp = file.with_extension("json.tmp");
        fs::write(&tmp, json)?;
        fs::rename(tmp, file)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protection_covers_descendants_and_ancestors() {
        let mut list = ProtectList::default();
        list.add("/home/u/Photos".into()).unwrap();
        assert_eq!(list.check(Path::new("/home/u/Photos")), Protection::Protected);
        assert_eq!(list.check(Path::new("/home/u/Photos/2024/a.jpg")), Protection::Protected);
        assert_eq!(list.check(Path::new("/home/u")), Protection::ContainsProtected);
        assert_eq!(list.check(Path::new("/home/u/Photoshop")), Protection::None);
        assert!(list.blocks_delete(Path::new("/home")));
        assert!(!list.blocks_delete(Path::new("/home/u/Music")));
    }

    #[test]
    fn persists_to_disk() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("cfg/protected.json");
        let mut list = ProtectList::load(file.clone());
        list.add("/a".into()).unwrap();
        list.add("/b".into()).unwrap();
        list.remove(Path::new("/a")).unwrap();
        let again = ProtectList::load(file);
        assert_eq!(again.paths(), &[PathBuf::from("/b")]);
    }
}
