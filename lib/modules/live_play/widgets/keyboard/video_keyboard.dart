import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';

class VideoKeyboardShortcuts extends StatefulWidget {
  final VideoController? controller;
  final Widget child;

  const VideoKeyboardShortcuts({super.key, required this.controller, required this.child});

  @override
  State<VideoKeyboardShortcuts> createState() => _VideoKeyboardShortcutsState();
}

class _VideoKeyboardShortcutsState extends State<VideoKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    super.dispose();
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;

    final escape = event.logicalKey == LogicalKeyboardKey.escape;
    if (!escape && isEditingFocused()) return false;

    if (event.logicalKey == LogicalKeyboardKey.space || event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      GlobalPlayerService.instance.player.togglePlayPause();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPlay) {
      GlobalPlayerService.instance.player.resume();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPause) {
      GlobalPlayerService.instance.player.pause();
      return true;
    }

    final controller = widget.controller;
    if (controller != null) {
      if (event.logicalKey == LogicalKeyboardKey.keyR) {
        controller.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        final state = GlobalPlayerState.to;
        if (state.isFullscreen.value || state.isPipMode.value) {
          return false;
        }
        controller.toggleWindowFullScreen();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyQ) {
        final state = GlobalPlayerState.to;
        if (state.isFullscreen.value || state.isPipMode.value || state.isWindowFullscreen.value) {
          return false;
        }
        if (Get.isRegistered<LivePlayController>()) {
          final tabController = Get.find<LivePlayController>().tabController;
          final total = tabController.length;
          if (total > 0) {
            final current = tabController.index;
            final next = (current + 1) % total;
            tabController.animateTo(next);
          }
        }
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _adjustVolume(controller, 0.05);
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _adjustVolume(controller, -0.05);
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        final player = GlobalPlayerService.instance.player;
        if (!player.canSeek) return false;
        controller.enableController();
        final bigStep = HardwareKeyboard.instance.isShiftPressed;
        final step = bigStep ? const Duration(seconds: 30) : const Duration(seconds: 5);
        player.seekRelative(-step);
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        final player = GlobalPlayerService.instance.player;
        if (!player.canSeek) return false;
        controller.enableController();
        final bigStep = HardwareKeyboard.instance.isShiftPressed;
        final step = bigStep ? const Duration(seconds: 30) : const Duration(seconds: 5);
        player.seekRelative(step);
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyE) {
        final player = GlobalPlayerService.instance.player;
        if (!player.canSeek) return false;
        controller.enableController();
        player.seekToLiveEdge();
        if (!player.isPlayingNow) {
          player.resume();
        }
        return true;
      }
    }

    if (!escape) return false;

    switch (resolveEscapePresentationAction(
      pip: GlobalPlayerState.to.isPipMode.value,
      fullscreen: controller != null && GlobalPlayerState.to.isFullscreen.value,
      widescreen: controller != null && GlobalPlayerState.to.isWindowFullscreen.value,
    )) {
      case EscapePresentationAction.exitFullscreen:
        controller!.toggleFullScreen();
        return true;
      case EscapePresentationAction.exitWidescreen:
        controller!.toggleWindowFullScreen();
        return true;
      case EscapePresentationAction.popRoute:
        unawaited(Navigator.of(context).maybePop());
        return true;
      case EscapePresentationAction.none:
        return false;
    }
  }

  Future<void> _adjustVolume(VideoController controller, double delta) async {
    final current = await controller.volume() ?? 1.0;
    final next = (current + delta).clamp(0.0, 1.0);
    controller.setVolume(next);
    controller.updateVolumn(next);
  }

  @override
  Widget build(BuildContext context) {
    // No more CallbackShortcuts — all shortcuts go through the
    // HardwareKeyboard global handler (_handleGlobalKey) above.
    // This avoids breakage caused by nested Focus/FocusScope widgets
    // further down the tree stealing the keyboard focus.
    return widget.child;
  }
}

@visibleForTesting
enum EscapePresentationAction { none, exitFullscreen, exitWidescreen, popRoute }

@visibleForTesting
EscapePresentationAction resolveEscapePresentationAction({
  required bool pip,
  required bool fullscreen,
  required bool widescreen,
}) {
  if (pip) return EscapePresentationAction.none;
  if (fullscreen) return EscapePresentationAction.exitFullscreen;
  if (widescreen) return EscapePresentationAction.exitWidescreen;
  return EscapePresentationAction.popRoute;
}
