import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:spaceman/app_model.dart';
import 'package:spaceman/main.dart';
import 'package:spaceman/src/rust/api/spaceman.dart';
import 'package:spaceman/widgets/treemap.dart';

import 'support/fake_core.dart';

void main() {
  final core = setUpFakes();
  late Directory tmp;
  late AppModel model;

  String at(String rel) => '${core.root}/$rel';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('spaceman_widgets');
    PathProviderPlatform.instance = FakePathProvider(tmp.path);
    core.reset(
      root: '${tmp.path}/home',
      files: {
        'Movies/film.mkv': 6000000,
        'Movies/clip.mov': 1000000,
        'code/app/target/x': 3000000,
        'code/lib/target/x': 2000000,
        'notes.txt': 500,
      },
    );
    Directory(core.root).createSync();
    core.cachedScanAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
    core.disk = const DiskSpace(total: 100000000, free: 40000000);
    model = AppModel();
  });

  tearDown(() {
    model.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Starts the app on a [width] wide window with a finished scan.
  Future<void> start(WidgetTester tester, {double width = 1600}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await model.init();
      core.scan!.add(scanUpdate(files: 5, elapsedMs: 1500, done: true));
      await pumpEventQueue();
    });
    await tester.pumpWidget(SpaceManApp(model: model));
    await tester.pumpAndSettle();
  }

  Finder rowOf(String name) =>
      find.ancestor(of: find.text(name), matching: find.byType(ListTile));

  group('home', () {
    testWidgets('wide windows get a side rail with the tabs', (tester) async {
      core.suggestionList = [suggestion(core, at('Movies'))];
      await start(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      for (final tab in ['Explore', 'Clean up', 'Do not touch']) {
        expect(find.text(tab), findsOneWidget);
      }
      // The number of suggestions sits on the Clean up tab.
      expect(find.widgetWithText(Badge, '1'), findsOneWidget);
    });

    testWidgets('narrow windows get a bottom bar', (tester) async {
      await start(tester, width: 400);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('asks about access first when undecided', (tester) async {
      await start(tester);
      model.showAccessIntro();
      await tester.pumpAndSettle();
      expect(find.text('Continue without Full Disk Access'), findsOneWidget);
      await tester.tap(find.text('Continue without Full Disk Access'));
      await tester.pumpAndSettle();
      expect(model.access, DiskAccess.limited);
      // The status line offers to grant it after all.
      expect(find.text('Full Disk Access'), findsOneWidget);
    });

    testWidgets('? opens the help', (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('Help (?)'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('explore', () {
    testWidgets('lists the largest items first', (tester) async {
      await start(tester);
      final names = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Row).children.first as Flexible).child)
          .whereType<Text>()
          .map((t) => t.data)
          .toList();
      expect(names, ['Movies', 'code', 'notes.txt']);
      expect(find.text('12.0 MB in 5 files'), findsOneWidget);
      expect(find.text('58.3%'), findsOneWidget);
    });

    testWidgets('opens folders and goes back up', (tester) async {
      await start(tester);
      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();
      expect(find.text('film.mkv'), findsOneWidget);
      expect(model.currentId, core.idOf(at('Movies')));

      // The breadcrumb of the root shows its last path component.
      await tester.tap(find.widgetWithText(TextButton, 'home'));
      await tester.pumpAndSettle();
      expect(model.currentId, 0);

      // The folder we came out of keeps the focus, so Enter opens it
      // again, and the arrows move on from there.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(model.currentId, core.idOf(at('Movies')));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(model.currentId, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(model.currentId, core.idOf(at('code')));
    });

    testWidgets('ticking items shows the selection bar', (tester) async {
      await start(tester);
      await tester.tap(
        find.descendant(of: rowOf('Movies'), matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 selected, 7.0 MB'), findsOneWidget);

      // Delete toggles the focused item and moves on.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('2 selected, 12.0 MB'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
      expect(model.selection, isEmpty);
    });

    testWidgets('the lock marks an item do not touch', (tester) async {
      await start(tester);
      await tester.tap(
        find.descendant(
          of: rowOf('code'),
          matching: find.byTooltip('Mark as do not touch'),
        ),
      );
      await tester.pumpAndSettle();
      expect(core.protectedList, [at('code')]);
      // Protected items move out of the way, to their own tab.
      expect(find.text('code'), findsNothing);
      await tester.tap(find.text('Do not touch'));
      await tester.pumpAndSettle();
      expect(find.text(at('code')), findsOneWidget);
      expect(find.text('2 files'), findsOneWidget);
      await tester.tap(find.byTooltip('Allow touching again'));
      await tester.pumpAndSettle();
      expect(core.protectedList, isEmpty);
      expect(
        find.text('Nothing marked yet. Click the lock in front of any item.'),
        findsOneWidget,
      );
    });

    testWidgets('the treemap draws the folder', (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('Treemap'));
      await tester.pumpAndSettle();
      expect(model.treemap, isTrue);
      expect(find.byType(Treemap), findsOneWidget);
      expect(
        find.text('Click a folder to open it. Right-click for more.'),
        findsOneWidget,
      );
      // Clicking the biggest tile opens it.
      final box = tester.getRect(find.byType(Treemap));
      await tester.tapAt(box.topLeft + const Offset(40, 40));
      await tester.pumpAndSettle();
      expect(model.currentId, core.idOf(at('Movies')));
    });
  });

  testWidgets('arrows and the menu work in the treemap', (tester) async {
    await start(tester);
    await tester.tap(find.byTooltip('Treemap'));
    await tester.pumpAndSettle();
    final map = tester.state<TreemapState>(find.byType(Treemap));
    // Nothing focused yet: the biggest tile; then by position.
    expect(map.neighbor(null, AxisDirection.right)?.path, at('Movies'));
    final next = map.neighbor(at('Movies'), AxisDirection.right);
    expect(next?.path, isNot(at('Movies')));
    expect(map.neighbor(at('Movies'), AxisDirection.left), isNull);

    final box = tester.getRect(find.byType(Treemap));
    await tester.tapAt(
      box.topLeft + const Offset(40, 40),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    // The deepest tile there is a file: it can be ticked, not opened.
    expect(find.text('Open'), findsNothing);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(model.selection.keys, [at('Movies/film.mkv')]);

    await tester.tapAt(
      box.topLeft + const Offset(40, 40),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Unselect'), findsOneWidget);
    await tester.tap(find.text('Do not touch').last);
    await tester.pumpAndSettle();
    expect(core.protectedList, [at('Movies/film.mkv')]);
  });

  group('scan header', () {
    testWidgets('shows the scan, disk and what was not read', (tester) async {
      core.unreadable = [at('locked')];
      await start(tester);
      expect(find.text(core.root), findsOneWidget);
      expect(find.text('5 files · 1.5 s'), findsOneWidget);
      expect(find.text('40.0 MB free'), findsOneWidget);
      // 100 MB in use on disk, 10 MB scanned: not big enough to mention, so
      // the unreadable folder is what shows.
      expect(find.text(' · 1 unreadable '), findsOneWidget);
      await tester.tap(find.text(' · 1 unreadable '));
      await tester.pumpAndSettle();
      expect(find.text('Folders that could not be read:'), findsOneWidget);
      expect(find.text(at('locked')), findsOneWidget);
    });

    testWidgets('follows a running scan', (tester) async {
      await start(tester);
      await tester.tap(
        find.byTooltip('Rescan (right-click for a full rescan)'),
      );
      await tester.pump();
      expect(find.text('Starting scan...'), findsOneWidget);
      core.scan!.add(scanUpdate(files: 1200, bytes: 3000000));
      await tester.pump();
      expect(find.text('Scanning · 1.2K files · 3.0 MB'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop scan'));
      await tester.pump();
      expect(find.text('Stopping...'), findsOneWidget);
      core.scan!.add(scanUpdate(files: 1200, done: true, partial: true));
      await tester.pumpAndSettle();
      expect(find.text('Stopped after 1.2K files'), findsOneWidget);
    });

    testWidgets('shows scan errors', (tester) async {
      await start(tester);
      model.scan();
      core.scan!.add(scanUpdate(done: true, error: 'cannot read /x'));
      await tester.pumpAndSettle();
      expect(find.text('cannot read /x'), findsOneWidget);
    });
  });

  group('clean up', () {
    Future<void> openCleanup(WidgetTester tester) async {
      await tester.tap(find.text('Clean up'));
      await tester.pumpAndSettle();
    }

    testWidgets('says when there is nothing to do', (tester) async {
      await start(tester);
      await openCleanup(tester);
      expect(find.text('Nothing to clean up. Nice and tidy!'), findsOneWidget);
    });

    testWidgets('groups build output and sums sections', (tester) async {
      core.suggestionList = [
        suggestion(
          core,
          at('code/app/target'),
          title: 'Rust build output',
          category: SuggestionCategory.buildOutput,
        ),
        suggestion(
          core,
          at('code/lib/target'),
          title: 'Rust build output',
          category: SuggestionCategory.buildOutput,
        ),
        suggestion(
          core,
          at('Movies/film.mkv'),
          title: 'film.mkv',
          category: SuggestionCategory.largeOldFile,
          safe: false,
        ),
      ];
      await start(tester);
      await openCleanup(tester);
      expect(find.text('Developer build output'), findsOneWidget);
      expect(find.text('Rust build output (2)'), findsOneWidget);
      expect(find.text('5.0 MB'), findsWidgets);
      expect(find.text('Large files'), findsOneWidget);
      expect(find.text('Caches'), findsNothing);

      // One checkbox ticks the whole group.
      final group = rowOf('Rust build output (2)');
      await tester.tap(
        find.descendant(of: group, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(model.selectionRoots, hasLength(2));

      // Opening it shows each folder, relative to the home folder.
      await tester.tap(find.text('Rust build output (2)'));
      await tester.pumpAndSettle();
      expect(find.text('~/code/app/target'), findsOneWidget);
      await tester.tap(find.text('~/code/app/target'));
      await tester.pumpAndSettle();
      expect(model.selectionRoots, hasLength(1));
    });

    testWidgets('long sections show more on request', (tester) async {
      core.reset(
        root: core.root,
        files: {for (var i = 1; i <= 7; i++) 'c$i/x': i * 1000},
      );
      core.suggestionList = [
        for (var i = 7; i >= 1; i--) suggestion(core, at('c$i'), title: 'c$i'),
      ];
      await start(tester);
      await openCleanup(tester);
      expect(find.text('c3'), findsOneWidget);
      expect(find.text('c2'), findsNothing);
      await tester.tap(find.text('Show 2 more'));
      await tester.pumpAndSettle();
      expect(find.text('c1'), findsOneWidget);
    });

    testWidgets('space ticks the row under the pointer', (tester) async {
      core.suggestionList = [suggestion(core, at('Movies'), title: 'Movies')];
      await start(tester);
      await openCleanup(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: tester.getCenter(rowOf('Movies')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(model.isSelected(at('Movies')), isTrue);
      await gesture.removePointer();
    });
  });

  group('removing', () {
    Future<void> selectMovies(WidgetTester tester) async {
      await tester.tap(
        find.descendant(of: rowOf('Movies'), matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('moves to the trash after confirming', (tester) async {
      await start(tester);
      await selectMovies(tester);
      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();
      expect(find.text('Move "Movies" to the Trash?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(core.deleted, isNull);

      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash').last);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(core.deleted, [at('Movies')]);
      expect(core.deletedPermanently, isFalse);
      expect(find.text('Removed 7.0 MB'), findsOneWidget);
      expect(find.text('Movies'), findsNothing);
    });

    testWidgets('permanent removal warns and lists failures', (tester) async {
      core.deleteReport = (paths) => DeleteReport(
        deleted: const [],
        freed: 0,
        failed: [FailedDelete(path: paths.single, reason: 'in use')],
      );
      await start(tester);
      await selectMovies(tester);
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Delete "Movies" permanently?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(core.deletedPermanently, isTrue);
      expect(find.text('Removed 0 B. 1 could not be removed.'), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('in use'), findsOneWidget);
    });

    testWidgets('the selection bar lists and protects items', (tester) async {
      await start(tester);
      await selectMovies(tester);
      await tester.tap(find.text('1 selected, 7.0 MB'));
      await tester.pumpAndSettle();
      expect(find.text(at('Movies')), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Do not touch'));
      await tester.pumpAndSettle();
      expect(core.protectedList, [at('Movies')]);
      expect(find.text('1 selected, 7.0 MB'), findsNothing);
    });
  });
}
