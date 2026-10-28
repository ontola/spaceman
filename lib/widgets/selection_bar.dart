import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';

/// Bottom bar with everything that is ticked, and actions for all of it.
class SelectionBar extends StatefulWidget {
  const SelectionBar({super.key, required this.model});

  final AppModel model;

  @override
  State<SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<SelectionBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final theme = Theme.of(context);
    final items = model.selectionRoots;
    if (items.isEmpty) return const SizedBox.shrink();

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final node in items)
                    ListTile(
                      dense: true,
                      title: Text(node.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        node.path,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(formatBytes(node.size)),
                          IconButton(
                            tooltip: 'Remove from selection',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => model.setSelected(node, false),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Clear selection',
                  icon: const Icon(Icons.close),
                  onPressed: model.clearSelection,
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_more : Icons.expand_less),
                  label: Text(
                    '${items.length} selected, ${formatBytes(model.selectionSize)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: model.protectSelection,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Do not touch'),
                ),
                if (hasTrash) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _confirmAndDelete(context, model, permanent: true),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Delete permanently'),
                  ),
                ],
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _confirmAndDelete(context, model),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(hasTrash ? 'Move to $trashName' : 'Delete'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteProgressDialog extends StatefulWidget {
  const _DeleteProgressDialog({required this.progress, required this.toTrash});

  final ValueNotifier<DeleteProgress?> progress;
  final bool toTrash;

  @override
  State<_DeleteProgressDialog> createState() => _DeleteProgressDialogState();
}

class _DeleteProgressDialogState extends State<_DeleteProgressDialog> {
  bool _stopping = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<DeleteProgress?>(
      valueListenable: widget.progress,
      builder: (context, p, _) {
        // By files when the scan knows them, so one big folder moves the
        // bar too; otherwise by items.
        final double? value = p == null
            ? null
            : p.filesTotal > 0
            ? (p.filesDone / p.filesTotal).clamp(0.0, 1.0)
            : p.total > 0
            ? p.done / p.total
            : null;
        final verb = widget.toTrash ? 'Moving' : 'Deleting';
        return AlertDialog(
          title: Text(
            p == null
                ? '$verb...'
                : '$verb ${p.done} of ${p.total} · '
                      '${formatBytes(p.freed)} freed',
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 12),
                Text(
                  _stopping ? 'Stopping after this file...' : p?.current ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _stopping
                  ? null
                  : () {
                      setState(() => _stopping = true);
                      cancelDelete();
                    },
              child: const Text('Stop'),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for confirmation, removes the selection and reports the result.
/// With [permanent] (or without a trash) nothing can be restored.
Future<void> _confirmAndDelete(
  BuildContext context,
  AppModel model, {
  bool permanent = false,
}) async {
  final toTrash = hasTrash && !permanent;
  final items = model.selectionRoots;
  final total = model.selectionSize;
  final what = items.length == 1
      ? '"${items.single.name}"'
      : '${items.length} items';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        toTrash ? 'Move $what to the $trashName?' : 'Delete $what permanently?',
      ),
      content: Text(
        toTrash
            ? 'This frees up to ${formatBytes(total)} once the $trashName is emptied. '
                  'You can still restore it from the $trashName.'
                  '${model.selectionEmptiesTrash ? '\n\nThe current contents of the $trashName are deleted for good.' : ''}'
            : 'This frees ${formatBytes(total)}. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: toTrash
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
          child: Text(toTrash ? 'Move to $trashName' : 'Delete permanently'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  // Removing can take a while (big folders, permanently): show how far it
  // is and keep everything else out of reach meanwhile.
  final progress = ValueNotifier<DeleteProgress?>(null);
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: _DeleteProgressDialog(progress: progress, toTrash: toTrash),
    ),
  );
  final DeleteReport report;
  try {
    report = await model.deleteSelection(
      permanent: permanent,
      onProgress: (p) => progress.value = p,
    );
  } finally {
    // Never leave the blocking dialog up, whatever happened.
    if (context.mounted) Navigator.of(context).pop();
    await dialog;
    progress.dispose();
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (report.failed.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text('Removed ${formatBytes(report.freed)}')),
    );
    return;
  }
  // Failures stay until dismissed, so they can be read.
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(days: 1),
      showCloseIcon: true,
      content: Text(
        'Removed ${formatBytes(report.freed)}. '
        '${report.failed.length} could not be removed.',
      ),
      action: SnackBarAction(
        label: 'Details',
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Not removed'),
            content: SizedBox(
              width: 500,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in report.failed)
                    ListTile(
                      dense: true,
                      title: Text(f.path),
                      subtitle: Text(f.reason),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
