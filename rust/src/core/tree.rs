//! Flat, arena-backed representation of a scanned directory tree.
//!
//! Directories are always stored. Files are stored individually only when
//! they are at least [`crate::core::scan::ScanOptions::min_file_size`] bytes;
//! smaller files are folded into a single "aggregate" child per directory so
//! that scanning millions of files stays cheap in memory.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub type NodeId = u32;

/// The current time in seconds since the Unix epoch (0 if the clock is
/// before it).
pub fn unix_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Dir,
    File,
    /// Many small files in one directory, shown as a single entry.
    Aggregate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Node {
    pub name: Box<str>,
    pub parent: Option<NodeId>,
    pub kind: NodeKind,
    /// Bytes on disk, including all descendants.
    pub size: u64,
    /// Number of files, including all descendants.
    pub file_count: u64,
    /// Modification time in seconds since the Unix epoch (0 when unknown).
    pub modified: i64,
    /// High-resolution modification stamp of a directory, used to decide
    /// whether a cached listing can be reused on the next scan.
    pub stamp: u64,
    pub children: Vec<NodeId>,
    /// Set when the node was removed after the scan (e.g. moved to trash).
    pub removed: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Tree {
    pub root_path: PathBuf,
    /// When the scan finished, in seconds since the Unix epoch.
    pub scanned_at: i64,
    /// Directories left out of this scan (see `ScanOptions::skip`).
    pub skipped: Vec<PathBuf>,
    /// The scan was stopped early; folders it did not get to look empty.
    pub partial: bool,
    /// Folders that could not be read (capped, see `scan::MAX_UNREADABLE`).
    pub unreadable: Vec<PathBuf>,
    pub nodes: Vec<Node>,
}

impl Tree {
    pub const ROOT: NodeId = 0;

    pub fn get(&self, id: NodeId) -> Option<&Node> {
        self.nodes.get(id as usize).filter(|n| !n.removed)
    }

    pub fn root(&self) -> Option<&Node> {
        self.get(Self::ROOT)
    }

    /// Children sorted by size, largest first.
    pub fn sorted_children(&self, id: NodeId) -> Vec<NodeId> {
        let Some(node) = self.get(id) else { return vec![] };
        let mut kids: Vec<NodeId> = node
            .children
            .iter()
            .copied()
            .filter(|c| !self.nodes[*c as usize].removed)
            .collect();
        kids.sort_by(|a, b| self.nodes[*b as usize].size.cmp(&self.nodes[*a as usize].size));
        kids
    }

    /// Path of a node. Aggregate nodes resolve to their parent directory.
    pub fn path(&self, id: NodeId) -> PathBuf {
        let mut parts = Vec::new();
        let mut cur = Some(id);
        while let Some(c) = cur {
            let n = &self.nodes[c as usize];
            if c != Self::ROOT && n.kind != NodeKind::Aggregate {
                parts.push(&*n.name);
            }
            cur = n.parent;
        }
        let mut p = self.root_path.clone();
        for part in parts.iter().rev() {
            p.push(part);
        }
        p
    }

    /// Chain from the root down to (and including) `id`.
    pub fn ancestors(&self, id: NodeId) -> Vec<NodeId> {
        let mut chain = Vec::new();
        let mut cur = Some(id);
        while let Some(c) = cur {
            chain.push(c);
            cur = self.nodes.get(c as usize).and_then(|n| n.parent);
        }
        chain.reverse();
        chain
    }

    /// Finds the node for an absolute path, if it was scanned.
    pub fn find(&self, path: &Path) -> Option<NodeId> {
        let rel = path.strip_prefix(&self.root_path).ok()?;
        let mut cur = Self::ROOT;
        for comp in rel.components() {
            let name = comp.as_os_str().to_string_lossy();
            cur = *self.nodes[cur as usize].children.iter().find(|c| {
                let n = &self.nodes[**c as usize];
                !n.removed && n.kind != NodeKind::Aggregate && *n.name == *name
            })?;
        }
        Some(cur)
    }

    /// Marks a node as removed and subtracts its size from all ancestors.
    pub fn remove(&mut self, id: NodeId) {
        if id == Self::ROOT || self.get(id).is_none() {
            return;
        }
        let (size, files) = {
            let n = &self.nodes[id as usize];
            (n.size, n.file_count)
        };
        self.nodes[id as usize].removed = true;
        let mut cur = self.nodes[id as usize].parent;
        while let Some(c) = cur {
            let n = &mut self.nodes[c as usize];
            n.size = n.size.saturating_sub(size);
            n.file_count = n.file_count.saturating_sub(files);
            cur = n.parent;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(name: &str, parent: Option<NodeId>, kind: NodeKind, size: u64, children: &[NodeId]) -> Node {
        Node {
            name: name.into(),
            parent,
            kind,
            size,
            file_count: if kind == NodeKind::Dir { 0 } else { 1 },
            modified: 0,
            stamp: 0,
            children: children.to_vec(),
            removed: false,
        }
    }

    /// /r
    /// ├── a        (dir, 0)
    /// │   ├── f    (file, 1)
    /// │   └── ...  (small files, 2)
    /// └── b        (dir, 3)
    fn sample() -> Tree {
        let mut nodes = vec![
            node("", None, NodeKind::Dir, 160, &[1, 4]),
            node("a", Some(0), NodeKind::Dir, 150, &[2, 3]),
            node("f", Some(1), NodeKind::File, 100, &[]),
            node("2 smaller files", Some(1), NodeKind::Aggregate, 50, &[]),
            node("b", Some(0), NodeKind::Dir, 10, &[]),
        ];
        nodes[0].file_count = 4;
        nodes[1].file_count = 3;
        nodes[3].file_count = 2;
        Tree { root_path: "/r".into(), nodes, ..Default::default() }
    }

    #[test]
    fn paths_resolve_aggregates_to_their_folder() {
        let t = sample();
        assert_eq!(t.path(Tree::ROOT), Path::new("/r"));
        assert_eq!(t.path(2), Path::new("/r/a/f"));
        assert_eq!(t.path(3), Path::new("/r/a"));
    }

    #[test]
    fn find_skips_aggregates_and_unknown_paths() {
        let t = sample();
        assert_eq!(t.find(Path::new("/r")), Some(Tree::ROOT));
        assert_eq!(t.find(Path::new("/r/a/f")), Some(2));
        assert_eq!(t.find(Path::new("/r/a/2 smaller files")), None);
        assert_eq!(t.find(Path::new("/r/c")), None);
        assert_eq!(t.find(Path::new("/elsewhere")), None);
    }

    #[test]
    fn ancestors_run_from_the_root() {
        let t = sample();
        assert_eq!(t.ancestors(2), vec![0, 1, 2]);
        assert_eq!(t.ancestors(Tree::ROOT), vec![0]);
    }

    #[test]
    fn sorted_children_are_largest_first_without_removed() {
        let mut t = sample();
        assert_eq!(t.sorted_children(1), vec![2, 3]);
        assert_eq!(t.sorted_children(Tree::ROOT), vec![1, 4]);
        t.remove(2);
        assert_eq!(t.sorted_children(1), vec![3]);
        // A removed node has no children to show.
        t.remove(1);
        assert!(t.sorted_children(1).is_empty());
        assert!(t.get(1).is_none());
    }

    #[test]
    fn remove_subtracts_once_and_never_the_root() {
        let mut t = sample();
        t.remove(2);
        assert_eq!(t.nodes[1].size, 50);
        assert_eq!(t.nodes[1].file_count, 2);
        assert_eq!(t.root().unwrap().size, 60);
        assert_eq!(t.root().unwrap().file_count, 3);
        // Removing again changes nothing.
        t.remove(2);
        assert_eq!(t.root().unwrap().size, 60);
        t.remove(Tree::ROOT);
        assert!(t.root().is_some());
        assert_eq!(t.find(Path::new("/r/a/f")), None);
    }

    #[test]
    fn empty_tree_has_no_root() {
        let t = Tree::default();
        assert!(t.root().is_none());
        assert!(t.sorted_children(Tree::ROOT).is_empty());
    }

    #[test]
    fn unix_now_is_after_2020() {
        assert!(unix_now() > 1_577_836_800);
    }
}
