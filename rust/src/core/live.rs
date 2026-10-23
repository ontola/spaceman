//! A coarse view of a scan while it runs: the top few levels of folders,
//! with sizes that grow as the scanner gets through them. The UI shows it
//! when there is no earlier scan to show, so results appear right away.
//!
//! Cheap for the scanner: a node is created once per folder near the top,
//! and deeper folders add their bytes to the nearest such node with one
//! atomic add each.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use super::tree::{Node, NodeId, NodeKind, Tree};

/// Folders this many levels below the root, or less, get their own node.
pub const DEPTH: usize = 3;

#[derive(Debug, Default)]
pub struct LiveNode {
    /// Stable index in snapshots, so the UI can keep its place.
    pub id: NodeId,
    pub name: Box<str>,
    /// Bytes and files found in this folder and in deeper folders that
    /// have no node of their own; children's totals are not included.
    pub own_bytes: AtomicU64,
    pub own_files: AtomicU64,
    /// Everything below it has been scanned.
    pub done: AtomicBool,
    pub children: Mutex<Vec<Arc<LiveNode>>>,
}

/// The live tree of one scan.
#[derive(Debug, Default)]
pub struct LiveTree {
    next_id: AtomicU32,
    pub root: Mutex<Option<Arc<LiveNode>>>,
}

impl LiveTree {
    /// A node for a folder; the first one becomes the root.
    pub fn add(&self, parent: Option<&Arc<LiveNode>>, name: Box<str>) -> Arc<LiveNode> {
        let node = Arc::new(LiveNode {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            name,
            ..Default::default()
        });
        match parent {
            Some(p) => p.children.lock().unwrap().push(node.clone()),
            None => *self.root.lock().unwrap() = Some(node.clone()),
        }
        node
    }

    /// The tree as it is now, as a regular [`Tree`] whose node ids stay the
    /// same between snapshots, plus which nodes are still being scanned.
    pub fn snapshot(&self, root_path: &Path) -> Option<(Tree, Vec<bool>)> {
        let root = self.root.lock().unwrap().clone()?;
        let len = self.next_id.load(Ordering::Relaxed) as usize;
        // Ids handed out but not yet linked stay as removed placeholders.
        let mut nodes: Vec<Node> = (0..len)
            .map(|_| Node {
                name: "".into(),
                parent: None,
                kind: NodeKind::Dir,
                size: 0,
                file_count: 0,
                modified: 0,
                stamp: 0,
                children: Vec::new(),
                removed: true,
            })
            .collect();
        let mut pending = vec![false; len];
        fill(&root, None, &mut nodes, &mut pending);
        let tree = Tree {
            root_path: root_path.to_path_buf(),
            nodes,
            ..Default::default()
        };
        Some((tree, pending))
    }
}

/// Writes `n` and everything below it; returns its (size, files).
fn fill(
    n: &LiveNode,
    parent: Option<NodeId>,
    nodes: &mut Vec<Node>,
    pending: &mut Vec<bool>,
) -> (u64, u64) {
    let kids = n.children.lock().unwrap().clone();
    let mut size = n.own_bytes.load(Ordering::Relaxed);
    let mut files = n.own_files.load(Ordering::Relaxed);
    let mut ids = Vec::with_capacity(kids.len());
    for k in &kids {
        if (k.id as usize) < nodes.len() {
            let (s, f) = fill(k, Some(n.id), nodes, pending);
            size += s;
            files += f;
            ids.push(k.id);
        }
    }
    let i = n.id as usize;
    if i < nodes.len() {
        nodes[i] = Node {
            name: n.name.clone(),
            parent,
            kind: NodeKind::Dir,
            size,
            file_count: files,
            modified: 0,
            stamp: 0,
            children: ids,
            removed: false,
        };
        pending[i] = !n.done.load(Ordering::Relaxed);
    }
    (size, files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_sums_children_and_keeps_ids() {
        let live = LiveTree::default();
        let root = live.add(None, "".into());
        let a = live.add(Some(&root), "a".into());
        let b = live.add(Some(&a), "b".into());
        root.own_bytes.store(10, Ordering::Relaxed);
        a.own_bytes.store(5, Ordering::Relaxed);
        b.own_bytes.store(100, Ordering::Relaxed);
        b.done.store(true, Ordering::Relaxed);

        let (tree, pending) = live.snapshot(Path::new("/r")).unwrap();
        assert_eq!(tree.root().unwrap().size, 115);
        assert_eq!(tree.nodes[a.id as usize].size, 105);
        assert_eq!(tree.find(Path::new("/r/a/b")), Some(b.id));
        assert!(pending[a.id as usize] && !pending[b.id as usize]);

        // A new child later keeps the earlier ids.
        live.add(Some(&root), "c".into());
        let (tree, _) = live.snapshot(Path::new("/r")).unwrap();
        assert_eq!(tree.find(Path::new("/r/a/b")), Some(b.id));
    }
}
