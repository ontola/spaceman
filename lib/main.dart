import 'package:flutter/material.dart';
import 'package:spaceman/src/rust/frb_generated.dart';

import 'app_model.dart';
import 'screens/access_intro.dart';
import 'screens/cleanup.dart';
import 'screens/explorer.dart';
import 'screens/protected.dart';
import 'widgets/scan_header.dart';

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
    const seed = Color(0xFF3B6FE0);
    return MaterialApp(
      title: 'SpaceMan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
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

  static const _destinations = [
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
          _ => ProtectedScreen(model: model),
        };
        final cleanupBadge = model.suggestions.isEmpty
            ? null
            : '${model.suggestions.length}';

        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final body = Column(
              children: [
                ScanHeader(model: model),
                const Divider(height: 1),
                Expanded(child: page),
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
                          Icon(d.icon),
                          i == 1 ? cleanupBadge : null,
                        ),
                        selectedIcon: Icon(d.active),
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
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Icon(Icons.rocket_launch, size: 32),
                    ),
                    destinations: [
                      for (final (i, d) in _destinations.indexed)
                        NavigationRailDestination(
                          icon: _badge(
                            Icon(d.icon),
                            i == 1 ? cleanupBadge : null,
                          ),
                          selectedIcon: Icon(d.active),
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
