import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:spaceman/app_model.dart';
import 'package:spaceman/src/rust/api/spaceman.dart';

import 'support/fake_core.dart';

void main() {
  final core = setUpFakes();
  late Directory tmp;
  late AppModel model;

  const files = {
    'a/one.bin': 400,
    'a/two.bin': 100,
    'b/three.bin': 300,
    '.Trash/old.zip': 50,
  };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('spaceman_test');
    PathProviderPlatform.instance = FakePathProvider(tmp.path);
    core.reset(root: '${tmp.path}/home', files: files);
    Directory(core.root).createSync();
    model = AppModel();
  });

  tearDown(() {
    model.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Lets the model run init, then finishes the scan it starts.
  Future<void> initAndScan() async {
    await model.init();
    core.scan!.add(scanUpdate(files: 4, done: true));
    await pumpEventQueue();
  }

  group('init', () {
    test('starts in the home folder and scans it', () async {
      await model.init();
      expect(model.root, core.root);
      expect(model.access, DiskAccess.full);
      expect(model.loadingCache, isFalse);
      expect(model.scanning, isTrue);
      expect(core.lastScan, (
        root: core.root,
        full: false,
        skipPromptingFolders: false,
      ));
      // No cached scan: nothing to show until the scan is done.
      expect(model.rootNode, isNull);
    });

    test('shows the cached scan right away', () async {
      core.cachedScanAt = 1234;
      await model.init();
      expect(model.scannedAt, 1234);
      expect(model.rootNode?.path, core.root);
    });

    test('without Full Disk Access skips folders that prompt', () async {
      core.fullDiskAccess = false;
      await model.init();
      expect(model.access, DiskAccess.limited);
      expect(core.lastScan?.skipPromptingFolders, isTrue);
    });

    test('remembers the folder and the view', () async {
      await model.init();
      final other = Directory('${tmp.path}/other')..createSync();
      await model.setRoot(other.path);
      await model.setTreemap(true);

      final again = AppModel();
      addTearDown(again.dispose);
      await again.init();
      expect(again.root, other.path);
      expect(again.treemap, isTrue);
    });

    test('forgets a remembered folder that is gone', () async {
      await model.init();
      final other = Directory('${tmp.path}/other')..createSync();
      await model.setRoot(other.path);
      other.deleteSync();

      final again = AppModel();
      addTearDown(again.dispose);
      await again.init();
      expect(again.root, core.root);
    });
  });

  group('scan', () {
    test('shows the live view, then the result', () async {
      await model.init();
      final changes = <bool>[];
      model.addListener(() => changes.add(model.live));

      core.scan!.add(scanUpdate(files: 2, live: true));
      await pumpEventQueue();
      expect(model.live, isTrue);
      expect(model.rootNode?.path, core.root);
      expect(model.progress?.files, 2);

      core.cachedScanAt = 99;
      core.suggestionList = [suggestion(core, '${core.root}/a')];
      core.scan!.add(scanUpdate(files: 4, done: true));
      await pumpEventQueue();
      expect(model.live, isFalse);
      expect(model.scanning, isFalse);
      expect(model.scannedAt, 99);
      expect(model.suggestions, hasLength(1));
      expect(model.loadingSuggestions, isFalse);
      expect(changes, isNotEmpty);
    });

    test('reports errors', () async {
      await model.init();
      core.scan!.add(scanUpdate(done: true, error: 'cannot read /x'));
      await pumpEventQueue();
      expect(model.lastError, 'cannot read /x');
      expect(model.scanning, isFalse);

      model.scan();
      expect(model.lastError, isNull);
      core.scan!.addError(Exception('boom'));
      await pumpEventQueue();
      expect(model.lastError, contains('boom'));
      expect(model.scanning, isFalse);
    });

    test('a full rescan ignores the cache', () async {
      await initAndScan();
      model.scan(full: true);
      expect(core.lastScan?.full, isTrue);
    });

    test('stopping waits for the scanner', () async {
      await model.init();
      model.cancelScan();
      expect(model.stopping, isTrue);
      expect(core.cancelledScans, 1);
      core.scan!.add(scanUpdate(done: true, partial: true));
      await pumpEventQueue();
      expect(model.stopping, isFalse);
    });

    test('does not scan while access is undecided', () async {
      await initAndScan();
      model.showAccessIntro();
      expect(model.access, DiskAccess.undecided);
      core.lastScan = null;
      model.scan();
      expect(core.lastScan, isNull);
      model.chooseLimitedAccess();
      expect(model.access, DiskAccess.limited);
    });

    test('rescans once access is granted', () async {
      core.fullDiskAccess = false;
      await initAndScan();
      expect(await model.recheckAccess(), isFalse);
      core.fullDiskAccess = true;
      expect(await model.recheckAccess(), isTrue);
      expect(model.access, DiskAccess.full);
      expect(core.lastScan?.skipPromptingFolders, isFalse);
    });

    test('keeps the open folder when ids change', () async {
      await initAndScan();
      final b = core.node('${core.root}/b');
      model.open(b.id);
      expect(model.currentId, b.id);
      // The folder before it in the list goes away, so b gets a new id.
      core.remove('${core.root}/a');
      model.scan();
      core.scan!.add(scanUpdate(done: true));
      await pumpEventQueue();
      expect(model.currentId, core.idOf('${core.root}/b'));
      expect(model.currentId, isNot(b.id));

      // Gone altogether: back to the top.
      core.remove('${core.root}/b');
      model.scan();
      core.scan!.add(scanUpdate(done: true));
      await pumpEventQueue();
      expect(model.currentId, 0);
    });
  });

  group('selection', () {
    setUp(() => core.cachedScanAt = 1);

    test('counts nested items once', () async {
      await initAndScan();
      model.setSelected(core.node('${core.root}/a'), true);
      model.setSelected(core.node('${core.root}/a/one.bin'), true);
      model.setSelected(core.node('${core.root}/b'), true);
      expect(model.isSelected('${core.root}/a/one.bin'), isTrue);
      expect(model.selectionRoots.map((n) => n.path), [
        '${core.root}/a',
        '${core.root}/b',
      ]);
      expect(model.selectionSize, 800);

      model.setSelected(core.node('${core.root}/a'), false);
      expect(model.selectionSize, 700);
      model.clearSelection();
      expect(model.selection, isEmpty);
    });

    test('knows when the Trash would be emptied', () async {
      core.suggestionList = [
        suggestion(
          core,
          '${core.root}/.Trash',
          removal: RemovalMode.emptyTrash,
          category: SuggestionCategory.trash,
        ),
      ];
      await initAndScan();
      model.setSelected(core.node('${core.root}/a'), true);
      expect(model.selectionEmptiesTrash, isFalse);
      model.setSelected(core.node('${core.root}/.Trash'), true);
      expect(model.selectionEmptiesTrash, isTrue);
    });

    test('protecting unticks what it covers', () async {
      await initAndScan();
      model.setSelected(core.node('${core.root}/a/one.bin'), true);
      model.setSelected(core.node('${core.root}/b'), true);
      model.protect('${core.root}/a');
      expect(model.protectedPaths, ['${core.root}/a']);
      expect(model.selection.keys, ['${core.root}/b']);

      model.unprotect('${core.root}/a');
      expect(model.protectedPaths, isEmpty);

      model.protectSelection();
      expect(model.protectedPaths, ['${core.root}/b']);
      expect(model.selection, isEmpty);
    });

    test('removing reports progress and unticks what is gone', () async {
      await initAndScan();
      model.setSelected(core.node('${core.root}/a'), true);
      model.setSelected(core.node('${core.root}/a/one.bin'), true);
      model.setSelected(core.node('${core.root}/b'), true);
      core.deleteSteps = [
        const DeleteProgress(
          done: 0,
          total: 2,
          freed: 0,
          filesDone: 0,
          filesTotal: 3,
          current: '/x',
        ),
      ];
      core.deleteReport = (paths) => DeleteReport(
        deleted: [paths.first],
        freed: 500,
        failed: [FailedDelete(path: paths.last, reason: 'in use')],
      );
      final steps = <DeleteProgress>[];
      final report = await model.deleteSelection(
        permanent: true,
        onProgress: steps.add,
      );
      expect(core.deleted, ['${core.root}/a', '${core.root}/b']);
      expect(core.deletedPermanently, isTrue);
      expect(steps.single.filesTotal, 3);
      expect(report.freed, 500);
      // What failed stays ticked, so the user can try again.
      expect(model.selection.keys, ['${core.root}/b']);
    });

    test('delete removes paths and reloads', () async {
      await initAndScan();
      final report = await model.delete(['${core.root}/b']);
      expect(report.freed, 300);
      expect(core.deletedPermanently, isFalse);
      expect(model.rootNode?.size, 550);
    });
  });

  test('changing the folder starts over', () async {
    core.cachedScanAt = 1;
    await initAndScan();
    model.open(core.idOf('${core.root}/a'));
    model.setSelected(core.node('${core.root}/b'), true);
    final other = Directory('${tmp.path}/other')..createSync();

    await model.setRoot(core.root);
    expect(core.lastScan?.root, core.root);

    await model.setRoot(other.path);
    expect(model.root, other.path);
    expect(model.currentId, 0);
    expect(model.suggestions, isEmpty);
    expect(core.lastScan?.root, other.path);
    // The cache belongs to another folder.
    expect(model.scannedAt, isNull);
    expect(model.rootNode, isNull);
  });

  test('disk space of the scanned folder', () async {
    expect(model.diskSpace, isNull);
    core.disk = const DiskSpace(total: 1000, free: 400);
    await model.init();
    expect(model.diskSpace?.free, 400);
  });
}
