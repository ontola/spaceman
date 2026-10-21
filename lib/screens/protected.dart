import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_model.dart';

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
    final paths = model.protectedPaths;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
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
          child: paths.isEmpty
              ? Center(
                  child: Text(
                    'Nothing marked yet. Use "Do not touch" in the ... menu of any item.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  children: [
                    for (final p in paths)
                      ListTile(
                        leading: Icon(
                          Icons.lock,
                          color: theme.colorScheme.tertiary,
                        ),
                        title: Text(p, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          tooltip: 'Allow touching again',
                          icon: const Icon(Icons.close),
                          onPressed: () => model.unprotect(p),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
