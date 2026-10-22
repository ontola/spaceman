import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/selection_bar.dart';

/// Suggestions for what can be removed. Nothing is ticked up front: the
/// selection is shared with Explore, where it would go unnoticed.
class CleanupScreen extends StatelessWidget {
  const CleanupScreen({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final suggestions = model.suggestions;
    if (suggestions.isEmpty) {
      return Center(
        child: model.loadingSuggestions || model.scanning
            ? const CircularProgressIndicator()
            : const Text('Nothing to clean up. Nice and tidy!'),
      );
    }

    final safe = suggestions.where((s) => s.safe).toList();
    final review = suggestions.where((s) => !s.safe).toList();
    return ListView(
      children: [
        if (safe.isNotEmpty)
          _Section(
            title: 'Safe to remove',
            subtitle:
                'Caches and build output. Apps recreate these when needed.',
            items: safe,
            model: model,
          ),
        if (review.isNotEmpty)
          _Section(
            title: 'Worth a look',
            subtitle: 'Probably not needed, but check before removing.',
            items: review,
            model: model,
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.model,
  });

  final String title;
  final String subtitle;
  final List<SuggestionView> items;
  final AppModel model;

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
          ListTile(
            onTap: () =>
                model.setSelected(s.node, !model.isSelected(s.node.path)),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProtectToggle(model: model, node: s.node),
                RowCheckbox(
                  value: model.isSelected(s.node.path),
                  onChanged: (v) => model.setSelected(s.node, v ?? false),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatBytes(s.node.size),
                  style: theme.textTheme.titleSmall,
                ),
                RevealButton(path: s.node.path),
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
