import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../drives.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart' as core;
import 'help.dart';
import 'not_scanned.dart';

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
              if (canPickFolder) ...[
                IconButton(
                  tooltip: 'Choose folder',
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: canPickFolder && model.drives.isNotEmpty
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: _DriveMenu(
                          model: model,
                          onPickFolder: _pickFolder,
                        ),
                      )
                    : Text(
                        model.root,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (showHelp) const HelpButton(),
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

/// What is scanned, as a dropdown: the drive's name or the folder's path,
/// with the other drives and a folder picker in the menu.
class _DriveMenu extends StatelessWidget {
  const _DriveMenu({required this.model, required this.onPickFolder});

  final AppModel model;
  final VoidCallback onPickFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drive = model.rootDrive;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final d in model.drives)
          MenuItemButton(
            leadingIcon: Icon(
              d.path == model.root ? Icons.check : _driveIcon(d),
              size: 20,
            ),
            onPressed: () => model.setRoot(d.path),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(d.name),
                  Text(
                    '${formatBytes(d.free)} free of ${formatBytes(d.total)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open_outlined, size: 20),
          onPressed: onPickFolder,
          child: const Text('Choose folder...'),
        ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (controller.isOpen) {
            controller.close();
          } else {
            model.refreshDrives();
            controller.open();
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                drive == null ? Icons.folder_outlined : _driveIcon(drive),
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Tooltip(
                  message: model.root,
                  child: Text(
                    drive?.name ?? model.root,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _driveIcon(Drive d) =>
      d.main ? Icons.computer_outlined : Icons.storage_outlined;
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
    if (model.rootNode == null) return const SizedBox.shrink();
    final unreadable = core.unreadableFolders();
    final outside = model.unscanned;
    final showOutside = outside >= AppModel.unscannedThreshold;
    if (unreadable.isEmpty && !showOutside) return const SizedBox.shrink();

    final label = showOutside
        ? '${formatBytes(outside)} not scanned'
        : '${unreadable.length >= 200 ? '200+' : unreadable.length} '
              'unreadable';
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showNotScanned(context, model),
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
