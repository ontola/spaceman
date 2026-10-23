import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spaceman/src/rust/frb_generated.dart';

import 'app_model.dart';
import 'palette.dart';
import 'platform.dart';
import 'screens/access_intro.dart';
import 'screens/apps.dart';
import 'screens/cleanup.dart';
import 'screens/explorer.dart';
import 'screens/protected.dart';
import 'widgets/fly_to.dart';
import 'widgets/help.dart';
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

        // "?" opens the help from anywhere.
        return CallbackShortcuts(
          bindings: {const CharacterActivator('?'): () => showHelp(context)},
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final body = Column(
                children: [
                  ScanHeader(model: model, showHelp: !wide),
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
                      // The logo sits flush at the bottom, out of the way of
                      // the tabs.
                      trailing: Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            const HelpButton(),
                            const SizedBox(height: 8),
                            canOpenUrl
                                ? Tooltip(
                                    message: 'SpaceMan website',
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () => openUrl(websiteUrl),
                                        child: const SpaceManLogo(size: 40),
                                      ),
                                    ),
                                  )
                                : const SpaceManLogo(size: 40),
                          ],
                        ),
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
          ),
        );
      },
    );
  }

  Widget _badge(Widget icon, String? label) =>
      label == null ? icon : Badge(label: Text(label), child: icon);
}
