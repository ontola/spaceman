import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';

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
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _confirmAndDelete(context, model),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(hasTrash ? 'Move to Trash' : 'Delete'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for confirmation, removes the selection and reports the result.
Future<void> _confirmAndDelete(BuildContext context, AppModel model) async {
  final items = model.selectionRoots;
  final total = model.selectionSize;
  final what = items.length == 1
      ? '"${items.single.name}"'
      : '${items.length} items';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(hasTrash ? 'Move $what to the Trash?' : 'Delete $what?'),
      content: Text(
        hasTrash
            ? 'This frees up to ${formatBytes(total)} once the Trash is emptied. '
                  'You can still restore it from the Trash.'
                  '${model.selectionEmptiesTrash ? '\n\nThe current contents of the Trash are deleted for good.' : ''}'
            : 'This frees ${formatBytes(total)}. This cannot be undone.',
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

  final report = await model.deleteSelection();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        report.failed.isEmpty
            ? 'Removed ${formatBytes(report.freed)}'
            : 'Removed ${formatBytes(report.freed)}. '
                  '${report.failed.length} failed: ${report.failed.first.reason}',
      ),
    ),
  );
}

/// Small trailing button to show an item in Finder / Explorer.
class RevealButton extends StatelessWidget {
  const RevealButton({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (!canReveal) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Show in $fileManagerName',
      icon: const Icon(Icons.open_in_new, size: 18),
      onPressed: () => reveal(path),
    );
  }
}
