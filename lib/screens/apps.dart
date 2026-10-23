import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';

/// Android only: space used by installed apps and their data. That is most
/// of a phone's storage, and a file scan can not see it, so the sizes come
/// from Android itself. Removing goes through the system: App info for
/// clearing cache or storage, the uninstall dialog for the app.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> with WidgetsBindingObserver {
  bool? _access;
  AppSizes? _sizes;
  String? _error;
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Settings: access may be granted, or an app cleared or
  /// uninstalled.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final access = await hasUsageAccess();
    if (!mounted) return;
    setState(() => _access = access);
    if (!access) return;
    try {
      final sizes = await appSizes();
      if (!mounted) return;
      setState(() {
        _sizes = sizes;
        _error = null;
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    if (access == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!access) return const _UsageAccessIntro();
    if (_error != null) return Center(child: Text(_error!));
    final sizes = _sizes;
    if (sizes == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final apps = sizes.apps.where((a) => _showSystem || !a.system).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final largest = apps.isEmpty ? 1 : apps.first.total;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: apps.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return _Summary(
              sizes: sizes,
              files: widget.model.rootNode?.size ?? 0,
              showSystem: _showSystem,
              onShowSystem: (v) => setState(() => _showSystem = v),
            );
          }
          final app = apps[i - 1];
          return _AppRow(app: app, fraction: app.total / largest);
        },
      ),
    );
  }
}

/// Where the phone's storage goes: apps, the user's files, and the rest.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.sizes,
    required this.files,
    required this.showSystem,
    required this.onShowSystem,
  });

  final AppSizes sizes;

  /// Size of the shared storage scan.
  final int files;
  final bool showSystem;
  final ValueChanged<bool> onShowSystem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apps = sizes.apps.fold<int>(0, (sum, a) => sum + a.total);
    final cache = sizes.apps.fold<int>(0, (sum, a) => sum + a.cache);
    final used = sizes.total - sizes.free;
    final system = used - apps - files;
    Widget line(String label, int bytes) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(formatBytes(bytes), style: theme.textTheme.titleSmall),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line('Apps and their data', apps),
          line('Your files (Explore)', files),
          if (system > 0) line('System and other', system),
          const SizedBox(height: 8),
          Text(
            '${formatBytes(cache)} of the app data is cache, which apps '
            'download again when needed. Tap an app to clear its cache or '
            'storage.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: const Text('Built-in apps'),
              selected: showSystem,
              onSelected: onShowSystem,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.fraction});

  final AppSize app;

  /// Size relative to the largest app, for the bar.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [
      'App ${formatBytes(app.app)}',
      'Data ${formatBytes(app.data - app.cache)}',
      if (app.cache > 0) 'Cache ${formatBytes(app.cache)}',
    ].join(' · ');
    return ListTile(
      onTap: () => openAppInfo(app.package),
      title: Text(app.label, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction.clamp(0, 1),
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatBytes(app.total), style: theme.textTheme.titleSmall),
          PopupMenuButton<void>(
            itemBuilder: (context) => [
              PopupMenuItem(
                onTap: () => openAppInfo(app.package),
                child: const Text('Clear cache or storage'),
              ),
              if (!app.system)
                PopupMenuItem(
                  onTap: () => uninstallApp(app.package),
                  child: const Text('Uninstall'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UsageAccessIntro extends StatelessWidget {
  const _UsageAccessIntro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.apps, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Most of your space is in apps',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Apps and their data are stored where no file scan can look. '
                'Android does tell SpaceMan how big each app is, once you '
                'turn on "Usage access" for it.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'SpaceMan only reads sizes, not what you do in your apps.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: requestUsageAccess,
                icon: const Icon(Icons.settings),
                label: const Text('Allow usage access'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
