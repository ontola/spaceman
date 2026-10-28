/// Controls on an item row in Explore and Clean up: the size bar, show in
/// the file manager, do not touch, and the checkbox.
library;

import 'package:flutter/material.dart';

import '../app_model.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import 'fly_to.dart';

/// Size of each row control (lock, checkbox), placed
/// [leadingGap] apart so the gaps look equal.
const double leadingSlot = 24;
const double leadingGap = 12;

/// Small trailing button to show an item in Finder / Explorer.
class RevealButton extends StatelessWidget {
  const RevealButton({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (!canReveal) return const SizedBox.shrink();
    return Tooltip(
      message: 'Show in $fileManagerName',
      child: InkResponse(
        radius: 18,
        onTap: () => reveal(path),
        child: const SizedBox.square(
          dimension: leadingSlot,
          child: Icon(Icons.open_in_new, size: 18),
        ),
      ),
    );
  }
}

/// Lock at the end of a row: marks the item as do not touch, or allows it
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

/// Bar under an item's name showing its size next to its siblings.
class SizeBar extends StatelessWidget {
  const SizeBar(this.fraction, {super.key, this.padding = _padding});

  /// Size relative to the largest row around it.
  final double fraction;
  final EdgeInsetsGeometry padding;

  static const _padding = EdgeInsets.only(top: 4, bottom: 2);

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: fraction.isFinite ? fraction.clamp(0, 1) : 0,
        minHeight: 6,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    ),
  );
}
