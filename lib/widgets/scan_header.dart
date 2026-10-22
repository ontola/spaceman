import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart' as core;
import 'selection_bar.dart';

/// Top bar: which folder is scanned, disk usage and scan controls.
class ScanHeader extends StatelessWidget {
  const ScanHeader({super.key, required this.model});

  final AppModel model;

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
          : 'Scanning: ${formatCount(p.files)} files, ${formatBytes(p.bytes)}';
    } else if (model.lastError != null) {
      status = model.lastError!;
    } else if (p != null && p.done && p.partial) {
      status =
          'Scan stopped after ${formatCount(p.files)} files. '
          'Rescan to complete it.';
    } else if (p != null && p.done) {
      status =
          'Scanned ${formatCount(p.files)} files in ${(p.elapsedMs / 1000).toStringAsFixed(1)} s';
    } else if (model.scannedAt != null) {
      status = 'From cache, scanned ${formatAgo(model.scannedAt!)}';
    } else {
      status = '';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.root,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (status.isNotEmpty)
                      Text(
                        status,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: model.lastError != null
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (canPickFolder)
                IconButton(
                  tooltip: 'Choose folder',
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.drive_folder_upload_outlined),
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
          if (!model.scanning) _NotScanned(model: model),
          if (model.access == DiskAccess.limited)
            Row(
              children: [
                Flexible(
                  child: Text(
                    'Desktop, Documents and other protected folders are skipped.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.bodySmall,
                  ),
                  onPressed: model.showAccessIntro,
                  child: const Text('Grant Full Disk Access'),
                ),
              ],
            ),
          const SizedBox(height: 8),
          if (model.scanning)
            const LinearProgressIndicator()
          else if (disk != null && disk.total > 0)
            _DiskBar(total: disk.total, free: disk.free),
        ],
      ),
    );
  }
}

/// What the scan could not count: unreadable folders, and disk space in
/// use that is not in the scanned folder at all.
class _NotScanned extends StatelessWidget {
  const _NotScanned({required this.model});

  final AppModel model;

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

    final parts = [
      if (showOutside) '${formatBytes(outside)} of used disk space not scanned',
      if (unreadable.isNotEmpty)
        '${unreadable.length >= 200 ? '200+' : unreadable.length} '
            'folder${unreadable.length == 1 ? '' : 's'} not readable',
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
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
          child: Text(
            parts.join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
            ),
          ),
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
                'The scan of $root found ${formatBytes(scanned)}. Another '
                '${formatBytes(outside)} of the disk is in use outside it: '
                'other folders, macOS itself, apps, other users, local '
                'snapshots, and folders that could not be read. Their exact '
                'size is unknown, because what can not be read can not be '
                'measured.',
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
        Text(
          '${formatBytes(free)} free of ${formatBytes(total)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
