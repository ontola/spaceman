import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import 'fly_to.dart';

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
        toTrash ? 'Move $what to the Trash?' : 'Delete $what permanently?',
      ),
      content: Text(
        toTrash
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
          style: toTrash
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
          child: Text(toTrash ? 'Move to Trash' : 'Delete permanently'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  final report = await model.deleteSelection(permanent: permanent);
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

/// Lock in front of a row: marks the item as do not touch, or allows it
/// again. Items inside a protected folder show the lock but can not be
/// toggled on their own.
class ProtectToggle extends StatelessWidget {
  const ProtectToggle({super.key, required this.model, required this.node});

  final AppModel model;
  final NodeView node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (node.kind == EntryKind.smallFiles) {
      return const SizedBox(width: leadingSlot);
    }
    final own = model.protectedPaths.contains(node.path);
    final inherited = !own && node.protection == ProtectionState.protected;
    return Tooltip(
      message: own
          ? 'Do not touch (click to allow again)'
          : inherited
          ? 'Inside a folder marked do not touch'
          : 'Mark as do not touch',
      child: InkResponse(
        radius: 18,
        onTap: inherited
            ? null
            : () {
                if (own) {
                  model.unprotect(node.path);
                } else {
                  // Start the flight before the row changes or disappears.
                  flyToDoNotTouch(context, node.name);
                  model.protect(node.path);
                }
              },
        child: SizedBox.square(
          dimension: leadingSlot,
          child: Icon(
            own || inherited ? Icons.lock : Icons.lock_open_outlined,
            size: 20,
            // Same weight as an unticked checkbox; inherited locks are
            // dimmed like a disabled control.
            color: own
                ? theme.colorScheme.tertiary
                : inherited
                ? theme.colorScheme.tertiary.withValues(alpha: 0.45)
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Size of each control in front of a row (lock, checkbox, icon), placed
/// [leadingGap] apart so the gaps look equal.
const double leadingSlot = 24;
const double leadingGap = 12;

/// Compact checkbox that fits a [leadingSlot].
class RowCheckbox extends StatelessWidget {
  const RowCheckbox({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: leadingSlot,
    child: Checkbox(
      value: value,
      onChanged: onChanged,
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}
