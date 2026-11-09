import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart' as core;
import 'row_controls.dart';

/// Whether Full Disk Access would let SpaceMan see more: macOS, and the
/// user scans without it.
bool canGrantFullDiskAccess(AppModel model) =>
    _platform == TargetPlatform.macOS && model.access == DiskAccess.limited;

/// The platform, as tests can override it.
TargetPlatform get _platform => defaultTargetPlatform;

/// One line on what the space the scan does not see is made of.
String unscannedSummary(AppModel model) => switch (_platform) {
  TargetPlatform.android => 'Apps, their data and Android itself',
  TargetPlatform.macOS when canGrantFullDiskAccess(model) =>
    'Protected folders, macOS, apps and other users',
  TargetPlatform.macOS => 'macOS, apps, other users and snapshots',
  TargetPlatform.windows => 'Windows, apps and other users',
  _ => 'The system, apps and other users',
};

/// Explains what the scan did not count, with a way to fix what can be.
Future<void> showNotScanned(BuildContext context, AppModel model) =>
    showDialog<void>(
      context: context,
      builder: (context) => NotScannedDialog(model: model),
    );

/// Opens the Full Disk Access settings; once opened, offers the restart
/// macOS needs before the access applies.
class FullDiskAccessButton extends StatefulWidget {
  const FullDiskAccessButton({super.key, this.dense = false});

  /// Smaller, to fit in a treemap tile or a list row.
  final bool dense;

  @override
  State<FullDiskAccessButton> createState() => _FullDiskAccessButtonState();
}

class _FullDiskAccessButtonState extends State<FullDiskAccessButton> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    final style = widget.dense
        ? const ButtonStyle(visualDensity: VisualDensity.compact)
        : null;
    if (_opened) {
      return FilledButton.tonalIcon(
        style: style,
        onPressed: relaunchApp,
        icon: const Icon(Icons.restart_alt),
        label: const Text('Restart SpaceMan'),
      );
    }
    return FilledButton.icon(
      style: style,
      onPressed: () async {
        await openFullDiskAccessSettings();
        if (mounted) setState(() => _opened = true);
      },
      icon: const Icon(Icons.shield_outlined),
      label: const Text('Grant Full Disk Access'),
    );
  }
}

class NotScannedDialog extends StatelessWidget {
  const NotScannedDialog({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanned = model.rootNode?.size ?? 0;
    final outside = model.unscanned >= AppModel.unscannedThreshold
        ? model.unscanned
        : 0;
    final unreadable = core.unreadableFolders();
    final grant = canGrantFullDiskAccess(model);
    final body = theme.textTheme.bodyMedium;
    return AlertDialog(
      title: const Text('Not in this scan'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (outside > 0) ...[
              Text(
                'The scan of ${model.root} found ${formatBytes(scanned)}. '
                'About ${formatBytes(outside)} more of the '
                '${_platform == TargetPlatform.android ? 'phone' : 'disk'} is in use, but '
                'SpaceMan can not see what it is: that is the used space of '
                'the disk minus what the scan found.',
                style: body,
              ),
              const SizedBox(height: 12),
              if (grant) ...[
                Text(
                  'Part of it is in folders macOS protects: Desktop, '
                  'Documents, Downloads, iCloud Drive, Mail, Messages and the '
                  'data of other apps. SpaceMan skipped them so macOS would '
                  'not ask you about each one. With Full Disk Access, '
                  'SpaceMan can count them too.',
                  style: body,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                _platform == TargetPlatform.android
                    ? 'The rest is mostly apps and their data, and Android '
                          'itself. See the Apps tab for the size of each app.'
                    : _platform == TargetPlatform.macOS
                    ? '${grant ? 'The rest' : 'It'} is macOS itself, apps, '
                          'other users, local snapshots and space macOS can '
                          'free up on its own.'
                    : 'It is the system itself, apps, other users and '
                          'folders that could not be read.',
                style: body,
              ),
            ],
            if (unreadable.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                unreadable.length >= 200
                    ? 'First 200 folders that could not be read:'
                    : 'Folders that could not be read:',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final path in unreadable)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(path, overflow: TextOverflow.ellipsis),
                        trailing: RevealButton(path: path),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (grant) const FullDiskAccessButton(),
      ],
    );
  }
}

/// How a block for part of the unscanned space looks and what it does.
class _PartView {
  _PartView({
    required this.icon,
    required this.title,
    required this.size,
    required this.summary,
    required this.onTap,
    this.action,
    this.estimate = true,
  });

  final IconData icon;
  final String title;
  final int size;
  final String summary;
  final VoidCallback onTap;

  /// The main thing to do about it, such as granting access.
  final Widget? action;

  /// The size is the gap in disk use, not measured.
  final bool estimate;

  String get sizeText =>
      estimate ? 'about ${formatBytes(size)}' : formatBytes(size);
}

_PartView _view(BuildContext context, AppModel model, UnscannedPart part) {
  void why() => showNotScanned(context, model);
  void seeApps() => model.showTab(AppModel.appsTab);
  switch (part.kind) {
    case UnscannedKind.unknown:
      return _PartView(
        icon: Icons.question_mark_rounded,
        title: 'Not scanned',
        size: part.size,
        summary: unscannedSummary(model),
        onTap: why,
        action: canGrantFullDiskAccess(model)
            ? const FullDiskAccessButton(dense: true)
            : null,
      );
    case UnscannedKind.apps:
      final apps = model.apps;
      if (model.usageAccess == false) {
        return _PartView(
          icon: Icons.apps,
          title: 'Apps',
          size: part.size,
          summary:
              'Apps and their data. Android shows how big each one '
              'is once you allow usage access.',
          onTap: seeApps,
          action: const FilledButton(
            onPressed: requestUsageAccess,
            style: ButtonStyle(visualDensity: VisualDensity.compact),
            child: Text('Allow usage access'),
          ),
        );
      }
      if (apps == null) {
        return _PartView(
          icon: Icons.apps,
          title: 'Apps',
          size: part.size,
          summary: 'Asking Android how big each app is...',
          onTap: seeApps,
        );
      }
      return _PartView(
        icon: Icons.apps,
        title: 'Apps',
        size: part.size,
        estimate: false,
        summary: '${apps.apps.length} apps and their data',
        onTap: seeApps,
        action: FilledButton.tonal(
          onPressed: seeApps,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          child: const Text('See apps'),
        ),
      );
    case UnscannedKind.system:
      return _PartView(
        icon: Icons.phone_android,
        title: 'System and other',
        size: part.size,
        summary: 'Android itself and space it keeps aside',
        onTap: why,
      );
  }
}

/// Part of the space the scan does not see, as one tile of the treemap:
/// what it is, how big, and the way to see more.
class UnscannedTile extends StatelessWidget {
  const UnscannedTile({super.key, required this.model, required this.part});

  final AppModel model;
  final UnscannedPart part;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final v = _view(context, model, part);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: v.onTap,
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < 70 || c.maxHeight < 50) {
              return Center(child: Icon(v.icon, size: 20, color: muted));
            }
            final roomy = c.maxWidth >= 220 && c.maxHeight >= 200;
            return Center(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(v.icon, size: roomy ? 56 : 28, color: muted),
                    const SizedBox(height: 4),
                    Text(
                      v.title,
                      style:
                          (roomy
                                  ? theme.textTheme.titleMedium
                                  : theme.textTheme.labelMedium)
                              ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      v.sizeText,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (roomy) ...[
                      const SizedBox(height: 8),
                      Text(
                        v.summary,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ?v.action,
                      if (part.kind == UnscannedKind.unknown)
                        TextButton(
                          onPressed: v.onTap,
                          child: const Text('Why?'),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Part of the space the scan does not see, as a row of the Explore list.
class UnscannedRow extends StatelessWidget {
  const UnscannedRow({
    super.key,
    required this.model,
    required this.part,
    required this.fraction,
  });

  final AppModel model;
  final UnscannedPart part;

  /// Size relative to the largest item, for the bar.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _view(context, model, part);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return ListTile(
      onTap: v.onTap,
      leading: Icon(v.icon, color: theme.colorScheme.onSurfaceVariant),
      title: Text(
        narrow ? v.title : '${v.title} · ${v.summary}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      subtitle: SizeBar(fraction, padding: const EdgeInsets.only(top: 4)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (v.action != null) ...[v.action!, const SizedBox(width: 12)],
          SizedBox(
            width: narrow ? 72 : 120,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  v.estimate ? '~${formatBytes(v.size)}' : formatBytes(v.size),
                  style: theme.textTheme.titleSmall,
                ),
                if (v.estimate)
                  Text('estimate', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          // Lines the size up with the rows that have buttons after it.
          if (!narrow)
            SizedBox(width: (canReveal ? 3 : 2) * (leadingGap + leadingSlot)),
        ],
      ),
    );
  }
}

/// One line about [part] for the status line under the treemap.
String unscannedHint(UnscannedPart part) => switch (part.kind) {
  UnscannedKind.unknown =>
    'Not scanned: about ${formatBytes(part.size)}. Click to see why.',
  UnscannedKind.apps => 'Apps: ${formatBytes(part.size)}. Click to see them.',
  UnscannedKind.system =>
    'System and other: about ${formatBytes(part.size)}. Click to see why.',
};
