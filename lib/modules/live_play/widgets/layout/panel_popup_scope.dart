import 'package:flutter/material.dart';

/// Tracks popups spawned from inside the floating live-play panel (custom
/// overlay dropdown menus). The panel's auto-hide must be suspended while
/// such a popup holds the pointer, because the popup's full-screen barrier
/// fires the panel's [MouseRegion.onExit] as soon as it is inserted.
///
/// Route-based popups (modal sheets, dialogs) do not need this scope; the
/// shell detects them via `ModalRoute.isCurrent`.
class PanelPopupScope extends StatefulWidget {
  const PanelPopupScope({
    super.key,
    required this.onPopupOpened,
    required this.onPopupClosed,
    required this.child,
  });

  final VoidCallback onPopupOpened;
  final VoidCallback onPopupClosed;
  final Widget child;

  static PanelPopupScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<PanelPopupScopeState>();

  @override
  State<PanelPopupScope> createState() => PanelPopupScopeState();
}

class PanelPopupScopeState extends State<PanelPopupScope> {
  void notifyPopupOpened() => widget.onPopupOpened();

  void notifyPopupClosed() => widget.onPopupClosed();

  @override
  Widget build(BuildContext context) => widget.child;
}
