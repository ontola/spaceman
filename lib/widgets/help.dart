import 'dart:io';

import 'package:flutter/material.dart';

import '../platform.dart';

/// Opens the help: what the tabs are for and the keyboard shortcuts.
Future<void> showHelp(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _HelpDialog());

/// The help button, the same wherever it sits.
class HelpButton extends StatelessWidget {
  const HelpButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Help (?)',
    onPressed: () => showHelp(context),
    icon: const Icon(Icons.help_outline),
  );
}

class _HelpDialog extends StatelessWidget {
  const _HelpDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(s, style: theme.textTheme.titleSmall),
    );
    Widget para(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(s, style: theme.textTheme.bodyMedium),
    );
    final keys = [
      ('↑ ↓ ← →', 'Move the focus (in the list, ← goes up, → opens)'),
      ('Enter', 'Open the folder'),
      ('Space', 'Select or unselect the item under the mouse'),
      ('Backspace / Delete', 'Select or unselect the focused item'),
      (
        Platform.isMacOS ? 'Esc  Cmd+[  Cmd+↑' : 'Esc  Alt+←  Alt+↑',
        'Up one folder (Esc also closes dialogs)',
      ),
      ('Scroll, pinch', 'Treemap: up or out goes up, down or in opens'),
      ('Pull down', 'At the top of the list: up one folder'),
      ('?', 'This help'),
    ];

    return AlertDialog(
      title: const Text('SpaceMan'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              para(
                'Explore shows where your space goes, biggest first, as a '
                'list or a treemap. Bars and tiles are sized by disk use.',
              ),
              para(
                'Clean up suggests caches, build output and big files that '
                'are usually safe to remove.',
              ),
              para(
                'Do not touch lists what you locked: it is never suggested '
                'and cannot be removed.',
              ),
              heading('Removing'),
              para(
                hasTrash
                    ? 'Tick items, then Move to $trashName (you can restore '
                          'them) or Delete permanently (cannot be undone).'
                    : 'Tick items, then Delete. This cannot be undone.',
              ),
              if (Platform.isMacOS)
                para(
                  'Without Full Disk Access, macOS keeps Desktop, Documents '
                  'and similar folders out of the scan.',
                ),
              heading('Keyboard'),
              Table(
                columnWidths: const {0: IntrinsicColumnWidth()},
                children: [
                  for (final (k, what) in keys)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 16, bottom: 4),
                          child: Text(
                            k,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(what, style: theme.textTheme.bodyMedium),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
