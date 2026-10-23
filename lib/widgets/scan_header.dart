import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart' as core;
import 'help.dart';
import 'selection_bar.dart';

/// Top bar: which folder is scanned, disk usage and scan controls.
class ScanHeader extends StatelessWidget {
  const ScanHeader({super.key, required this.model, this.showHelp = false});

  final AppModel model;

  /// Narrow layouts have no sidebar to carry the help button.
  final bool showHelp;

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(initialDirectory: model.root);
    if (path != null) await model.setRoot(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disk = model.diskSpace;
    final p = model.progress;

    final String status;
    if (model.stopping) {
      status = 'Stopping...';
    } else if (model.scanning) {
      status = p == null
          ? 'Starting scan...'
          : 'Scanning · ${formatCompact(p.files)} files · ${formatBytes(p.bytes)}';
    } else if (model.lastError != null) {
      status = model.lastError!;
    } else if (p != null && p.done && p.partial) {
      status = 'Stopped after ${formatCompact(p.files)} files';
    } else if (p != null && p.done) {
      status =
          '${formatCompact(p.files)} files · ${(p.elapsedMs / 1000).toStringAsFixed(1)} s';
    } else if (model.scannedAt != null) {
      status = 'Scanned ${formatAgo(model.scannedAt!)}';
    } else {
      status = '';
    }

    final muted = theme.textTheme.bodySmall?.copyWith(
      color: model.lastError != null
          ? theme.colorScheme.error
          : theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model.root,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (showHelp) const HelpButton(),
              if (canPickFolder)
                IconButton(
                  tooltip: 'Choose folder',
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                ),
              if (model.scanning)
                IconButton(
                  tooltip: 'Stop scan',
                  onPressed: model.cancelScan,
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              else
                MenuAnchor(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () => model.scan(full: true),
                      leadingIcon: const Icon(Icons.refresh),
                      child: const Text('Full rescan (ignore cache)'),
                    ),
                  ],
                  builder: (context, controller, _) => GestureDetector(
                    onSecondaryTap: controller.open,
                    onLongPress: controller.open,
                    child: IconButton(
                      tooltip: 'Rescan (right-click for a full rescan)',
                      onPressed: model.scan,
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                ),
            ],
          ),
          // One quiet line: how the scan went, what it missed, and access.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    status,
                    style: muted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!model.scanning) _NotScanned(model: model, style: muted),
                if (model.access == DiskAccess.limited) ...[
                  const SizedBox(width: 8),
                  _Chip(
                    icon: Icons.shield_outlined,
                    label: 'Full Disk Access',
                    tooltip:
                        'Desktop, Documents and other protected folders are '
                        'skipped. Click to grant access.',
                    onTap: model.showAccessIntro,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: model.scanning
                ? const LinearProgressIndicator()
                : disk != null && disk.total > 0
                ? _DiskBar(total: disk.total, free: disk.free)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// A small tappable label with an icon, for the status line.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the scan could not count: unreadable folders, and disk space in
/// use that is not in the scanned folder at all.
class _NotScanned extends StatelessWidget {
  const _NotScanned({required this.model, required this.style});

  final AppModel model;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final root = model.rootNode;
    if (root == null) return const SizedBox.shrink();
    final unreadable = core.unreadableFolders();
    final disk = model.diskSpace;
    final outside = disk == null ? 0 : disk.total - disk.free - root.size;
    // Small differences are rounding and metadata, not worth a mention.
    final showOutside = outside > 1024 * 1024 * 1024;
    if (unreadable.isEmpty && !showOutside) return const SizedBox.shrink();

    final label = showOutside
        ? '${formatBytes(outside)} not scanned'
        : '${unreadable.length >= 200 ? '200+' : unreadable.length} '
              'unreadable';
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => _NotScannedDialog(
          root: model.root,
          scanned: root.size,
          outside: showOutside ? outside : 0,
          unreadable: unreadable,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(' · $label ', style: style),
            Icon(Icons.info_outline, size: 13, color: style?.color),
          ],
        ),
      ),
    );
  }
}

class _NotScannedDialog extends StatelessWidget {
  const _NotScannedDialog({
    required this.root,
    required this.scanned,
    required this.outside,
    required this.unreadable,
  });

  final String root;
  final int scanned;
  final int outside;
  final List<String> unreadable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Not in this scan'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (outside > 0)
              Text(
                Platform.isAndroid
                    ? 'The scan of $root found ${formatBytes(scanned)}. '
                          'Another ${formatBytes(outside)} of the phone is in '
                          'use outside it: mostly apps and their data, and '
                          'Android itself. See the Apps tab for the size of '
                          'each app.'
                    : 'The scan of $root found ${formatBytes(scanned)}. '
                          'Another ${formatBytes(outside)} of the disk is in '
                          'use outside it: other folders, macOS itself, apps, '
                          'other users, local snapshots, and folders that '
                          'could not be read. Their exact size is unknown, '
                          'because what can not be read can not be measured.',
                style: theme.textTheme.bodyMedium,
              ),
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
      ],
    );
  }
}

class _DiskBar extends StatelessWidget {
  const _DiskBar({required this.total, required this.free});

  final int total;
  final int free;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = (total - free) / total;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: used,
              minHeight: 8,
              color: used > 0.9 ? theme.colorScheme.error : null,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: '${formatBytes(total - free)} used of ${formatBytes(total)}',
          child: Text(
            '${formatBytes(free)} free',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
