import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';

/// Asks for confirmation, removes [paths] and reports the result.
Future<void> confirmAndDelete(
  BuildContext context,
  AppModel model,
  List<String> paths,
  int totalSize, {
  bool emptiesTrash = false,
}) async {
  final what = paths.length == 1
      ? '"${paths.single.split(RegExp(r'[/\\]')).last}"'
      : '${paths.length} items';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(hasTrash ? 'Move $what to the Trash?' : 'Delete $what?'),
      content: Text(
        hasTrash
            ? 'This frees up to ${formatBytes(totalSize)} once the Trash is emptied. '
                  'You can still restore it from the Trash.'
                  '${emptiesTrash ? '\n\nThe current contents of the Trash are deleted for good.' : ''}'
            : 'This frees ${formatBytes(totalSize)}. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(hasTrash ? 'Move to Trash' : 'Delete'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  final report = await model.delete(paths);
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (report.failed.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text('Removed ${formatBytes(report.freed)}')),
    );
  } else {
    final first = report.failed.first;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Removed ${formatBytes(report.freed)}. '
          '${report.failed.length} failed: ${first.reason}',
        ),
      ),
    );
  }
}

/// The "..." menu shown on every file or folder row.
class ItemMenu extends StatelessWidget {
  const ItemMenu({super.key, required this.model, required this.node});

  final AppModel model;
  final NodeView node;

  @override
  Widget build(BuildContext context) {
    final isProtected = model.protectedPaths.contains(node.path);
    final inherited =
        node.protection == ProtectionState.protected && !isProtected;
    final blocked = node.protection != ProtectionState.none;
    final bucket = node.kind == EntryKind.smallFiles;

    return MenuAnchor(
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_horiz),
        tooltip: 'Actions',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        if (canReveal)
          MenuItemButton(
            leadingIcon: const Icon(Icons.open_in_new),
            onPressed: () => reveal(node.path),
            child: Text('Show in $fileManagerName'),
          ),
        if (!bucket && isProtected)
          MenuItemButton(
            leadingIcon: const Icon(Icons.lock_open),
            onPressed: () => model.unprotect(node.path),
            child: const Text('Allow touching again'),
          )
        else if (!bucket && !inherited)
          MenuItemButton(
            leadingIcon: const Icon(Icons.lock_outline),
            onPressed: () => model.protect(node.path),
            child: const Text('Do not touch'),
          ),
        if (!bucket)
          MenuItemButton(
            leadingIcon: const Icon(Icons.delete_outline),
            onPressed: blocked
                ? null
                : () =>
                      confirmAndDelete(context, model, [node.path], node.size),
            child: Text(hasTrash ? 'Move to Trash' : 'Delete'),
          ),
      ],
    );
  }
}
