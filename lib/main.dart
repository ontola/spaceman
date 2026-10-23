import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spaceman/src/rust/frb_generated.dart';

import 'app_model.dart';
import 'palette.dart';
import 'screens/access_intro.dart';
import 'screens/apps.dart';
import 'screens/cleanup.dart';
import 'screens/explorer.dart';
import 'screens/protected.dart';
import 'widgets/fly_to.dart';
import 'widgets/logo.dart';
import 'widgets/scan_header.dart';
import 'widgets/selection_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final model = AppModel();
  runApp(SpaceManApp(model: model));
  await model.init();
}

class SpaceManApp extends StatelessWidget {
  const SpaceManApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpaceMan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seedColor, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seedColor,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(model: model),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.model});

  final AppModel model;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  static final _destinations = [
    (
      icon: Icons.folder_open_outlined,
      active: Icons.folder_open,
      label: 'Explore',
    ),
    (
      icon: Icons.cleaning_services_outlined,
      active: Icons.cleaning_services,
      label: 'Clean up',
    ),
    (icon: Icons.lock_outline, active: Icons.lock, label: 'Do not touch'),
    // Android keeps apps out of reach of the file scan; see AppsScreen.
    if (Platform.isAndroid)
      (icon: Icons.apps_outlined, active: Icons.apps, label: 'Apps'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final model = widget.model;
        if (model.access == DiskAccess.undecided) {
          return Scaffold(
            body: SafeArea(child: AccessIntro(model: model)),
          );
        }
        final page = switch (_tab) {
          0 => ExplorerScreen(model: model),
          1 => CleanupScreen(model: model),
          2 => ProtectedScreen(model: model),
          _ => AppsScreen(model: model),
        };
        final cleanupBadge = model.suggestions.isEmpty
            ? null
            : '${model.suggestions.length}';

        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final body = Column(
              children: [
                ScanHeader(model: model, showLogo: !wide),
                const Divider(height: 1),
                Expanded(child: page),
                if (_tab < 2) SelectionBar(model: model),
              ],
            );
            if (!wide) {
              return Scaffold(
                body: SafeArea(child: body),
                bottomNavigationBar: NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: [
                    for (final (i, d) in _destinations.indexed)
                      NavigationDestination(
                        icon: _badge(
                          i == 2
                              ? KeyedSubtree(
                                  key: doNotTouchTarget,
                                  child: Icon(d.icon),
                                )
                              : Icon(d.icon),
                          i == 1 ? cleanupBadge : null,
                        ),
                        selectedIcon: i == 2
                            ? KeyedSubtree(
                                key: doNotTouchTarget,
                                child: Icon(d.active),
                              )
                            : Icon(d.active),
                        label: d.label,
                      ),
                  ],
                ),
              );
            }
            return Scaffold(
              body: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: SpaceManLogo(size: 48),
                    ),
                    destinations: [
                      for (final (i, d) in _destinations.indexed)
                        NavigationRailDestination(
                          icon: _badge(
                            i == 2
                                ? KeyedSubtree(
                                    key: doNotTouchTarget,
                                    child: Icon(d.icon),
                                  )
                                : Icon(d.icon),
                            i == 1 ? cleanupBadge : null,
                          ),
                          selectedIcon: i == 2
                              ? KeyedSubtree(
                                  key: doNotTouchTarget,
                                  child: Icon(d.active),
                                )
                              : Icon(d.active),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: SafeArea(child: body)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _badge(Widget icon, String? label) =>
      label == null ? icon : Badge(label: Text(label), child: icon);
}
