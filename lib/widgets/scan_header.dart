import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';

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
    if (model.scanning) {
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
          'Scanned ${formatCount(p.files)} files in ${(p.elapsedMs / 1000).toStringAsFixed(1)} s'
          '${p.errors > 0 ? ' (${formatCount(p.errors)} folders not readable)' : ''}';
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
          if (model.access == DiskAccess.limited)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: model.showAccessIntro,
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: const Text(
                  'Protected folders are skipped. Grant Full Disk Access',
                ),
              ),
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
