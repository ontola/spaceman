import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api/spaceman.dart' as core;

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

  StreamSubscription<core.ScanUpdate>? _scanSub;

  File get _lastRootFile => File('$_configDir/last_root.txt');

  /// Loads settings and the cached scan, then refreshes it in the background.
  Future<void> init() async {
    _configDir = (await getApplicationSupportDirectory()).path;
    final cacheDir = (await getApplicationCacheDirectory()).path;
    core.configure(configDir: _configDir, cacheDir: cacheDir);
    protectedPaths = core.protectedPaths();

    root = await _initialRoot();
    notifyListeners();

    scannedAt = await core.loadCachedScan(root: root);
    if (scannedAt != null) _reloadTree();
    notifyListeners();
    // With a cache this only revisits changed folders, so it is quick.
    scan();
  }

  Future<String> _initialRoot() async {
    try {
      final saved = (await _lastRootFile.readAsString()).trim();
      if (saved.isNotEmpty && Directory(saved).existsSync()) return saved;
    } on FileSystemException {
      // First launch.
    }
    return core.homeDir() ?? (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> setRoot(String path) async {
    if (path == root) return;
    root = path;
    rootNode = null;
    currentId = 0;
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

  /// Scans [root]. Unless [full] is set, unchanged folders come from cache.
  void scan({bool full = false}) {
    _scanSub?.cancel();
    lastError = null;
    progress = null;
    _scanSub = core
        .scanDir(root: root, full: full)
        .listen(
          (update) {
            progress = update;
            if (update.done) {
              _scanSub = null;
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

  void cancelScan() {
    core.cancelScan();
  }

  void _reloadTree() {
    rootNode = core.rootNode();
    // Keep the user's place if that folder still exists.
    if (rootNode == null || core.breadcrumbs(id: currentId).isEmpty) {
      currentId = 0;
    }
    refreshSuggestions();
  }

  Future<void> refreshSuggestions() async {
    loadingSuggestions = true;
    notifyListeners();
    suggestions = await core.suggestions();
    loadingSuggestions = false;
    notifyListeners();
  }

  List<core.NodeView> children(int id) => core.children(id: id);
  List<core.NodeView> breadcrumbs(int id) => core.breadcrumbs(id: id);

  void open(int id) {
    currentId = id;
    notifyListeners();
  }

  void protect(String path) {
    core.protectPath(path: path);
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
