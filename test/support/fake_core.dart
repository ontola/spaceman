import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:spaceman/src/rust/api/spaceman.dart';
import 'package:spaceman/src/rust/frb_generated.dart';

/// An in-memory stand-in for the Rust core: a scanned folder of [files]
/// (path relative to [root] -> size), with the protect list, suggestions,
/// scans and removals under the test's control.
class FakeCore implements RustLibApi {
  FakeCore._();

  /// The one fake of this test file. flutter_rust_bridge can only be set up
  /// once per isolate, so tests [reset] it instead of making a new one.
  static final FakeCore instance = () {
    final core = FakeCore._();
    RustLib.initMock(api: core);
    return core;
  }();

  String root = '/home/u';
  final _paths = <String>[];
  final _sizes = <String, int>{};
  final _dirs = <String>{};
  List<String> protectedList = [];
  List<SuggestionView> suggestionList = [];
  List<String> unreadable = [];
  DiskSpace? disk;
  bool fullDiskAccess = true;
  int? cachedScanAt;

  /// The scan the app starts next; the test adds updates to it.
  StreamController<ScanUpdate>? scan;
  ({String root, bool full, bool skipPromptingFolders})? lastScan;
  int cancelledScans = 0;

  /// Paths passed to the last removal, and what it reports.
  List<String>? deleted;
  bool? deletedPermanently;
  List<DeleteProgress> deleteSteps = [];
  DeleteReport Function(List<String> paths)? deleteReport;
  int cancelledDeletes = 0;

  void reset({String root = '/home/u', Map<String, int> files = const {}}) {
    this.root = root;
    _paths
      ..clear()
      ..add(root);
    _sizes.clear();
    _dirs
      ..clear()
      ..add(root);
    for (final MapEntry(key: rel, value: size) in files.entries) {
      _add('$root/$rel', size);
    }
    protectedList = [];
    suggestionList = [];
    unreadable = [];
    disk = null;
    fullDiskAccess = true;
    cachedScanAt = null;
    scan = null;
    lastScan = null;
    cancelledScans = 0;
    deleted = null;
    deletedPermanently = null;
    deleteSteps = [];
    deleteReport = null;
    cancelledDeletes = 0;
  }

  void _add(String path, int size) {
    var p = path;
    while (true) {
      if (!_paths.contains(p)) _paths.add(p);
      _sizes[p] = (_sizes[p] ?? 0) + size;
      final parent = _parent(p);
      if (parent == null) break;
      _dirs.add(parent);
      p = parent;
    }
  }

  String? _parent(String path) {
    if (path == root) return null;
    return path.substring(0, path.lastIndexOf('/'));
  }

  void remove(String path) {
    final size = _sizes[path] ?? 0;
    _paths.removeWhere((p) => p == path || p.startsWith('$path/'));
    for (var p = _parent(path); p != null; p = _parent(p)) {
      _sizes[p] = (_sizes[p] ?? 0) - size;
    }
  }

  int idOf(String path) => _paths.indexOf(path);

  /// The node the core would hand out for [path].
  NodeView node(String path) {
    final kids = _paths.where((p) => _parent(p) == path);
    final protected = protectedList.any(
      (p) => path == p || path.startsWith('$p/'),
    );
    final contains = protectedList.any((p) => p.startsWith('$path/'));
    return NodeView(
      id: idOf(path),
      name: path == root ? root : path.substring(path.lastIndexOf('/') + 1),
      path: path,
      size: _sizes[path] ?? 0,
      fileCount: _paths
          .where((p) => !_dirs.contains(p) && p.startsWith('$path/'))
          .length,
      kind: _dirs.contains(path) ? EntryKind.dir : EntryKind.file,
      modified: 0,
      protection: protected
          ? ProtectionState.protected
          : contains
          ? ProtectionState.containsProtected
          : ProtectionState.none,
      hasChildren: kids.isNotEmpty,
      scanning: false,
    );
  }

  @override
  void crateApiSpacemanConfigure({
    required String configDir,
    required String cacheDir,
  }) {}

  @override
  bool crateApiSpacemanHasFullDiskAccess() => fullDiskAccess;

  @override
  String? crateApiSpacemanHomeDir() => root;

  @override
  Future<int?> crateApiSpacemanLoadCachedScan({required String root}) async =>
      root == this.root ? cachedScanAt : null;

  @override
  int? crateApiSpacemanScannedAt() => cachedScanAt;

  @override
  DiskSpace? crateApiSpacemanDiskSpace({required String path}) => disk;

  @override
  NodeView? crateApiSpacemanRootNode() =>
      _paths.isEmpty ? null : node(_paths.first);

  @override
  List<NodeView> crateApiSpacemanChildren({required int id}) {
    if (id < 0 || id >= _paths.length) return [];
    final path = _paths[id];
    return [
      for (final p in _paths)
        if (_parent(p) == path) node(p),
    ]..sort((a, b) => b.size.compareTo(a.size));
  }

  @override
  List<NodeView> crateApiSpacemanBreadcrumbs({required int id}) {
    if (id < 0 || id >= _paths.length) return [];
    final chain = <NodeView>[];
    for (String? p = _paths[id]; p != null; p = _parent(p)) {
      chain.insert(0, node(p));
    }
    return chain;
  }

  @override
  NodeView? crateApiSpacemanNodeAt({required String path}) =>
      _paths.contains(path) ? node(path) : null;

  @override
  List<String> crateApiSpacemanProtectedPaths() => [...protectedList];

  @override
  void crateApiSpacemanProtectPath({required String path}) {
    if (!protectedList.contains(path)) protectedList = [...protectedList, path];
  }

  @override
  void crateApiSpacemanUnprotectPath({required String path}) =>
      protectedList = protectedList.where((p) => p != path).toList();

  @override
  Future<List<SuggestionView>> crateApiSpacemanSuggestions() async =>
      suggestionList;

  @override
  List<String> crateApiSpacemanUnreadableFolders() => unreadable;

  @override
  Stream<ScanUpdate> crateApiSpacemanScanDir({
    required String root,
    required bool full,
    required bool skipPromptingFolders,
  }) {
    lastScan = (
      root: root,
      full: full,
      skipPromptingFolders: skipPromptingFolders,
    );
    scan = StreamController<ScanUpdate>();
    return scan!.stream;
  }

  @override
  void crateApiSpacemanCancelScan() => cancelledScans++;

  @override
  Stream<DeleteProgress> crateApiSpacemanDeletePathsWithProgress({
    required List<String> paths,
    required bool permanent,
  }) async* {
    final report = _delete(paths, permanent);
    for (final step in deleteSteps) {
      yield step;
    }
    yield DeleteProgress(
      done: paths.length,
      total: 0,
      freed: report.freed,
      filesDone: 0,
      filesTotal: 0,
      current: '',
      report: report,
    );
  }

  @override
  Future<DeleteReport> crateApiSpacemanDeletePaths({
    required List<String> paths,
    required bool permanent,
  }) async => _delete(paths, permanent);

  DeleteReport _delete(List<String> paths, bool permanent) {
    deleted = paths;
    deletedPermanently = permanent;
    final custom = deleteReport;
    if (custom != null) return custom(paths);
    var freed = 0;
    for (final p in paths) {
      freed += _sizes[p] ?? 0;
      remove(p);
    }
    return DeleteReport(deleted: paths, freed: freed, failed: const []);
  }

  @override
  void crateApiSpacemanCancelDelete() => cancelledDeletes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A scan update as the core streams them.
ScanUpdate scanUpdate({
  int files = 0,
  int bytes = 0,
  int elapsedMs = 0,
  bool done = false,
  bool partial = false,
  String? error,
  bool live = false,
}) => ScanUpdate(
  files: files,
  dirs: 0,
  bytes: bytes,
  errors: 0,
  elapsedMs: elapsedMs,
  done: done,
  partial: partial,
  error: error,
  live: live,
);

/// A suggestion for the node at [path] of [core].
SuggestionView suggestion(
  FakeCore core,
  String path, {
  String title = 'Cache',
  SuggestionCategory category = SuggestionCategory.cache,
  RemovalMode removal = RemovalMode.whole,
  bool safe = true,
}) => SuggestionView(
  node: core.node(path),
  removal: removal,
  title: title,
  reason: 'Because.',
  category: category,
  safe: safe,
);

/// path_provider pointing into [dir], so AppModel can keep its files there.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => '$dir/support';

  @override
  Future<String?> getApplicationCachePath() async => '$dir/cache';

  @override
  Future<String?> getApplicationDocumentsPath() async => '$dir/documents';
}

/// Sets up the fake core and path_provider for a test file.
FakeCore setUpFakes() {
  TestWidgetsFlutterBinding.ensureInitialized();
  return FakeCore.instance;
}
