import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../format.dart';
import '../paths.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/row_controls.dart';

/// Suggestions for what can be removed, in a few sections: caches, project
/// build output (grouped by kind) and very large files. Nothing is ticked
/// up front: the selection is shared with Explore, where it would go
/// unnoticed.
class CleanupScreen extends StatefulWidget {
  const CleanupScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<CleanupScreen> createState() => _CleanupScreenState();
}

class _CleanupScreenState extends State<CleanupScreen> {
  /// The item under the pointer, for Space, Backspace and Delete.
  final _hover = _Hover();

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final suggestions = model.suggestions;
    if (suggestions.isEmpty) {
      return Center(
        child: model.loadingSuggestions || model.scanning
            ? const CircularProgressIndicator()
            : const Text('Nothing to clean up. Nice and tidy!'),
      );
    }

    List<SuggestionView> of(Set<SuggestionCategory> categories) =>
        suggestions.where((s) => categories.contains(s.category)).toList();
    final home = homeDir();

    // Space, Backspace or Delete ticks the item under the pointer.
    void toggleHovered() {
      final node = _hover.node;
      if (node == null) return;
      if (node.protection != ProtectionState.none) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('${node.name} is marked do not touch.'),
              duration: const Duration(seconds: 2),
            ),
          );
        return;
      }
      model.setSelected(node, !model.isSelected(node.path));
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.backspace): toggleHovered,
        const SingleActivator(LogicalKeyboardKey.delete): toggleHovered,
        const SingleActivator(LogicalKeyboardKey.space): toggleHovered,
        const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
            toggleHovered,
      },
      child: Focus(
        autofocus: true,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _Section(
              title: 'Caches',
              subtitle: 'Apps and tools download these again when needed.',
              items: of({
                SuggestionCategory.cache,
                SuggestionCategory.logs,
                SuggestionCategory.trash,
              }),
              model: model,
              home: home,
              hover: _hover,
            ),
            _Section(
              title: 'Developer build output',
              subtitle: 'Rebuilt by your tools the next time you build.',
              items: of({SuggestionCategory.buildOutput}),
              model: model,
              home: home,
              hover: _hover,
              grouped: true,
            ),
            _Section(
              title: 'Large files',
              subtitle:
                  'Single files of a gigabyte or more. Check before removing.',
              items: of({SuggestionCategory.largeOldFile}),
              model: model,
              home: home,
              hover: _hover,
            ),
            _Section(
              title: 'Worth a look',
              subtitle: 'Probably not needed, but check before removing.',
              items: of({
                SuggestionCategory.downloads,
                SuggestionCategory.backups,
              }),
              model: model,
              home: home,
              hover: _hover,
            ),
          ],
        ),
      ),
    );
  }
}

/// Which item the pointer is on. Rows update it without a rebuild.
class _Hover {
  NodeView? node;
}

/// A section with a header and total. With [grouped], items of the same
/// kind (all Rust `target` folders, ...) collapse into one row.
class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.model,
    required this.home,
    required this.hover,
    this.grouped = false,
  });

  final String title;
  final String subtitle;
  final List<SuggestionView> items;
  final AppModel model;
  final String? home;
  final _Hover hover;
  final bool grouped;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  /// Rows shown before "Show more".
  static const _initial = 5;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final total = items.fold<int>(0, (sum, s) => sum + s.node.size);

    final rows = <Widget>[];
    if (widget.grouped) {
      final groups = <String, List<SuggestionView>>{};
      for (final s in items) {
        (groups[s.title] ??= []).add(s);
      }
      final sorted = groups.values.toList()
        ..sort((a, b) => _sum(b).compareTo(_sum(a)));
      final largest = _sum(sorted.first);
      for (final g in sorted) {
        rows.add(
          g.length == 1
              ? _ItemRow(
                  model: widget.model,
                  s: g.single,
                  home: widget.home,
                  hover: widget.hover,
                  fraction: g.single.node.size / largest,
                )
              : _GroupRow(
                  model: widget.model,
                  items: g,
                  home: widget.home,
                  hover: widget.hover,
                  fraction: _sum(g) / largest,
                ),
        );
      }
    } else {
      final largest = items.first.node.size;
      for (final s in items) {
        rows.add(
          _ItemRow(
            model: widget.model,
            s: s,
            home: widget.home,
            hover: widget.hover,
            fraction: s.node.size / largest,
          ),
        );
      }
    }
    final hidden = _all ? 0 : (rows.length - _initial).clamp(0, rows.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Row(
            children: [
              Tooltip(
                message: widget.subtitle,
                child: Text(widget.title, style: theme.textTheme.titleMedium),
              ),
              const Spacer(),
              Text(formatBytes(total), style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        ...rows.take(rows.length - hidden),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: TextButton(
              onPressed: () => setState(() => _all = true),
              child: Text('Show $hidden more'),
            ),
          ),
      ],
    );
  }
}

int _sum(List<SuggestionView> items) =>
    items.fold<int>(0, (sum, s) => sum + s.node.size);

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.model,
    required this.s,
    required this.home,
    required this.hover,
    required this.fraction,
    this.inGroup = false,
  });

  final AppModel model;
  final SuggestionView s;
  final String? home;
  final _Hover hover;
  final double fraction;

  /// Inside a group the kind is already said; show just the location.
  final bool inGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = switch (s.removal) {
      RemovalMode.emptyTrash => 'Empties the $trashName permanently.',
      RemovalMode.contents => 'The folder stays, its contents are removed.',
      RemovalMode.whole => null,
    };
    final path = homeRelative(s.node.path, home);
    final isFile = s.node.kind == EntryKind.file;
    final row = ListTile(
      contentPadding: EdgeInsets.only(left: inGroup ? 40 : 16, right: 16),
      onTap: () => model.setSelected(s.node, !model.isSelected(s.node.path)),
      leading: inGroup
          ? null
          : Icon(
              isFile ? Icons.insert_drive_file_outlined : Icons.folder,
              color: isFile ? null : theme.colorScheme.primary,
            ),
      // The details are there when wanted, not in the way.
      title: Tooltip(
        message: [if (!inGroup) s.reason, ?note, path].join('\n'),
        waitDuration: const Duration(milliseconds: 400),
        child: Text(inGroup ? path : s.title, overflow: TextOverflow.ellipsis),
      ),
      subtitle: inGroup
          ? SizeBar(fraction)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizeBar(fraction),
                Text(
                  middleEllipsis(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              formatBytes(s.node.size),
              textAlign: TextAlign.end,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(width: leadingGap),
          RevealButton(path: s.node.path),
          const SizedBox(width: leadingGap),
          ProtectToggle(model: model, node: s.node),
          const SizedBox(width: leadingGap),
          RowCheckbox(
            value: model.isSelected(s.node.path),
            onChanged: (v) => model.setSelected(s.node, v ?? false),
          ),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => hover.node = s.node,
      onExit: (_) {
        if (hover.node?.path == s.node.path) hover.node = null;
      },
      child: row,
    );
  }
}

/// Several suggestions of one kind, e.g. 23 Rust `target` folders: one row
/// with their total and a checkbox for all of them, expandable to each.
class _GroupRow extends StatefulWidget {
  const _GroupRow({
    required this.model,
    required this.items,
    required this.home,
    required this.hover,
    required this.fraction,
  });

  final AppModel model;
  final List<SuggestionView> items;
  final String? home;
  final _Hover hover;
  final double fraction;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.model;
    final items = widget.items;
    final ticked = items.where((s) => model.isSelected(s.node.path)).length;
    final value = ticked == 0
        ? false
        : ticked == items.length
        ? true
        : null;

    return Column(
      children: [
        ListTile(
          onTap: () => setState(() => _open = !_open),
          leading: Icon(Icons.folder_copy, color: theme.colorScheme.primary),
          title: Row(
            children: [
              Flexible(
                child: Tooltip(
                  message: items.first.reason,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    '${items.first.title} (${items.length})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _open ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          subtitle: SizeBar(widget.fraction),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  formatBytes(_sum(items)),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: leadingGap),
              // Keeps the checkbox in line with the item rows.
              const SizedBox(width: leadingSlot * 2 + leadingGap * 2),
              SizedBox.square(
                dimension: leadingSlot,
                child: Checkbox(
                  tristate: true,
                  value: value,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) {
                    final on = value != true;
                    for (final s in items) {
                      model.setSelected(s.node, on);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Column(
                  children: [
                    for (final s in items)
                      _ItemRow(
                        model: model,
                        s: s,
                        home: widget.home,
                        hover: widget.hover,
                        // Within the group, relative to its biggest folder.
                        fraction: s.node.size / items.first.node.size,
                        inGroup: true,
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
