import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'paths.dart';
import 'platform.dart';
import 'src/rust/api/spaceman.dart' as core;

/// How much of the disk the app may read without macOS permission prompts.
enum DiskAccess {
  /// Full Disk Access (macOS) or All files access (Android) granted, or
  /// another platform.
  full,

  /// The user chose to scan without the folders that need permission.
  limited,

  /// The user is reading how to grant Full Disk Access.
  undecided,
}

/// App-wide state. The scanned tree itself lives in Rust; this only keeps
/// track of what the UI is showing and forwards actions to the core.
class AppModel extends ChangeNotifier {
  late String _configDir;

  String root = '';
  core.NodeView? rootNode;

  /// Folder currently opened in the explorer.
  int currentId = 0;

  core.ScanUpdate? progress;
  bool get scanning => _scanSub != null;
  String? lastError;
  int? scannedAt;

  List<core.SuggestionView> suggestions = [];
  bool loadingSuggestions = false;

  List<String> protectedPaths = [];

  DiskAccess access = DiskAccess.full;

  StreamSubscription<core.ScanUpdate>? _scanSub;

  File get _lastRootFile => File('$_configDir/last_root.txt');
  File get _viewFile => File('$_configDir/explorer_view.txt');

  /// Explore shows a treemap instead of the list.
  bool treemap = false;

  Future<void> setTreemap(bool on) async {
    treemap = on;
    notifyListeners();
    try {
      await _viewFile.writeAsString(on ? 'treemap' : 'list');
    } on FileSystemException {
      // Not remembering the view is not worth bothering the user about.
    }
  }

  /// Loads settings and the cached scan, then refreshes it in the background.
  Future<void> init() async {
    _configDir = (await getApplicationSupportDirectory()).path;
    final cacheDir = (await getApplicationCacheDirectory()).path;
    core.configure(configDir: _configDir, cacheDir: cacheDir);
    protectedPaths = core.protectedPaths();
    // Without Full Disk Access, start with a scan that never makes macOS
    // prompt; the header offers to grant access. Android without access
    // would only see the app's own files, so explain that first.
    if (await hasDiskAccess()) {
      access = DiskAccess.full;
    } else {
      access = Platform.isAndroid ? DiskAccess.undecided : DiskAccess.limited;
    }

    try {
      treemap = (await _viewFile.readAsString()).trim() == 'treemap';
    } on FileSystemException {
      // First launch: the list.
    }
    root = await _initialRoot();
    notifyListeners();

    scannedAt = await core.loadCachedScan(root: root);
    if (scannedAt != null) _reloadTree();
    loadingCache = false;
    notifyListeners();
    // With a cache this only revisits changed folders, so it is quick.
    scan();
  }

  /// Still reading the cached scan at startup; there is nothing to say
  /// about the folder yet.
  bool loadingCache = true;

  Future<String> _initialRoot() async {
    try {
      final saved = (await _lastRootFile.readAsString()).trim();
      if (saved.isNotEmpty && Directory(saved).existsSync()) return saved;
    } on FileSystemException {
      // First launch.
    }
    if (Platform.isAndroid) {
      final storage = await androidStorageRoot();
      if (storage != null) return storage;
    }
    return core.homeDir() ?? (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> setRoot(String path) async {
    if (path == root) return;
    root = path;
    rootNode = null;
    currentId = 0;
    _currentPath = null;
    suggestions = [];
    try {
      await _lastRootFile.parent.create(recursive: true);
      await _lastRootFile.writeAsString(path);
    } on FileSystemException {
      // Not remembering the folder is not worth bothering the user about.
    }
    scannedAt = await core.loadCachedScan(root: path);
    if (scannedAt != null) _reloadTree();
    notifyListeners();
    scan();
  }

  /// Back from the explanation without granting access: keep scanning
  /// without the folders that make macOS ask for permission.
  void chooseLimitedAccess() {
    access = DiskAccess.limited;
    notifyListeners();
  }

  /// Goes back to the explanation, e.g. to grant Full Disk Access after all.
  void showAccessIntro() {
    access = DiskAccess.undecided;
    notifyListeners();
  }

  /// Checks again after the user visited System Settings. Returns whether
  /// access is now granted.
  Future<bool> recheckAccess() async {
    if (access == DiskAccess.full || !await hasDiskAccess()) return false;
    access = DiskAccess.full;
    notifyListeners();
    scan();
    return true;
  }

  /// Scans [root]. Unless [full] is set, unchanged folders come from cache.
  void scan({bool full = false}) {
    if (access == DiskAccess.undecided) return;
    _scanSub?.cancel();
    lastError = null;
    progress = null;
    _scanSub = core
        .scanDir(
          root: root,
          full: full,
          skipPromptingFolders: access == DiskAccess.limited,
        )
        .listen(
          (update) {
            progress = update;
            if (update.live) {
              live = true;
              rootNode = core.rootNode();
              _findCurrent();
            }
            if (update.done) {
              live = false;
              _scanSub = null;
              stopping = false;
              if (update.error != null) {
                lastError = update.error;
              } else {
                scannedAt = core.scannedAt();
                _reloadTree();
              }
            }
            notifyListeners();
          },
          onError: (Object e) {
            _scanSub = null;
            lastError = e.toString();
            notifyListeners();
          },
        );
    notifyListeners();
  }

  /// Set between pressing Stop and the scanner handing over its results.
  bool stopping = false;

  void cancelScan() {
    stopping = true;
    notifyListeners();
    core.cancelScan();
  }

  void _reloadTree() {
    rootNode = core.rootNode();
    _findCurrent();
    refreshSuggestions();
  }

  /// Keeps the user's place if that folder still exists.
  void _findCurrent() {
    final path = _currentPath;
    final id = rootNode == null || path == null
        ? null
        : core.nodeAt(path: path)?.id;
    if (id == null) {
      currentId = 0;
      // Not there yet in a live view: keep looking for it.
      if (!live) _currentPath = null;
    } else {
      currentId = id;
    }
  }

  Future<void> refreshSuggestions() async {
    loadingSuggestions = true;
    notifyListeners();
    suggestions = await core.suggestions();
    loadingSuggestions = false;
    notifyListeners();
  }

  /// Selected items by path, shared by Explore and Clean up.
  final Map<String, core.NodeView> selection = {};

  bool isSelected(String path) => selection.containsKey(path);

  void setSelected(core.NodeView node, bool on) {
    on ? selection[node.path] = node : selection.remove(node.path);
    notifyListeners();
  }

  void clearSelection() {
    selection.clear();
    notifyListeners();
  }

  /// The selection without items inside another selected folder, so
  /// nothing is counted or removed twice.
  List<core.NodeView> get selectionRoots {
    final paths = selection.keys.toList()..sort();
    final roots = <core.NodeView>[];
    String? last;
    for (final p in paths) {
      if (last != null && isInside(p, last)) continue;
      roots.add(selection[p]!);
      last = p;
    }
    return roots;
  }

  int get selectionSize =>
      selectionRoots.fold(0, (sum, node) => sum + node.size);

  /// Whether removing the selection empties the Trash for good.
  bool get selectionEmptiesTrash => suggestions.any(
    (sug) =>
        sug.removal == core.RemovalMode.emptyTrash &&
        selection.containsKey(sug.node.path),
  );

  /// Removes the selection, reporting progress to [onProgress] as it goes.
  Future<core.DeleteReport> deleteSelection({
    bool permanent = false,
    void Function(core.DeleteProgress)? onProgress,
  }) async {
    final paths = selectionRoots.map((n) => n.path).toList();
    late core.DeleteReport report;
    await for (final p in core.deletePathsWithProgress(
      paths: paths,
      permanent: permanent,
    )) {
      if (p.report != null) {
        report = p.report!;
      } else {
        onProgress?.call(p);
      }
    }
    _reloadTree();
    for (final p in report.deleted) {
      selection.removeWhere((key, _) => key == p || isInside(key, p));
    }
    notifyListeners();
    return report;
  }

  void protectSelection() {
    for (final node in selectionRoots) {
      core.protectPath(path: node.path);
    }
    selection.clear();
    _protectionChanged();
  }

  List<core.NodeView> children(int id) => core.children(id: id);
  List<core.NodeView> breadcrumbs(int id) => core.breadcrumbs(id: id);

  void open(int id) {
    currentId = id;
    _currentPath = id == 0 ? null : core.breadcrumbs(id: id).lastOrNull?.path;
    notifyListeners();
  }

  /// Path of the open folder, to find it again in a new tree (ids differ
  /// between the live view of a scan and its result).
  String? _currentPath;

  /// Showing the scan as it runs, not a finished one. Items can not be
  /// removed yet: their folders are not fully known.
  bool live = false;

  void protect(String path) {
    core.protectPath(path: path);
    // Protected items can not be removed, so they can not stay ticked.
    selection.removeWhere((key, _) => key == path || isInside(key, path));
    _protectionChanged();
  }

  void unprotect(String path) {
    core.unprotectPath(path: path);
    _protectionChanged();
  }

  void _protectionChanged() {
    protectedPaths = core.protectedPaths();
    rootNode = core.rootNode();
    notifyListeners();
    refreshSuggestions();
  }

  Future<core.DeleteReport> delete(
    List<String> paths, {
    bool permanent = false,
  }) async {
    final report = await core.deletePaths(paths: paths, permanent: permanent);
    _reloadTree();
    notifyListeners();
    return report;
  }

  core.DiskSpace? get diskSpace =>
      root.isEmpty ? null : core.diskSpace(path: root);

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }
}
