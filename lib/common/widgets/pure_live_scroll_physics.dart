import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show MaterialScrollBehavior;

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

/// 为有限横向选择器（页签栏、标签条等）开启鼠标左键拖拽平移。
///
/// 全局 [MyCustomScrollBehavior] 刻意把鼠标排除在 dragDevices 之外，以保证
/// 内容列表在桌面端具备预期的边界回弹行为；而页签栏这类有限选择器使用的是
/// [PureLiveBoundedScrollPhysics]（无回弹、硬边界），因此在此开启鼠标拖拽
/// 既安全又符合直觉。用法：
///
/// ```dart
/// ScrollConfiguration(
///   behavior: const MouseDraggableScrollBehavior(),
///   child: TabBar(isScrollable: true, ...),
/// )
/// ```
class MouseDraggableScrollBehavior extends MaterialScrollBehavior {
  const MouseDraggableScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.mouse,
    PointerDeviceKind.unknown,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const PureLiveBoundedScrollPhysics();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
