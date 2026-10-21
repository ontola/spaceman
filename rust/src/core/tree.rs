//! Flat, arena-backed representation of a scanned directory tree.
//!
//! Directories are always stored. Files are stored individually only when
//! they are at least [`crate::core::scan::ScanOptions::min_file_size`] bytes;
//! smaller files are folded into a single "aggregate" child per directory so
//! that scanning millions of files stays cheap in memory.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub type NodeId = u32;

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
