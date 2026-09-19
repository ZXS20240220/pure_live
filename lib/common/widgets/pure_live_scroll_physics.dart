import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

/// Uses the native touch model instead of forcing the iOS spring model on
/// Android and desktop lists.
class PureLiveScrollPhysics extends ScrollPhysics {
  const PureLiveScrollPhysics({super.parent});

  @override
  ScrollPhysics applyTo(ScrollPhysics? ancestor) {
    final resolvedParent = buildParent(ancestor);
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => BouncingScrollPhysics(parent: resolvedParent),
      _ => ClampingScrollPhysics(parent: resolvedParent),
    };
  }
}

/// A platform-independent hard boundary for navigation strips and paged views.
///
/// Content lists keep [PureLiveScrollPhysics] so iOS/macOS retain their native
/// spring. Navigation, filters and other finite selectors must never expose an
/// offset before their first item or after their last item, even when their
/// contents shrink while the route stays mounted.
class PureLiveBoundedScrollPhysics extends ClampingScrollPhysics {
  const PureLiveBoundedScrollPhysics({super.parent});

  @override
  PureLiveBoundedScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return PureLiveBoundedScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    return adjusted.clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent).toDouble();
  }
}

class MouseScrollDirectionConverter extends StatefulWidget {
  final Axis targetAxis;
  final ScrollController controller;
  final Widget child;

  const MouseScrollDirectionConverter({
    super.key,
    required this.targetAxis,
    required this.controller,
    required this.child,
  });

  @override
  State<MouseScrollDirectionConverter> createState() => _MouseScrollDirectionConverterState();
}

class _MouseScrollDirectionConverterState extends State<MouseScrollDirectionConverter> {
  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        if (widget.controller.hasClients) {
          final viewport = widget.controller.position;
          final delta = widget.targetAxis == Axis.horizontal ? event.scrollDelta.dy : event.scrollDelta.dx;
          final target = (viewport.pixels + delta).clamp(viewport.minScrollExtent, viewport.maxScrollExtent);
          widget.controller.jumpTo(target.toDouble());
        }
      },
      child: widget.child,
    );
  }
}

const Duration pureLiveTabTransitionDuration = Duration(milliseconds: 220);
