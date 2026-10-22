import 'package:flutter/material.dart';

/// The "Do not touch" navigation icon, where protected rows fly to.
final doNotTouchTarget = GlobalKey(debugLabel: 'doNotTouchTarget');

/// Animates a ghost of the row around [context] into the "Do not touch"
/// navigation icon, so it is clear where the item went.
void flyToDoNotTouch(BuildContext context, String label) {
  final overlay = Overlay.maybeOf(context);
  final target = doNotTouchTarget.currentContext?.findRenderObject();
  RenderObject? row;
  context.visitAncestorElements((e) {
    if (e.widget is ListTile) {
      row = e.renderObject;
      return false;
    }
    return true;
  });
  final from = row ?? context.findRenderObject();
  if (overlay == null ||
      from is! RenderBox ||
      target is! RenderBox ||
      !from.attached ||
      !target.attached) {
    return;
  }
  final overlayBox = overlay.context.findRenderObject() as RenderBox;
  final start =
      from.localToGlobal(Offset.zero, ancestor: overlayBox) & from.size;
  final end =
      target.localToGlobal(Offset.zero, ancestor: overlayBox) & target.size;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _Flight(
      start: start,
      end: end,
      label: label,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _Flight extends StatefulWidget {
  const _Flight({
    required this.start,
    required this.end,
    required this.label,
    required this.onDone,
  });

  final Rect start;
  final Rect end;
  final String label;
  final VoidCallback onDone;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeInOutCubic.transform(_c.value);
          final rect = Rect.lerp(widget.start, widget.end, t)!;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: Opacity(
                  opacity: (1 - Curves.easeIn.transform(_c.value) * 0.8),
                  child: Material(
                    elevation: 6,
                    color: theme.colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8 + 12 * t),
                    clipBehavior: Clip.antiAlias,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            if (t < 0.6) ...[
                              const SizedBox(width: 12),
                              Text(
                                widget.label,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
