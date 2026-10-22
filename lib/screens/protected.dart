import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../src/rust/api/spaceman.dart' as core;

/// Paths the user never wants suggested or removed.
class ProtectedScreen extends StatelessWidget {
  const ProtectedScreen({super.key, required this.model});

  final AppModel model;

  Future<void> _add() async {
    final path = await getDirectoryPath(initialDirectory: model.root);
    if (path != null) model.protect(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Largest first; items the current scan did not see go last.
    final items = [
      for (final p in model.protectedPaths)
        (path: p, node: core.nodeAt(path: p)),
    ]..sort((a, b) => (b.node?.size ?? -1).compareTo(a.node?.size ?? -1));
    final total = items.fold<int>(0, (sum, i) => sum + (i.node?.size ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${items.isEmpty ? '' : '${formatBytes(total)} kept safe. '}'
                  'Items here, and everything inside them, are never suggested '
                  'and can not be removed from SpaceMan.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add folder'),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    'Nothing marked yet. Click the lock in front of any item.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  children: [
                    for (final i in items)
                      ListTile(
                        leading: Icon(
                          Icons.lock,
                          color: theme.colorScheme.tertiary,
                        ),
                        title: Text(i.path, overflow: TextOverflow.ellipsis),
                        subtitle: i.node == null
                            ? const Text('Not in the current scan')
                            : Text('${formatCount(i.node!.fileCount)} files'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (i.node != null)
                              Text(
                                formatBytes(i.node!.size),
                                style: theme.textTheme.titleSmall,
                              ),
                            IconButton(
                              tooltip: 'Allow touching again',
                              icon: const Icon(Icons.close),
                              onPressed: () => model.unprotect(i.path),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
