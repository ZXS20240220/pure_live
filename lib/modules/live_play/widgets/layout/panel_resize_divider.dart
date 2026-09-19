import 'package:flutter/material.dart';

class PanelResizeDivider extends StatefulWidget {
  final double currentWidth;
  final double Function(double width, double screenWidth) clampWidth;
  final ValueChanged<double> onResize;
  final ValueChanged<double>? onDragEnd;

  const PanelResizeDivider({
    super.key,
    required this.currentWidth,
    required this.clampWidth,
    required this.onResize,
    this.onDragEnd,
  });

  @override
  State<PanelResizeDivider> createState() => _PanelResizeDividerState();
}

class _PanelResizeDividerState extends State<PanelResizeDivider> {
  double? _dragStartWidth;
  double? _dragStartX;
  bool _isHovering = false;
  bool _isDragging = false;

  double get _dividerWidth => 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hoverColor = theme.colorScheme.primary.withValues(alpha: 0.4);
    final dragColor = theme.colorScheme.primary.withValues(alpha: 0.7);
    final idleColor = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() {
        _isHovering = false;
        _isDragging = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _isHovering || _isDragging ? 4.0 : 2.0,
          color: _isDragging
              ? dragColor
              : _isHovering
              ? hoverColor
              : idleColor,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                left: (_dividerWidth - 4) / 2,
                right: (_dividerWidth - 4) / 2,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onDragStart(DragStartDetails details) {
    setState(() => _isDragging = true);
    _dragStartX = details.globalPosition.dx;
    _dragStartWidth = widget.currentWidth;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dragStartX == null || _dragStartWidth == null) return;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final delta = _dragStartX! - details.globalPosition.dx;
    final newWidth = widget.clampWidth(_dragStartWidth! + delta, screenWidth);
    widget.onResize(newWidth);
  }

  void _onDragEnd(DragEndDetails details) {
    setState(() => _isDragging = false);
    widget.onDragEnd?.call(widget.currentWidth);
    _dragStartX = null;
    _dragStartWidth = null;
  }
}
