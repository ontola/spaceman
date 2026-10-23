import 'dart:io';

import 'package:flutter/material.dart';

import '../app_model.dart';
import '../platform.dart';
import '../widgets/logo.dart';

/// Shown on macOS before the first scan when SpaceMan lacks Full Disk
/// Access. Without it, macOS asks separately for every protected folder
/// (Desktop, Documents, Downloads, iCloud Drive, other apps' data, ...),
/// so we explain that first and let the user pick.
///
/// On Android it asks for "All files access" instead: without it SpaceMan
/// would only see its own files.
class AccessIntro extends StatefulWidget {
  const AccessIntro({super.key, required this.model});

  final AppModel model;

  @override
  State<AccessIntro> createState() => _AccessIntroState();
}

class _AccessIntroState extends State<AccessIntro> with WidgetsBindingObserver {
  bool _openedSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from System Settings: continue right away if access was
  /// granted. Usually macOS only applies it after a restart, though.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.model.recheckAccess();
  }

  Future<void> _openSettings() async {
    await openFullDiskAccessSettings();
    setState(() => _openedSettings = true);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return const _AndroidAccess();
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SpaceManLogo(size: 72),
              const SizedBox(height: 16),
              Text(
                'SpaceMan needs to look at your whole disk',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'To find out where your space goes, SpaceMan has to read every '
                'folder. macOS protects many of them (Desktop, Documents, '
                'Downloads, iCloud Drive, data of other apps) and would ask '
                'you about each one separately.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'Granting Full Disk Access once avoids all those prompts. '
                'SpaceMan only reads sizes and never sends anything anywhere. '
                'Nothing is removed unless you ask for it.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              _Step(
                number: 1,
                text: 'Open System Settings > Privacy & Security > Full Disk Access.',
              ),
              _Step(
                number: 2,
                text: 'Turn on SpaceMan (use + to add it if it is not listed).',
              ),
              _Step(
                number: 3,
                text:
                    'Restart SpaceMan: macOS only applies the access after a '
                    'restart. Use "Quit & Reopen" if macOS offers it, or the '
                    'button below.',
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Open System Settings'),
                  ),
                  if (_openedSettings)
                    FilledButton.tonalIcon(
                      onPressed: relaunchApp,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restart SpaceMan'),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.model.chooseLimitedAccess,
                child: const Text('Continue without Full Disk Access'),
              ),
              Text(
                'Skips the protected folders, so macOS will not ask anything. '
                'Their space is not counted.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AndroidAccess extends StatelessWidget {
  const _AndroidAccess();

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
              const SpaceManLogo(size: 72),
              const SizedBox(height: 16),
              Text(
                'SpaceMan needs to see your files',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'To find out where your space goes, SpaceMan has to read every '
                'folder on your phone. Android only allows that with "All '
                'files access".',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'SpaceMan only reads sizes and never sends anything anywhere. '
                'Nothing is removed unless you ask for it.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              const _Step(
                number: 1,
                text: 'Tap the button below to open the setting.',
              ),
              const _Step(
                number: 2,
                text: 'Turn on "Allow access to manage all files".',
              ),
              const _Step(
                number: 3,
                text: 'Go back. SpaceMan starts scanning right away.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: requestAndroidStorageAccess,
                icon: const Icon(Icons.folder_open),
                label: const Text('Allow access'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text('$number', style: theme.textTheme.labelMedium),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
