/// What can be done with one item, offered in the same words and order
/// everywhere: the right-click menu of the list and the treemap, and the
/// bar under Explore for the folder that is open.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import 'fly_to.dart';
import 'selection_bar.dart';

/// Keyboard hints are for computers with a keyboard.
bool get showKeyHints =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// The keys that go up one folder, for hints.
String get upKeys => !kIsWeb && Platform.isMacOS ? 'Esc / ⌘[' : 'Esc / Alt+←';

enum ItemAction { open, select, protect, reveal, trash, deletePermanently }

/// One action as offered for [node]: its label, icon and key, and whether
/// it can be done now. Null when it does not apply at all.
({String label, IconData icon, String? keys, bool enabled})? describe(
  ItemAction action,
  AppModel model,
  NodeView node, {
  bool canOpen = true,
}) {
  final removable = model.canRemove(node);
  switch (action) {
    case ItemAction.open:
      if (!canOpen || node.kind != EntryKind.dir || !node.hasChildren) {
        return null;
      }
      return (
        label: 'Open',
        icon: Icons.folder_open,
        keys: 'Enter',
        enabled: true,
      );
    case ItemAction.select:
      final selected = model.isSelected(node.path);
      return (
        label: selected ? 'Unselect' : 'Select',
        icon: selected ? Icons.check_box : Icons.check_box_outline_blank,
        keys: 'Space',
        enabled: removable,
      );
    case ItemAction.protect:
      if (node.kind == EntryKind.smallFiles) return null;
      final own = model.protectedPaths.contains(node.path);
      return (
        label: own ? 'Allow again' : 'Do not touch',
        icon: own ? Icons.lock_open_outlined : Icons.lock_outline,
        keys: null,
        enabled: own || removable,
      );
    case ItemAction.reveal:
      if (!canReveal || node.kind == EntryKind.smallFiles) return null;
      return (
        label: 'Show in $fileManagerName',
        icon: Icons.open_in_new,
        keys: null,
        enabled: true,
      );
    case ItemAction.trash:
      return (
        label: hasTrash ? 'Move to $trashName' : 'Delete',
        icon: Icons.delete_outline,
        keys: null,
        enabled: removable,
      );
    case ItemAction.deletePermanently:
      if (!hasTrash) return null;
      return (
        label: 'Delete permanently',
        icon: Icons.delete_forever_outlined,
        keys: null,
        enabled: removable,
      );
  }
}

/// Does [action] on [node]. [onOpen] opens a folder.
void runAction(
  BuildContext context,
  ItemAction action,
  AppModel model,
  NodeView node, {
  ValueChanged<int>? onOpen,
}) {
  switch (action) {
    case ItemAction.open:
      onOpen?.call(node.id);
    case ItemAction.select:
      model.setSelected(node, !model.isSelected(node.path));
    case ItemAction.protect:
      if (model.protectedPaths.contains(node.path)) {
        model.unprotect(node.path);
      } else {
        flyToDoNotTouch(context, node.name);
        model.protect(node.path);
      }
    case ItemAction.reveal:
      reveal(node.path);
    case ItemAction.trash:
      confirmAndDelete(context, model, items: [node]);
    case ItemAction.deletePermanently:
      confirmAndDelete(context, model, items: [node], permanent: true);
  }
}

/// The right-click menu of [node], at [global].
Future<void> showItemMenu(
  BuildContext context,
  AppModel model,
  NodeView node,
  Offset global, {
  ValueChanged<int>? onOpen,
}) async {
  final theme = Theme.of(context);
  final error = theme.colorScheme.error;
  PopupMenuEntry<ItemAction>? entry(ItemAction a) {
    final d = describe(a, model, node, canOpen: onOpen != null);
    if (d == null) return null;
    final danger = a == ItemAction.deletePermanently;
    return PopupMenuItem(
      value: a,
      enabled: d.enabled,
      child: Row(
        children: [
          Icon(d.icon, size: 18, color: danger && d.enabled ? error : null),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              d.label,
              overflow: TextOverflow.ellipsis,
              style: danger && d.enabled ? TextStyle(color: error) : null,
            ),
          ),
          if (showKeyHints && d.keys != null) ...[
            const SizedBox(width: 24),
            Text(
              d.keys!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  final top = [
    for (final a in [
      ItemAction.open,
      ItemAction.select,
      ItemAction.protect,
      ItemAction.reveal,
    ])
      ?entry(a),
  ];
  final bottom = [
    for (final a in [ItemAction.trash, ItemAction.deletePermanently]) ?entry(a),
  ];
  final choice = await showMenu<ItemAction>(
    context: context,
    position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, 0),
    items: [
      PopupMenuItem(
        enabled: false,
        height: 32,
        child: Text(
          '${node.name}  ·  ${formatBytes(node.size)}',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium,
        ),
      ),
      const PopupMenuDivider(),
      ...top,
      if (bottom.isNotEmpty) const PopupMenuDivider(),
      ...bottom,
    ],
  );
  if (choice == null || !context.mounted) return;
  runAction(context, choice, model, node, onOpen: onOpen);
}

/// Bar under Explore with the actions for the folder that is open, and on
/// desktops the keys that work there.
class FolderBar extends StatelessWidget {
  const FolderBar({super.key, required this.model, required this.folder});

  final AppModel model;
  final NodeView folder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final buttons = [
      for (final a in [
        ItemAction.protect,
        ItemAction.reveal,
        ItemAction.trash,
        ItemAction.deletePermanently,
      ])
        if (describe(a, model, folder, canOpen: false) case final d?)
          IconButton(
            tooltip: '${d.label} this folder',
            onPressed: d.enabled
                ? () => runAction(context, a, model, folder)
                : null,
            color: a == ItemAction.deletePermanently
                ? theme.colorScheme.error
                : null,
            icon: Icon(d.icon, size: 20),
          ),
    ];
    // Selecting is the main thing to do here, so it leads, filled.
    final select = describe(ItemAction.select, model, folder)!;
    final selected = model.isSelected(folder.path);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, c) {
          // Phones: just the buttons.
          final narrow = c.maxWidth < 600;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            child: Row(
              children: [
                Tooltip(
                  message: showKeyHints
                      ? 'Space selects the item under the mouse instead'
                      : '',
                  child:
                      (selected ? FilledButton.tonalIcon : FilledButton.icon)(
                        onPressed: select.enabled
                            ? () => runAction(
                                context,
                                ItemAction.select,
                                model,
                                folder,
                              )
                            : null,
                        icon: Icon(select.icon, size: 20),
                        label: Text(
                          narrow ? select.label : '${select.label} this folder',
                        ),
                      ),
                ),
                const SizedBox(width: 8),
                if (!narrow) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.folder,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${folder.name.isEmpty ? folder.path : folder.name}  ·  '
                      '${formatBytes(folder.size)}',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                ...buttons,
                if (showKeyHints && !narrow) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '↑↓←→ move  ·  Enter open  ·  $upKeys up  ·  '
                      'Space select  ·  Right-click for more  ·  ? help',
                      style: muted,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          );
        },
      ),
    );
  }
}
