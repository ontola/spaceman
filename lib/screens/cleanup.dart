import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/item_actions.dart';

/// Suggestions for what can be removed, with safe items preselected.
class CleanupScreen extends StatefulWidget {
  const CleanupScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<CleanupScreen> createState() => _CleanupScreenState();
}

class _CleanupScreenState extends State<CleanupScreen> {
  final Set<String> _selected = {};
  List<SuggestionView>? _seen;

  /// Preselects safe items whenever a new set of suggestions arrives,
  /// keeping the user's choices for items that are still suggested.
  void _syncSelection(List<SuggestionView> suggestions) {
    if (identical(suggestions, _seen)) return;
    final previous = _seen?.map((s) => s.node.path).toSet() ?? {};
    _seen = suggestions;
    final current = suggestions.map((s) => s.node.path).toSet();
    _selected.removeWhere((p) => !current.contains(p));
    for (final s in suggestions) {
      if (s.safe && !previous.contains(s.node.path)) _selected.add(s.node.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final suggestions = model.suggestions;
    _syncSelection(suggestions);

    if (suggestions.isEmpty) {
      return Center(
        child: model.loadingSuggestions || model.scanning
            ? const CircularProgressIndicator()
            : const Text('Nothing to clean up. Nice and tidy!'),
      );
    }

    final safe = suggestions.where((s) => s.safe).toList();
    final review = suggestions.where((s) => !s.safe).toList();
    final selectedSize = suggestions
        .where((s) => _selected.contains(s.node.path))
        .fold<int>(0, (sum, s) => sum + s.node.size);

    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              if (safe.isNotEmpty)
                _Section(
                  title: 'Safe to remove',
                  subtitle: 'Caches and build output. Apps recreate these when needed.',
                  items: safe,
                  model: model,
                  selected: _selected,
                  onToggle: _toggle,
                ),
              if (review.isNotEmpty)
                _Section(
                  title: 'Worth a look',
                  subtitle: 'Probably not needed, but check before removing.',
                  items: review,
                  model: model,
                  selected: _selected,
                  onToggle: _toggle,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_selected.length} selected, ${formatBytes(selectedSize)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              FilledButton.icon(
                onPressed: _selected.isEmpty
                    ? null
                    : () => confirmAndDelete(
                        context,
                        model,
                        _selected.toList(),
                        selectedSize,
                        emptiesTrash: suggestions.any(
                          (s) =>
                              s.removal == RemovalMode.emptyTrash &&
                              _selected.contains(s.node.path),
                        ),
                      ),
                icon: const Icon(Icons.delete_outline),
                label: Text(hasTrash ? 'Move to Trash' : 'Delete'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _toggle(String path, bool on) {
    setState(() => on ? _selected.add(path) : _selected.remove(path));
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.model,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final String subtitle;
  final List<SuggestionView> items;
  final AppModel model;
  final Set<String> selected;
  final void Function(String path, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = items.fold<int>(0, (sum, s) => sum + s.node.size);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              Text(formatBytes(total), style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(subtitle, style: theme.textTheme.bodySmall),
        ),
        for (final s in items)
          CheckboxListTile(
            value: selected.contains(s.node.path),
            onChanged: (v) => onToggle(s.node.path, v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            secondary: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatBytes(s.node.size),
                  style: theme.textTheme.titleSmall,
                ),
                ItemMenu(model: model, node: s.node),
              ],
            ),
            title: Text(s.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.reason),
                if (s.removal != RemovalMode.whole)
                  Text(
                    s.removal == RemovalMode.emptyTrash
                        ? 'Empties the Trash permanently.'
                        : 'The folder stays, its contents are removed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                Text(
                  s.node.path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            isThreeLine: true,
          ),
      ],
    );
  }
}
