import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_svg/svg.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/utils/live_url_tool.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/common/consts/app_consts.dart';
import 'package:pure_live/common/utils/play_quality_label.dart';
import 'package:pure_live/modules/live_play/states/load_type.dart';
import 'package:pure_live/player/core/portrait_stream_support.dart';
import 'package:pure_live/modules/live_play/dialogs/play_other.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/modules/live_play/pages/danmaku_settings_page.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/content_first_panel_layout.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/volume_control.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/live_progress_bar.dart';
import 'package:pure_live/modules/live_play/widgets/layout/control_hover_region.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/main_danmaku_metrics.dart';
import 'package:pure_live/modules/live_play/widgets/layout/bottom_control_surface.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_settings_binding.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/iptv_schedule_dialog.dart';
import 'package:pure_live/modules/live_play/widgets/local_interaction/local_interaction_sheet.dart';

@visibleForTesting
enum TopActionLeadingSlot { back, datetime, battery }

@visibleForTesting
enum TopActionTrailingSlot { roomHistory, datetime, battery, alwaysOnTop, audioOnly, cast, pip }

/// Resolves the fixed order of the fullscreen leading actions. On Android the
/// clock and battery sit beside Back; PiP moves to the opposite corner so the
/// two groups match the user's visual scanning order.
@visibleForTesting
List<TopActionLeadingSlot> resolveTopActionLeadingSlots({required bool fullscreen, required bool android}) {
  if (!fullscreen) return const <TopActionLeadingSlot>[];
  return <TopActionLeadingSlot>[
    TopActionLeadingSlot.back,
    if (android) TopActionLeadingSlot.datetime,
    if (android) TopActionLeadingSlot.battery,
  ];
}

/// Keeps the three Android playback actions identical in portrait and
/// fullscreen: headphones, casting, then picture-in-picture.
@visibleForTesting
List<TopActionTrailingSlot> resolveTopActionTrailingSlots({
  required bool fullscreen,
  required bool android,
  required bool windows,
}) {
  return <TopActionTrailingSlot>[
    if (fullscreen) TopActionTrailingSlot.roomHistory,
    if (fullscreen && !android) TopActionTrailingSlot.datetime,
    if (fullscreen && !android) TopActionTrailingSlot.battery,
    if (windows) TopActionTrailingSlot.alwaysOnTop,
    TopActionTrailingSlot.audioOnly,
    if (android) TopActionTrailingSlot.cast,
    if (android || windows) TopActionTrailingSlot.pip,
  ];
}

/// The full-surface gesture layer sits below the visible controller bars, but
/// platform accessibility/input bridges can still deliver a tap to that layer
/// while a control is animating. Never reinterpret a tap inside either bar as
/// an on-video danmaku interaction. This also protects the audio/cast/PiP and
/// quality/fullscreen actions from opening a danmaku action sheet instead.
@visibleForTesting
bool shouldHandleVideoSurfaceTap({
  required Offset localPosition,
  required Size surfaceSize,
  required bool controlsVisible,
  double controlBarHeight = 56,
}) {
  if (!controlsVisible || surfaceSize.height <= 0) return true;
  final guardedHeight = controlBarHeight.clamp(0.0, surfaceSize.height / 2).toDouble();
  return localPosition.dy > guardedHeight && localPosition.dy < surfaceSize.height - guardedHeight;
}

@visibleForTesting
String fullscreenActionLabelKey(bool expanded) => expanded ? 'exit_fullscreen' : 'enter_fullscreen';

@visibleForTesting
String playerWindowActionLabelKey(bool expanded) => expanded ? 'collapse_player_window' : 'expand_player_window';

class VideoControllerPanel extends StatefulWidget {
  final VideoController controller;

  const VideoControllerPanel({super.key, required this.controller});

  @override
  State<StatefulWidget> createState() => _VideoControllerPanelState();
}

class _VideoControllerPanelState extends State<VideoControllerPanel> {
  static const barHeight = 56.0;
  Offset? _lastTapLocalPosition;

  /// Ctrl+左键拖拽平移的指针 id（同一时刻只跟踪一根指针）。
  int? _panPointerId;

  /// 当前 Ctrl 是否按下，用于切换 grab/zoomIn 光标。
  bool _ctrlHeld = false;

  VideoController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.enableController();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    // 面板销毁（进入小窗/切换房间）时结束拖拽，避免 grabbing 状态残留。
    controller.endVideoPan();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoControllerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 刷新/切换房间会在同一位置挂载新的 VideoController：结束旧控制器上
    // 可能残留的平移跟踪，避免 grabbing 光标/指针 id 跨房间串状态。
    if (oldWidget.controller != widget.controller) {
      _panPointerId = null;
      _ctrlHeld = HardwareKeyboard.instance.isControlPressed;
      oldWidget.controller.endVideoPan();
    }
  }

  /// 全局按键回调：跟踪 Ctrl 按下/释放。拖拽中松开 Ctrl 立即结束平移，
  /// 否则后续普通移动会继续拖走画面。
  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    final held = HardwareKeyboard.instance.isControlPressed;
    if (held == _ctrlHeld) return false;
    setState(() => _ctrlHeld = held);
    if (!held && _panPointerId != null) {
      _panPointerId = null;
      controller.endVideoPan();
    }
    return false;
  }

  void _startVideoPan(PointerDownEvent event) {
    if (_panPointerId != null) return;
    // 直接读全局实时状态，避免面板挂载前 Ctrl 已按住时本地标志不同步。
    if (!HardwareKeyboard.instance.isControlPressed || !controller.isVideoZoomed) return;
    _panPointerId = event.pointer;
    controller.beginVideoPan();
    // 拖拽期间没有 hover 事件，主动维持控制栏显示，结束后自动隐藏计时照常恢复。
    controller.enableController();
  }

  void _updateVideoPan(PointerMoveEvent event) {
    if (_panPointerId != event.pointer) return;
    // 拖拽过程中松开 Ctrl 立即停止平移（本地标志可能尚未回调）。
    if (!HardwareKeyboard.instance.isControlPressed) {
      _panPointerId = null;
      controller.endVideoPan();
      return;
    }
    controller.panVideoBy(event.delta);
    controller.enableController();
  }

  void _finishVideoPan(PointerEvent event) {
    if (_panPointerId != event.pointer) return;
    _panPointerId = null;
    controller.endVideoPan();
  }

  void _handleVideoZoomScroll(PointerScrollEvent event) {
    if (!HardwareKeyboard.instance.isControlPressed || event.scrollDelta.dy == 0) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    // 面板与视频纹理层铺满同一个 Stack，本地坐标即视频表面坐标。
    final focalPoint = renderObject.globalToLocal(event.position);
    controller.zoomVideoAt(focalPoint: focalPoint, scrollDy: event.scrollDelta.dy);
    controller.enableController();
  }

  MouseCursor _resolveCursor() {
    if (controller.videoPanning.value) return SystemMouseCursors.grabbing;
    if (!controller.showController.value) return SystemMouseCursors.none;
    if (_ctrlHeld) {
      return controller.isVideoZoomed ? SystemMouseCursors.grab : SystemMouseCursors.zoomIn;
    }
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        autofocus: true,
        child: Obx(() {
          final double currentVolume = controller.currentVolume.value;
          final int percentage = (currentVolume * 100).round();

          final IconData iconData = currentVolume <= 0
              ? Icons.volume_mute
              : currentVolume < 0.5
              ? Icons.volume_down
              : Icons.volume_up;

          return MouseRegion(
            onHover: (_) => controller.onMouseHoverPlayer(),
            onExit: (_) => controller.onMouseExitPlayer(),
            cursor: _resolveCursor(),
            // Right-click is the danmaku interaction trigger. A Listener at the
            // stack root receives secondary presses even over the action bars
            // (no control uses right-click), so danmaku beneath the controls
            // stays interactive.
            //
            // Ctrl+滚轮缩放画面、Ctrl+左键拖拽平移也在这一层拦截：滚轮信号
            // 会同时派发给下层音量区域，音量侧另有 Ctrl 守卫跳过，互不影响。
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (event.buttons == kPrimaryButton) {
                  _startVideoPan(event);
                }
                if (event.buttons != kSecondaryMouseButton) return;
                controller.handleDanmakuPointer(event.position);
              },
              onPointerMove: _updateVideoPan,
              onPointerUp: _finishVideoPan,
              onPointerCancel: _finishVideoPan,
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) _handleVideoZoomScroll(event);
              },
              child: Stack(
                children: [
                  Container(
                    color: Colors.transparent,
                    alignment: Alignment.center,
                    child: AnimatedOpacity(
                      opacity: controller.showVolume.value ? 0.8 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: Card(
                        color: Colors.black,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(iconData, color: Colors.white),
                              Padding(
                                padding: const EdgeInsets.only(left: 8, right: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 100,
                                    height: 20,
                                    child: LinearProgressIndicator(
                                      value: currentVolume,
                                      backgroundColor: Colors.white38,
                                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                "$percentage%",
                                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Obx(() {
                    final manager = GlobalPlayerService.instance.player;
                    final hideForPortrait =
                        manager.isVerticalVideo.value &&
                        SettingsService.to.player.portraitDanmakuMode == PortraitDanmakuMode.hidden;
                    return Offstage(
                      offstage: controller.hideDanmaku.value || hideForPortrait,
                      child: DanmakuViewer(key: controller.danmuKey, controller: controller),
                    );
                  }),
                  GestureDetector(
                    onTapDown: (details) {
                      _lastTapLocalPosition = details.localPosition;
                    },
                    onTap: () {
                      // Ctrl+点击属于画面缩放/平移交互，不触发暂停/播放与控制栏切换。
                      if (HardwareKeyboard.instance.isControlPressed) return;
                      final localPosition = _lastTapLocalPosition;
                      if (localPosition != null &&
                          !shouldHandleVideoSurfaceTap(
                            localPosition: localPosition,
                            surfaceSize: context.size ?? Size.zero,
                            controlsVisible: controller.showController.value,
                            controlBarHeight: barHeight,
                          )) {
                        controller.enableController();
                        return;
                      }
                      // A buffering/paused player must not swallow the only way
                      // to reveal its controls. Always expose the action bar; a
                      // tap on a paused surface keeps the historical resume
                      // behavior as well.
                      controller.enableController();
                      if (!GlobalPlayerService.instance.player.isPlayingNow) {
                        GlobalPlayerService.instance.player.togglePlayPause();
                      }
                    },
                    onLongPressStart: (details) {
                      if (HardwareKeyboard.instance.isControlPressed) return;
                      if (!shouldHandleVideoSurfaceTap(
                        localPosition: details.localPosition,
                        surfaceSize: context.size ?? Size.zero,
                        controlsVisible: controller.showController.value,
                        controlBarHeight: barHeight,
                      )) {
                        controller.enableController();
                      }
                    },
                    onDoubleTap: () {
                      if (HardwareKeyboard.instance.isControlPressed) return;
                      if (!controller.showLocked.value) {
                        GlobalPlayerState.to.isWindowFullscreen.value
                            ? controller.toggleWindowFullScreen()
                            : controller.toggleFullScreen();
                      }
                    },
                    child: BrightnessVolumnDargArea(controller: controller),
                  ),
                  LockButton(controller: controller),
                  PlaybackLeftSideButtons(controller: controller),
                  TopActionBar(controller: controller, barHeight: barHeight),
                  BottomActionBar(controller: controller, barHeight: barHeight),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class ErrorWidget extends StatelessWidget {
  const ErrorWidget({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(i18n("play_video_failed"), style: AppTextStyles.t14.copyWith(color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: () => controller.refresh(),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.2)),
            child: Text(i18n("retry"), style: AppTextStyles.t15.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// Top action bar widgets
class TopActionBar extends StatelessWidget {
  const TopActionBar({super.key, required this.controller, required this.barHeight});

  final VideoController controller;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => AnimatedPositioned(
        top: (controller.showController.value && !controller.showLocked.value) ? 0 : -barHeight,
        left: 0,
        right: 0,
        height: barHeight,
        duration: const Duration(milliseconds: 300),
        child: ControlHoverRegion(
          enabled: controller.showController.value && !controller.showLocked.value,
          onEnter: controller.onMouseEnterController,
          onExit: controller.onMouseExitController,
          child: Container(
            height: barHeight,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
              ),
            ),
            child: Row(
              children: [
                for (final slot in resolveTopActionLeadingSlots(
                  fullscreen: GlobalPlayerState.to.fullscreenUI,
                  android: PlatformUtils.isAndroid,
                ))
                  switch (slot) {
                    TopActionLeadingSlot.back => BackButton(controller: controller),
                    TopActionLeadingSlot.datetime => const DatetimeInfo(key: ValueKey('fullscreen-leading-time')),
                    TopActionLeadingSlot.battery => BatteryInfo(
                      key: const ValueKey('fullscreen-leading-battery'),
                      controller: controller,
                    ),
                  },
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.room.title!,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.t16.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (controller.room.currentProgramme != null &&
                            controller.room.currentProgramme!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            "${i18n('now_playing')}: ${controller.room.currentProgramme!}",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                if (controller.room.platform == Sites.iptvSite)
                  IconButton(
                    icon: const Icon(Icons.assignment_outlined), // 节目单账本图标
                    tooltip: i18n('view_schedule'),
                    color: Colors.white,
                    onPressed: () => _showSchedule(context),
                  ),
                for (final slot in resolveTopActionTrailingSlots(
                  fullscreen: GlobalPlayerState.to.fullscreenUI,
                  android: PlatformUtils.isAndroid,
                  windows: PlatformUtils.isWindows,
                ))
                  switch (slot) {
                    TopActionTrailingSlot.roomHistory => IconButton(
                      key: const ValueKey('fullscreen-room-history'),
                      icon: const Icon(Icons.swap_horiz_outlined),
                      tooltip: i18n('switch_live_room'),
                      color: Colors.white,
                      onPressed: () {
                        Get.dialog(PlayOther(controller: Get.find<LivePlayController>()));
                      },
                      style: IconButton.styleFrom(backgroundColor: Colors.black26),
                    ),
                    TopActionTrailingSlot.datetime => const DatetimeInfo(),
                    TopActionTrailingSlot.battery => BatteryInfo(controller: controller),
                    TopActionTrailingSlot.alwaysOnTop => AlwaysOnTopButton(
                      key: const ValueKey('playback-action-always-on-top'),
                      controller: controller,
                    ),
                    TopActionTrailingSlot.audioOnly => AudioOnlyButton(
                      key: const ValueKey('playback-action-audio-only'),
                      controller: controller,
                    ),
                    TopActionTrailingSlot.cast => CastButton(
                      key: const ValueKey('playback-action-cast'),
                      controller: controller,
                    ),
                    TopActionTrailingSlot.pip => PIPButton(
                      key: GlobalPlayerState.to.fullscreenUI
                          ? const ValueKey('fullscreen-pip-shortcut')
                          : const ValueKey('playback-action-pip'),
                      controller: controller,
                    ),
                  },
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSchedule(BuildContext context) async {
    if (controller.isMenuOpen.value) return;
    controller.isMenuOpen.value = true;
    controller.stopHideController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: EdgeInsets.zero,
          content: IptvScheduleDialogContent(controller: controller),
        ),
      );
    } finally {
      if (controller.status != PlayerStatus.disposed) {
        controller.isMenuOpen.value = false;
        controller.enableController();
      }
    }
  }
}

class DatetimeInfo extends StatefulWidget {
  const DatetimeInfo({super.key});

  @override
  State<DatetimeInfo> createState() => _DatetimeInfoState();
}

class _DatetimeInfoState extends State<DatetimeInfo> {
  DateTime dateTime = DateTime.now();
  Timer? refreshDateTimer;

  @override
  void initState() {
    super.initState();
    refreshDateTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      setState(() => dateTime = DateTime.now());
    });
  }

  @override
  void dispose() {
    super.dispose();
    refreshDateTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    // get system time and format
    var hour = dateTime.hour.toString();
    if (hour.length < 2) hour = '0$hour';
    var minute = dateTime.minute.toString();
    if (minute.length < 2) minute = '0$minute';

    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: Text(
        '$hour:$minute',
        style: const TextStyle(color: Colors.white, decoration: TextDecoration.none),
      ),
    );
  }
}

class BatteryInfo extends StatefulWidget {
  const BatteryInfo({super.key, required this.controller});

  final VideoController controller;

  @override
  State<BatteryInfo> createState() => _BatteryInfoState();
}

class _BatteryInfoState extends State<BatteryInfo> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Container(
        width: 35,
        height: 15,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.4),
          border: Border.all(color: Colors.white),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: Obx(
            () => Text(
              '${widget.controller.batteryLevel.value}',
              style: const TextStyle(color: Colors.white, fontSize: 9, decoration: TextDecoration.none),
            ),
          ),
        ),
      ),
    );
  }
}

class BackButton extends StatelessWidget {
  const BackButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => GlobalPlayerState.to.isWindowFullscreen.value
          ? controller.toggleWindowFullScreen()
          : controller.toggleFullScreen(),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: const Icon(Icons.arrow_back_rounded, color: Colors.white),
      ),
    );
  }
}

class PIPButton extends StatelessWidget {
  const PIPButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    final miniPip = Get.isRegistered<LivePlayController>() ? Get.find<LivePlayController>().miniPip : null;
    return Obx(() {
      final manager = GlobalPlayerService.instance.player;
      // 新进程内小窗存在时暂时禁用旧 Windows PiP：两套浮窗的视频/窗口
      // 状态互不感知，同时激活会造成主画面归属混乱。
      final blockedByMiniPip = miniPip?.slots.isNotEmpty ?? false;
      final disabled = manager.isPipPreparing.value || blockedByMiniPip;
      return IconButton(
        tooltip: i18n(blockedByMiniPip ? 'pip_disabled_by_mini_pip' : 'float_window_play'),
        color: Colors.white,
        onPressed: disabled
            ? null
            : () async {
                try {
                  await manager.enablePip();
                } catch (_) {
                  ToastUtil.show(i18n('pip_enter_failed'));
                }
              },
        icon: const Icon(CustomIcons.float_window),
      );
    });
  }
}

// Center widgets
class DanmakuViewer extends StatelessWidget {
  const DanmakuViewer({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final settings = SettingsService.to.danmaku;
      final playerSettings = SettingsService.to.player;
      final portraitSource = GlobalPlayerService.instance.player.isVerticalVideo.value;
      final portraitMode = portraitSource ? playerSettings.portraitDanmakuMode : PortraitDanmakuMode.followGlobal;
      final effectiveArea = switch (portraitMode) {
        PortraitDanmakuMode.upperQuarter => controller.danmakuArea.value.clamp(0.0, 0.25).toDouble(),
        PortraitDanmakuMode.reduced => controller.danmakuArea.value.clamp(0.0, 0.50).toDouble(),
        _ => controller.danmakuArea.value,
      };
      // LayoutBuilder runs after the Obx collection window, so read every
      // reactive value above and keep width-derived values purely local.
      return LayoutBuilder(
        builder: (context, constraints) {
          final surfaceWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : MainDanmakuMetrics.referenceWidth;
          // updateDanmaku() re-pushes the config on settings changes without
          // layout knowledge; publish the measured width for it.
          controller.mainDanmakuSurfaceWidth = surfaceWidth;
          final densityMode = settings.danmakuDensityMode.v;
          final fontSize = controller.danmakuFontSize.value;
          final speedScale = MainDanmakuMetrics.resolveSpeedScale(
            width: surfaceWidth,
            adaptive: settings.danmakuWidthAdaptiveSpeed.v,
          );
          final safeGap =
              MainDanmakuMetrics.resolveOverlapSafeGap(fontSize) *
              MainDanmakuMetrics.resolveSafeGapMultiplier(densityMode);
          return FlameBarrageWidget(
            controller: controller.danmakuController,
            // Video gestures own the full surface and forward only hits on actual
            // barrage bounds, so volume/brightness/double-tap remain responsive.
            enablePointerEvents: false,
            config: BarrageConfig(
              emitInterval: 0.05,
              fontSize: fontSize,
              topAreaDistance: controller.danmakuTopArea.value,
              area: effectiveArea,
              bottomAreaDistance: controller.danmakuBottomArea.value,
              baseSpeed: controller.danmakuSpeed.value * speedScale,
              opacity: (controller.danmakuOpacity.value * MainDanmakuMetrics.resolveOpacityMultiplier(densityMode))
                  .clamp(0.0, 1.0)
                  .toDouble(),
              fontWeight: FontWeight(controller.danmakuFontWeight.value),
              strokeWidth: controller.danmakuFontBorder.value,
              showStroke: controller.enableDanmakuStroke.value,
              noEmojiMode: controller.noEmojiMode.value,
              fps: settings.danmakuAutoFps.v
                  ? settings.resolvedDanmakuFps(refreshRateMode: SettingsService.to.app.refreshRateMode)
                  : controller.danmakuFps.value.clamp(30, 240).toInt(),
              maxVisibleCount: settings.danmakuMaxVisibleCount.v,
              maxPendingCount: 120,
              maxPendingAge: const Duration(seconds: 5),
              fontFamily: controller.danmakuFontFamilyName.value,
              trackHeight: (fontSize * 1.55).clamp(24.0, 64.0).toDouble(),
              emojiSize: (fontSize * 1.3).clamp(16.0, 48.0).toDouble(),
              overlapSafeGap: safeGap,
              allowOverlap: MainDanmakuMetrics.resolveAllowOverlap(densityMode),
              pictureCacheMaxSize: 96,
              barragePoolMaxSize: 72,
              textCacheMaxSize: 320,
            ),
            emojiAtlas: EmojiAtlas.instance,
          );
        },
      );
    });
  }
}

class BrightnessVolumnDargArea extends StatefulWidget {
  const BrightnessVolumnDargArea({super.key, required this.controller});

  final VideoController controller;

  @override
  State<BrightnessVolumnDargArea> createState() => BrightnessVolumnDargAreaState();
}

class BrightnessVolumnDargAreaState extends State<BrightnessVolumnDargArea> {
  VideoController get controller => widget.controller;

  Timer? _hideBVTimer;
  Timer? _activateTimer;
  bool _hideBVStuff = true;
  bool _isBrightness = false;
  bool _isActivated = false;
  double _updateDargVarVal = 1.0;
  double _cachedBrightness = 0.5;

  static const Duration _activateDelay = Duration(milliseconds: 300);

  static const double _dragPixelsPerFullRange = 560.0;
  static const double _wheelDyPerStep = 120.0;
  static const double _wheelStepRatio = 0.05;

  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isMobile) {
      controller.brightness().then((v) {
        if (mounted) _cachedBrightness = v;
      });
    }
  }

  @override
  void dispose() {
    _hideBVTimer?.cancel();
    _activateTimer?.cancel();
    super.dispose();
  }

  void updateVolumn(double? volume) {
    _isBrightness = false;
    _cancelAndRestartHideBVTimer();
    setState(() {
      _updateDargVarVal = volume!;
    });
  }

  void _cancelAndRestartHideBVTimer() {
    _hideBVTimer?.cancel();
    _hideBVTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _hideBVStuff = true);
    });
    setState(() => _hideBVStuff = false);
  }

  void _syncBaseValue(Offset position) {
    final size = MediaQuery.of(context).size;
    final isLeft = position.dx <= (size.width / 2);

    if (Platform.isWindows && isLeft) {
      _isBrightness = false;
      _updateDargVarVal = controller.currentVolume.value;
      return;
    }

    final newIsBrightness = isLeft && PlatformUtils.isMobile;

    if (newIsBrightness != _isBrightness) {
      _isBrightness = newIsBrightness;
      _updateDargVarVal = _isBrightness ? _cachedBrightness : controller.currentVolume.value;
    } else if (_hideBVStuff) {
      _updateDargVarVal = _isBrightness ? _cachedBrightness : controller.currentVolume.value;
    }
  }

  void _applyVerticalDelta(double dy) {
    if (controller.showLocked.value) return;

    double deltaValue = -(dy / _dragPixelsPerFullRange);
    double nextValue = (_updateDargVarVal + deltaValue).clamp(0.0, 1.0);

    if ((nextValue - _updateDargVarVal).abs() < 0.001) return;

    _updateDargVarVal = nextValue;
    if (_isBrightness) {
      _cachedBrightness = nextValue;
      controller.setBrightness(nextValue);
    } else {
      controller.setVolume(nextValue);
    }
    setState(() {});
  }

  void _applyScrollDelta(double dy) {
    if (controller.showLocked.value) return;

    double deltaValue = -(dy / _wheelDyPerStep) * _wheelStepRatio;
    double nextValue = (_updateDargVarVal + deltaValue).clamp(0.0, 1.0);

    if ((nextValue - _updateDargVarVal).abs() < 0.001) return;

    _updateDargVarVal = nextValue;
    if (_isBrightness) {
      _cachedBrightness = nextValue;
      controller.setBrightness(nextValue);
    } else {
      controller.setVolume(nextValue);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    IconData iconData;
    if (_isBrightness) {
      iconData = _updateDargVarVal <= 0
          ? Icons.brightness_low
          : _updateDargVarVal < 0.5
          ? Icons.brightness_medium
          : Icons.brightness_high;
    } else {
      iconData = _updateDargVarVal <= 0
          ? Icons.volume_mute
          : _updateDargVarVal < 0.5
          ? Icons.volume_down
          : Icons.volume_up;
    }

    final int percentage = (_updateDargVarVal * 100).round();

    return Listener(
      onPointerDown: (event) {
        // Ctrl+左键拖拽是画面平移手势，不启动音量/亮度竖向调节。
        if (event.buttons == kPrimaryButton && HardwareKeyboard.instance.isControlPressed) return;
        if (event.buttons != kPrimaryButton) return;
        _syncBaseValue(event.position);
        if (Platform.isWindows && _isBrightness) return;
        _activateTimer?.cancel();
        _isActivated = false;
        _activateTimer = Timer(_activateDelay, () {
          if (!mounted) return;
          _isActivated = true;
          _cancelAndRestartHideBVTimer();
        });
      },
      onPointerMove: (event) {
        if (HardwareKeyboard.instance.isControlPressed) return;
        if (!_isActivated) return;
        _applyVerticalDelta(event.delta.dy);
        _cancelAndRestartHideBVTimer();
      },
      onPointerUp: (_) {
        _activateTimer?.cancel();
        _isActivated = false;
      },
      onPointerCancel: (_) {
        _activateTimer?.cancel();
        _isActivated = false;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          // Ctrl+滚轮用于等比例缩放画面，此处跳过，音量保持不变。
          if (HardwareKeyboard.instance.isControlPressed) return;
          _syncBaseValue(event.position);
          if (Platform.isWindows && _isBrightness) return;
          _applyScrollDelta(event.scrollDelta.dy);
          _cancelAndRestartHideBVTimer();
        }
      },
      child: Container(
        color: Colors.transparent,
        alignment: Alignment.center,
        child: AnimatedOpacity(
          opacity: !_hideBVStuff ? 0.8 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: Card(
            color: Colors.black,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(iconData, color: Colors.white),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 100,
                        height: 20,
                        child: LinearProgressIndicator(
                          value: _updateDargVarVal,
                          backgroundColor: Colors.white38,
                          valueColor: const AlwaysStoppedAnimation(Colors.white),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    '$percentage%',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LockButton extends StatelessWidget {
  const LockButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => AnimatedOpacity(
        opacity: (GlobalPlayerState.to.fullscreenUI && controller.showController.value) ? 0.9 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Align(
          alignment: Alignment.centerRight,
          child: AbsorbPointer(
            absorbing: !controller.showController.value,
            child: Container(
              margin: const EdgeInsets.only(right: 20.0),
              child: IconButton(
                onPressed: () => {controller.showLocked.toggle()},
                icon: Icon(controller.showLocked.value ? Icons.lock_rounded : Icons.lock_open_rounded, size: 28),
                color: Colors.white,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black38,
                  shape: const StadiumBorder(),
                  minimumSize: const Size(50, 50),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放器左侧按钮列：截图按钮，以及画面被缩放后出现在其正上方的
/// "重置画面"按钮（风格与截图按钮一致）。
class PlaybackLeftSideButtons extends StatelessWidget {
  const PlaybackLeftSideButtons({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 20,
      top: 0,
      bottom: 0,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 未缩放时重置按钮折叠为零高度，截图按钮保持垂直居中；
            // 缩放后展开并与截图按钮间隔 16px。
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              alignment: Alignment.bottomCenter,
              child: Obx(() {
                if (!controller.isVideoZoomed) return const SizedBox(width: 50, height: 0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoZoomResetButton(controller: controller),
                    const SizedBox(height: 16),
                  ],
                );
              }),
            ),
            ScreenshotButton(controller: controller),
          ],
        ),
      ),
    );
  }
}

/// 画面缩放后的"重置画面大小和位置"按钮，样式与截图按钮完全一致，
/// 显隐同样跟随控制栏（控制栏自动隐藏时一起淡出且不响应点击）。
class VideoZoomResetButton extends StatelessWidget {
  const VideoZoomResetButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => AnimatedOpacity(
        opacity: controller.showController.value ? 0.9 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: AbsorbPointer(
          absorbing: !controller.showController.value,
          child: IconButton(
            tooltip: i18n('reset_video_zoom'),
            onPressed: controller.resetVideoTransform,
            icon: const Icon(Icons.fit_screen_rounded, size: 28),
            color: Colors.white,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black38,
              shape: const StadiumBorder(),
              minimumSize: const Size(50, 50),
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放器左侧的截屏按钮（与右侧锁定按钮位置对称的播放器控件），
/// 跟随控件栏显隐，任何窗口尺寸/模式下都可用，不限于宽屏模式。
/// 截取 mpv 原始解码帧（不含 UI 控件），保存到设置的截图目录。
class ScreenshotButton extends StatelessWidget {
  const ScreenshotButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => AnimatedOpacity(
        opacity: controller.showController.value ? 0.9 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: AbsorbPointer(
          absorbing: !controller.showController.value,
          child: IconButton(
            onPressed: controller.takeScreenshot,
            icon: const Icon(Icons.photo_camera_outlined, size: 28),
            color: Colors.white,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black38,
              shape: const StadiumBorder(),
              minimumSize: const Size(50, 50),
            ),
          ),
        ),
      ),
    );
  }
}

class LineSelectorButton extends StatelessWidget {
  const LineSelectorButton({super.key, required this.controller});

  final VideoController controller;

  void _showMobileDialog(BuildContext context) {
    controller.isMenuOpen.value = true;
    controller.stopHideController();

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16.0),
        clipBehavior: Clip.hardEdge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 10, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(i18n("select_line"), style: Theme.of(context).textTheme.titleMedium),
                    IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Obx(
                  () => ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: controller.livePlayController.state.value.player.lineCount,
                    itemBuilder: (context, index) {
                      final isSelected = index == controller.livePlayController.state.value.player.currentLineIndex;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Center(
                          child: InkWell(
                            onTap: () {
                              controller.livePlayController.setResolution(
                                ReloadDataType.changeLine,
                                controller.livePlayController.state.value.player.currentQuality,
                                index,
                              );
                              Navigator.of(context).pop();
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Container(
                                width: double.infinity, // 设定按钮固定宽度
                                height: 38, // 设定按钮高度
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Get.theme.colorScheme.primary
                                      : Get.theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  i18n("toolbox_line", args: {"index": (index + 1).toString()}),
                                  style: AppTextStyles.t15.copyWith(color: isSelected ? Colors.white : null),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel')))],
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      controller.isMenuOpen.value = false;
      controller.enableController();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!controller.livePlayController.state.value.player.hasPlaybackSource) return const SizedBox.shrink();
      final bool isMobile =
          Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;

      if (isMobile) {
        return GestureDetector(onTap: () => _showMobileDialog(context), child: _buildButtonChild());
      }

      const double itemHeight = 40.0;
      final double totalMenuHeight = (controller.livePlayController.state.value.player.lineCount * itemHeight) + 32;
      return Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          final state = controller.livePlayController.state.value.player;
          if (state.lineCount <= 1) return;
          final dir = event.scrollDelta.dy > 0 ? 1 : -1;
          final next = (state.currentLineIndex + dir) % state.lineCount;
          if (next == state.currentLineIndex) return;
          controller.livePlayController.setResolution(ReloadDataType.changeLine, state.currentQuality, next);
        },
        child: PopupMenuButton<int>(
          position: PopupMenuPosition.over,
          offset: Offset(30, -totalMenuHeight),
          constraints: const BoxConstraints(minWidth: 110, maxWidth: 110),
          onOpened: () {
            controller.isMenuOpen.value = true;
            controller.stopHideController();
          },
          onSelected: (index) {
            controller.isMenuOpen.value = false;
            controller.livePlayController.setResolution(
              ReloadDataType.changeLine,
              controller.livePlayController.state.value.player.currentQuality,
              index,
            );
            controller.enableController();
          },
          onCanceled: () {
            controller.isMenuOpen.value = false;
            controller.enableController();
          },
          color: Colors.black.withValues(alpha: 0.85),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white10),
          ),
          child: _buildButtonChild(),
          itemBuilder: (context) => List.generate(controller.livePlayController.state.value.player.lineCount, (index) {
            final isSelected = index == controller.livePlayController.state.value.player.currentLineIndex;
            return PopupMenuItem(
              value: index,
              height: itemHeight,
              child: Center(
                child: Text(
                  i18n("toolbox_line", args: {"index": (index + 1).toString()}),
                  style: AppTextStyles.t13.copyWith(color: isSelected ? Get.theme.colorScheme.primary : Colors.white),
                ),
              ),
            );
          }),
        ),
      );
    });
  }

  Widget _buildButtonChild() {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
      child: Text(
        i18n(
          "toolbox_line",
          args: {"index": (controller.livePlayController.state.value.player.currentLineIndex + 1).toString()},
        ),
        style: AppTextStyles.t13.copyWith(color: Colors.white),
      ),
    );
  }
}

class ResolutionSelectorButton extends StatelessWidget {
  const ResolutionSelectorButton({super.key, required this.controller});

  final VideoController controller;

  void _showMobileDialog(BuildContext context) {
    controller.isMenuOpen.value = true;
    controller.stopHideController();

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16.0),
        clipBehavior: Clip.hardEdge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 10, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(i18n("select_quality"), style: Theme.of(context).textTheme.titleMedium),
                    IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Obx(
                  () => ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: controller.livePlayController.state.value.player.qualites.length,
                    itemBuilder: (context, index) {
                      final isSelected = index == controller.livePlayController.state.value.player.currentQuality;
                      final qualityName = controller.livePlayController.state.value.player.qualites[index].quality;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Center(
                          child: InkWell(
                            onTap: () {
                              controller.livePlayController.setResolution(
                                ReloadDataType.changeQuality,
                                index,
                                controller.livePlayController.state.value.player.currentLineIndex,
                              );
                              Navigator.of(context).pop();
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Container(
                                width: double.infinity, // 独占一行宽度
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Get.theme.colorScheme.primary
                                      : Get.theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  qualityName,
                                  style: AppTextStyles.t15.copyWith(color: isSelected ? Colors.white : null),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel')))],
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      controller.isMenuOpen.value = false;
      controller.enableController();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.livePlayController.state.value.player.qualites.isEmpty) return const SizedBox.shrink();

      final bool isMobile =
          Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;

      if (isMobile) {
        return GestureDetector(onTap: () => _showMobileDialog(context), child: _buildButtonChild());
      }

      // Windows 桌面端样式
      final qualityCount = controller.livePlayController.state.value.player.qualites.length;
      const double itemHeight = 40.0;
      final double totalMenuHeight = (qualityCount * itemHeight) + 32;

      return Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          final state = controller.livePlayController.state.value.player;
          if (state.qualites.length <= 1) return;
          final dir = event.scrollDelta.dy > 0 ? 1 : -1;
          final next = (state.currentQuality + dir) % state.qualites.length;
          if (next == state.currentQuality) return;
          controller.livePlayController.setResolution(ReloadDataType.changeQuality, next, state.currentLineIndex);
        },
        child: PopupMenuButton<int>(
          tooltip: i18n('toolbox_select_quality'),
          position: PopupMenuPosition.over,
          offset: Offset(15, -totalMenuHeight),
          padding: EdgeInsets.zero,
          onOpened: () {
            controller.isMenuOpen.value = true;
            controller.stopHideController();
          },
          onCanceled: () {
            controller.isMenuOpen.value = false;
            controller.enableController();
          },
          onSelected: (index) {
            controller.isMenuOpen.value = false;
            controller.livePlayController.setResolution(
              ReloadDataType.changeQuality,
              index,
              controller.livePlayController.state.value.player.currentLineIndex,
            );
            controller.enableController();
          },
          color: Colors.black.withValues(alpha: 0.85),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white10),
          ),
          child: _buildButtonChild(),
          itemBuilder: (context) => List.generate(qualityCount, (index) {
            final isSelected = index == controller.livePlayController.state.value.player.currentQuality;
            return PopupMenuItem(
              value: index,
              height: itemHeight,
              child: Center(
                child: Text(
                  controller.livePlayController.state.value.player.qualites[index].quality,
                  style: AppTextStyles.t13.copyWith(color: isSelected ? Get.theme.colorScheme.primary : Colors.white),
                ),
              ),
            );
          }),
        ),
      );
    });
  }

  Widget _buildButtonChild() {
    final qualityName = controller.livePlayController.state.value.player.qualitySafe.playbackLabel;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
      child: Text(qualityName, style: AppTextStyles.t13.copyWith(color: Colors.white)),
    );
  }
}

/// Compact fullscreen entry for quality and CDN-line selection. Both controls
/// live in one landscape panel, avoiding two narrow menus competing for the
/// bottom-right safe area.
class FullscreenStreamSelectorButton extends StatefulWidget {
  const FullscreenStreamSelectorButton({super.key, required this.controller});

  final VideoController controller;

  @override
  State<FullscreenStreamSelectorButton> createState() => _FullscreenStreamSelectorButtonState();
}

/// 单行文本测宽：用于悬浮面板按内容自适应尺寸。
double _measureTextWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// 清晰度/线路面板的布局结果：整体尺寸与两个窗格的列数。
class _StreamPanelLayout {
  const _StreamPanelLayout({required this.size, required this.qualityColumns, required this.lineColumns});

  final Size size;
  final int qualityColumns;
  final int lineColumns;
}

/// 清晰度/线路合并胶囊：对齐音量控件的悬浮交互——鼠标移入即在按钮上方
/// 弹出选择面板（复用 [_StreamChoicePane] 双栏），移出后延迟收起。
/// 面板尺寸按内容自适应：宽度由最长标签与标题行测量得出，高度由选项
/// 行数得出；超出上限时收窄，再由网格滚动兜底。
class _FullscreenStreamSelectorButtonState extends State<FullscreenStreamSelectorButton> {
  /// 面板总宽度上限：两个窗格 + 中缝 8 + 外层左右内边距 16。
  static const double _maxPanelWidth = 480.0;

  /// 单个窗格内容高度上限：超过后改双列，仍超出则由网格滚动兜底。
  static const double _maxPaneHeight = 300.0;

  /// 与 [_StreamChoicePane] 的网格常量保持一致。
  static const double _paneGridExtent = 38.0;
  static const double _paneGridSpacing = 5.0;

  VideoController get controller => widget.controller;

  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInButton = false;
  bool _isMouseInPanel = false;
  Timer? _hideTimer;

  /// 面板展示期间绑定的控制器，移除面板时向其归还 isMenuOpen 状态。
  VideoController? _panelOwner;

  @override
  void didUpdateWidget(covariant FullscreenStreamSelectorButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, controller)) return;
    _hideTimer?.cancel();
    _removeOverlay(owner: oldWidget.controller);
    _isMouseInButton = false;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showPanel() {
    if (_overlayEntry != null || !mounted) return;
    final owner = controller;
    _panelOwner = owner;
    owner.isMenuOpen.value = true;
    owner.stopHideController();

    _overlayEntry = OverlayEntry(
      builder: (context) => Obx(() {
        // 尺寸跟随房间数据（清晰度/线路数量与标签长度）实时自适应。
        final layout = _computePanelLayout(context);
        return Positioned(
          width: layout.size.width,
          height: layout.size.height + 6,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            followerAnchor: Alignment.bottomCenter,
            targetAnchor: Alignment.topCenter,
            offset: const Offset(0, 6),
            child: MouseRegion(
              onEnter: (_) {
                _isMouseInPanel = true;
                owner.stopHideController();
              },
              onExit: (_) {
                _isMouseInPanel = false;
                owner.enableController();
                _startHideTimer();
              },
              child: _buildPanel(context, layout),
            ),
          ),
        );
      }),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  /// 按内容计算面板尺寸：宽度由最长标签（含选中态让位）与标题行决定，
  /// 高度由选项行数决定；两个窗格等宽并排。
  _StreamPanelLayout _computePanelLayout(BuildContext context) {
    final live = controller.livePlayController;
    final state = live.state.value.player;
    final textTheme = Theme.of(context).textTheme;

    final panes = [
      (
        title: i18n('select_quality'),
        count: state.qualites.length,
        label: (int index) => state.qualites[index].quality,
      ),
      (
        title: i18n('select_line'),
        count: state.playUrls.length,
        label: (int index) => i18n('toolbox_line', args: {'index': '${index + 1}'}),
      ),
    ];

    var paneWidth = 0.0;
    var paneHeight = 0.0;
    for (final pane in panes) {
      var maxLabelWidth = 0.0;
      for (var i = 0; i < pane.count; i++) {
        maxLabelWidth = math.max(
          maxLabelWidth,
          _measureTextWidth(context, pane.label(i), textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
        );
      }
      // 单元格宽 = 标签 + 左右内边距 12 + 选中态文本让位与勾选图标 33。
      final cellWidth = maxLabelWidth + 45;
      final columns = _paneColumns(pane.count);
      final gridWidth = columns * cellWidth + (columns - 1) * _paneGridSpacing;
      var width = gridWidth + 16; // 窗格左右内边距 14 + 边框 2

      // 标题行（图标 16 + 间距 6 + 标题 + 计数）同样需要放得下。
      final titleWidth = _measureTextWidth(
        context,
        pane.title,
        textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      );
      final countWidth = pane.count > 0 ? _measureTextWidth(context, '${pane.count}', textTheme.labelSmall) : 0.0;
      width = math.max(width, 16 + 16 + 6 + titleWidth + 4 + countWidth);

      paneWidth = math.max(paneWidth, width);
      paneHeight = math.max(paneHeight, _paneContentHeight(pane.count, columns));
    }

    // 总宽上限平分到两个窗格；总高超出则由网格滚动兜底。
    paneWidth = math.min(paneWidth, (_maxPanelWidth - 24) / 2);
    paneHeight = math.min(paneHeight, _maxPaneHeight);
    return _StreamPanelLayout(
      size: Size(paneWidth * 2 + 24, paneHeight + 16), // + 外层 Padding 上下 16
      qualityColumns: _paneColumns(panes[0].count),
      lineColumns: _paneColumns(panes[1].count),
    );
  }

  /// 单列高度超出上限时改用两列；仍超出则由网格滚动兜底。
  int _paneColumns(int count) {
    if (count <= 1) return 1;
    if (_paneContentHeight(count, 1) > _maxPaneHeight) return 2;
    return 1;
  }

  /// 窗格内容高度 = 标题行 25 + 分隔线 7 + 网格 + 上下内边距 12 + 边框 2。
  double _paneContentHeight(int count, int columns) {
    final rows = count <= 0 ? 1 : (count / columns).ceil();
    final gridHeight = rows * _paneGridExtent + (rows - 1) * _paneGridSpacing;
    return 25 + 7 + gridHeight + 12 + 2;
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_isMouseInButton && !_isMouseInPanel) {
        _removeOverlay();
      }
    });
  }

  void _removeOverlay({VideoController? owner}) {
    _hideTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    _isMouseInPanel = false;
    final target = owner ?? _panelOwner ?? controller;
    if (target.status != PlayerStatus.disposed) {
      target.isMenuOpen.value = false;
      target.enableController();
    }
    _panelOwner = null;
  }

  Widget _buildPanel(BuildContext context, _StreamPanelLayout layout) {
    final live = controller.livePlayController;
    final state = live.state.value.player;
    final switching = live.playerController.isStreamSwitching.value;
    final colorScheme = Theme.of(context).colorScheme;

    final qualityPane = _StreamChoicePane(
      key: const ValueKey('stream-quality-pane'),
      icon: Icons.high_quality_rounded,
      title: i18n('select_quality'),
      itemCount: state.qualites.length,
      columns: layout.qualityColumns,
      selectedIndex: state.currentQuality,
      labelBuilder: (index) {
        return state.qualites[index].quality;
      },
      onSelected: switching
          ? null
          : (index) async {
              await live.setResolution(ReloadDataType.changeQuality, index, state.currentLineIndex);
            },
    );

    final linePane = _StreamChoicePane(
      key: const ValueKey('stream-line-pane'),
      icon: Icons.alt_route_rounded,
      title: i18n('select_line'),
      itemCount: state.playUrls.length,
      columns: layout.lineColumns,
      selectedIndex: state.currentLineIndex,
      labelBuilder: (index) {
        return i18n('toolbox_line', args: {'index': (index + 1).toString()});
      },
      onSelected: switching
          ? null
          : (index) async {
              await live.setResolution(ReloadDataType.changeLine, state.currentQuality, index);
            },
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colorScheme.surface,
        elevation: 8,
        shadowColor: Colors.black45,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: layout.size.width,
          height: layout.size.height,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: qualityPane),
                const SizedBox(width: 8),
                Expanded(child: linePane),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final live = controller.livePlayController;
      final state = live.state.value.player;
      if (!live.state.value.room.success || state.qualites.isEmpty || state.playUrls.isEmpty) {
        return const SizedBox.shrink();
      }
      final switching = live.playerController.isStreamSwitching.value;
      final label =
          '${state.qualitySafe.quality} · ${i18n('toolbox_line', args: {'index': '${state.currentLineIndex + 1}'})}';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: CompositedTransformTarget(
          link: _layerLink,
          child: MouseRegion(
            onEnter: (_) {
              _isMouseInButton = true;
              _showPanel();
            },
            onExit: (_) {
              _isMouseInButton = false;
              _startHideTimer();
            },
            child: Material(
              key: const ValueKey('fullscreen-stream-selector'),
              color: Colors.white.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    switching
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.tune_rounded, size: 17, color: Colors.white),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.t13.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _StreamChoicePane extends StatelessWidget {
  const _StreamChoicePane({
    super.key,
    required this.icon,
    required this.title,
    required this.itemCount,
    required this.selectedIndex,
    required this.labelBuilder,
    required this.onSelected,
    this.columns,
  });

  final IconData icon;
  final String title;
  final int itemCount;
  final int selectedIndex;
  final String Function(int index) labelBuilder;
  final Future<void> Function(int index)? onSelected;

  /// 指定列数时跳过 [resolveStreamChoiceColumns] 的宽度阈值推断，
  /// 供内容自适应面板按测量结果精确布局。
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 5, 7, 7),
        child: Column(
          children: [
            SizedBox(
              height: 25,
              child: Row(
                children: [
                  Icon(icon, size: 16, color: colors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (itemCount > 0)
                    Text(
                      '$itemCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 7, thickness: 1, color: colors.outlineVariant.withValues(alpha: .45)),
            Expanded(
              child: itemCount <= 0
                  ? Center(
                      child: Text('—', style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final gridColumns =
                            columns ?? resolveStreamChoiceColumns(constraints.maxWidth, itemCount: itemCount);

                        return GridView.builder(
                          primary: false,
                          padding: EdgeInsets.zero,
                          physics: const PureLiveScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: gridColumns,
                            mainAxisExtent: 38,
                            mainAxisSpacing: 5,
                            crossAxisSpacing: 5,
                          ),
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                            final selected = selectedIndex == index;

                            return _StreamChoiceItem(
                              label: labelBuilder(index),
                              selected: selected,
                              enabled: onSelected != null && !selected,
                              onTap: onSelected == null || selected
                                  ? null
                                  : () {
                                      unawaited(onSelected!(index));
                                    },
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamChoiceItem extends StatelessWidget {
  const _StreamChoiceItem({required this.label, required this.selected, required this.enabled, required this.onTap});

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Material(
      color: selected ? colors.primaryContainer.withValues(alpha: .82) : colors.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? colors.primary.withValues(alpha: .65) : colors.outlineVariant.withValues(alpha: .2),
          width: selected ? 1.2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        hoverColor: colors.primary.withValues(alpha: .08),
        splashColor: colors.primary.withValues(alpha: .12),
        highlightColor: colors.primary.withValues(alpha: .06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(left: selected ? 15 : 2, right: selected ? 18 : 2),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? colors.onPrimaryContainer : colors.onSurface,
                  ),
                ),
              ),
              if (selected)
                Positioned(right: 0, child: Icon(Icons.check_circle_rounded, size: 15, color: colors.primary)),
            ],
          ),
        ),
      ),
    );
  }
}

// Bottom action bar widgets
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.controller, required this.barHeight});

  final VideoController controller;
  final double barHeight;

  /// Vertical space reserved for the live cache progress bar above the
  /// playback button row.
  static const double progressBarSlot = 28.0;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      bool shouldShow =
          (controller.showController.value || controller.isMenuOpen.value) && !controller.showLocked.value;

      // 控制栏结构依赖的响应式值必须在 Obx 的同步 build 阶段读取以注册
      // 依赖：下方 LayoutBuilder 的 builder 在布局阶段执行，其中的 Rx 读取
      // 不会被 Obx 收集，值变化不触发重建。
      final playerState = GlobalPlayerState.to;
      final fullscreen = playerState.fullscreenUI;
      final isPipMode = playerState.isPipMode.value;
      final enableImmersiveLayout = SettingsService.to.player.enableImmersiveLayout.v;
      final localInteractionEnabled = controller.livePlayController.localInteractionController.enabled.value;
      final enableDanmakuDisplay = SettingsService.to.danmaku.enableDanmakuDisplay.v;
      final isFullscreen = playerState.isFullscreen.value;
      final isWindowFullscreen = playerState.isWindowFullscreen.value;

      return BottomControlSurface(
        visible: shouldShow,
        height: barHeight + progressBarSlot,
        child: ControlHoverRegion(
          enabled: shouldShow,
          onEnter: controller.onMouseEnterController,
          onExit: controller.onMouseExitController,
          child: Container(
            height: barHeight + progressBarSlot,
            alignment: Alignment.bottomLeft,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                LiveProgressBar(controller: controller),
                SizedBox(
                  height: barHeight,
                  child: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 沉浸模式：非全屏时底栏复用全屏分支布局
                        // （居中发送框 + 清晰度/线路合并胶囊），与宽屏全屏底栏一致。
                        final immersive = !fullscreen && !isPipMode && enableImmersiveLayout;
                        final fullscreenStyle = fullscreen || immersive;
                        final compact = constraints.maxWidth < 760;
                        final left = _buildLeftActions(
                          compact: fullscreenStyle && compact && localInteractionEnabled,
                          enableDanmakuDisplay: enableDanmakuDisplay,
                        );
                        final right = _buildRightActions(
                          compact: fullscreenStyle && compact,
                          showStreamSelector: fullscreen || (!isPipMode && enableImmersiveLayout),
                          isFullscreen: isFullscreen,
                          isWindowFullscreen: isWindowFullscreen,
                        );

                        if (fullscreenStyle) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                left,
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 420),
                                      child: FullscreenLocalDanmakuComposer(controller: controller),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                right,
                              ],
                            ),
                          );
                        }

                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const PureLiveBoundedScrollPhysics(),
                          clipBehavior: Clip.hardEdge,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: constraints.maxWidth),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [left, right]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildLeftActions({required bool compact, required bool enableDanmakuDisplay}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayPauseButton(controller: controller),
        LiveEdgeButton(controller: controller),
        if (!compact) RefreshButton(controller: controller),
        if (!compact) FavoriteButton(controller: controller),
        if (enableDanmakuDisplay) ...[DanmakuButton(controller: controller), SettingsButton(controller: controller)],
      ],
    );
  }

  Widget _buildRightActions({
    required bool compact,
    required bool showStreamSelector,
    required bool isFullscreen,
    required bool isWindowFullscreen,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 清晰度/线路合并胶囊：全屏或沉浸模式（非紧凑布局）显示。
        if (!compact && showStreamSelector) ...[FullscreenStreamSelectorButton(controller: controller)],
        VideoFitSetting(controller: controller),
        if (Platform.isWindows) OverlayVolumeControl(controller: controller),
        if (Platform.isWindows && controller.supportWindowFull && !isFullscreen)
          ExpandWindowButton(controller: controller),
        if (!isWindowFullscreen) ExpandButton(controller: controller),
      ],
    );
  }
}

/// Room-local composer placed between the two fullscreen control groups.
/// Pure Live does not impersonate a platform account here: the submitted line
/// enters the local list and video barrage through the same ordered delivery
/// queue used by portrait mode.
class FullscreenLocalDanmakuComposer extends StatefulWidget {
  const FullscreenLocalDanmakuComposer({super.key, required this.controller});

  final VideoController controller;

  @override
  State<FullscreenLocalDanmakuComposer> createState() => _FullscreenLocalDanmakuComposerState();
}

/// The fullscreen composer is a presentation of the room-local interaction
/// feature, not an entry point that silently changes the user's global setting.
/// Keeping this decision pure also prevents portrait and landscape fullscreen
/// layouts from drifting apart when the setting is disabled.
bool shouldShowFullscreenLocalDanmakuComposer(bool localInteractionEnabled) => localInteractionEnabled;

class _FullscreenLocalDanmakuComposerState extends State<FullscreenLocalDanmakuComposer> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _pinsControllerBar = false;

  VideoController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      _pinsControllerBar = true;
      // `showController` is allowed to time out while the IME is animating.
      // Keep the bar mounted through `isMenuOpen` as well, otherwise the
      // TextField is disposed together with the typed draft before Send can be
      // pressed on slower Android keyboards.
      controller.isMenuOpen.value = true;
      controller.stopHideController();
      return;
    }
    if (_pinsControllerBar) {
      _pinsControllerBar = false;
      controller.isMenuOpen.value = false;
    }
    controller.enableController();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    if (_pinsControllerBar && controller.status != PlayerStatus.disposed) {
      _pinsControllerBar = false;
      controller.isMenuOpen.value = false;
      controller.enableController();
    }
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textController.text.trim();
    final live = controller.livePlayController;
    final local = live.localInteractionController;
    if (!local.enabled.v || text.isEmpty) return;
    live.emitLocalMessage(
      local.createChat(text, platform: live.site),
      showAsDanmaku: local.showAsDanmaku.v,
      delay: LivePlayController.localChatDeliveryDelay,
    );
    _textController.clear();
    ToastUtil.show(i18n('local_message_queued'));
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final local = controller.livePlayController.localInteractionController;
      if (!shouldShowFullscreenLocalDanmakuComposer(local.enabled.v)) return const SizedBox.shrink();

      final localStyle = local.currentDanmakuStyle;
      return SizedBox(
        key: const ValueKey('fullscreen-local-danmaku-composer'),
        height: 38,
        child: TextField(
          controller: _textController,
          focusNode: _focusNode,
          style: TextStyle(
            color: Color(local.danmakuColor.v).withValues(alpha: localStyle.opacity),
            fontSize: 13,
            fontWeight: FontWeight(localStyle.fontWeight),
            fontFamily: localStyle.fontFamily,
            fontStyle: localStyle.italic ? FontStyle.italic : FontStyle.normal,
            letterSpacing: localStyle.letterSpacing,
            shadows: localStyle.showShadow
                ? [
                    Shadow(
                      color: Color(localStyle.shadowColor).withValues(alpha: localStyle.opacity),
                      blurRadius: localStyle.shadowBlur,
                      offset: Offset(localStyle.shadowOffset, localStyle.shadowOffset),
                    ),
                  ]
                : null,
          ),
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.black54,
            hintText: i18n('local_message_hint'),
            hintStyle: const TextStyle(color: Colors.white60, fontSize: 13),
            prefixIcon: IconButton(
              key: const ValueKey('fullscreen-local-interaction'),
              tooltip: i18n('local_interaction_title'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              onPressed: () {
                final live = controller.livePlayController;
                controller.isMenuOpen.value = true;
                controller.stopHideController();
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (sheetContext) {
                    final detail = live.state.value.room.detail;
                    return LocalInteractionSheet(
                      controller: live.localInteractionController,
                      platform: detail?.platform ?? live.site,
                      onMessage: (message, showAsDanmaku) {
                        live.emitLocalMessage(message, showAsDanmaku: showAsDanmaku);
                      },
                    );
                  },
                ).whenComplete(() {
                  if (controller.status != PlayerStatus.disposed) {
                    controller.isMenuOpen.value = false;
                    controller.enableController();
                  }
                });
              },
              icon: Icon(Icons.auto_awesome_rounded, color: Color(local.danmakuColor.v), size: 18),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: IconButton(
              key: const ValueKey('fullscreen-local-danmaku-send'),
              tooltip: i18n('local_send_message'),
              visualDensity: VisualDensity.compact,
              onPressed: _send,
              icon: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.3),
            ),
          ),
        ),
      );
    });
  }
}

class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    final playerManager = GlobalPlayerService.instance.player;

    return GestureDetector(
      onTap: () => playerManager.togglePlayPause(),
      child: StreamBuilder<bool>(
        stream: playerManager.onPlaying.distinct(),
        initialData: playerManager.isPlayingNow,
        builder: (context, snapshot) {
          final isPlaying = snapshot.data ?? playerManager.isPlayingNow;
          return Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(right: 6),
            child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
          );
        },
      ),
    );
  }
}

class RefreshButton extends StatelessWidget {
  const RefreshButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => controller.refresh(),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.only(right: 6),
        child: const Icon(Icons.autorenew_rounded, color: Colors.white),
      ),
    );
  }
}

/// Jumps the playhead back to the live edge. Only shown for live streams
/// that expose a seekable cache window (`player.canSeek`). Bound to the E
/// key in [VideoKeyboardShortcuts].
class LiveEdgeButton extends StatelessWidget {
  const LiveEdgeButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    final player = GlobalPlayerService.instance.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, _) {
        if (!player.canSeek) return const SizedBox.shrink();
        return Tooltip(
          message: i18n('live_edge_back_to_live'),
          child: GestureDetector(
            onTap: () {
              controller.enableController();
              player.seekToLiveEdge();
              if (!player.isPlayingNow) player.resume();
            },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.only(right: 6, left: 6),
              child: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ),
        );
      },
    );
  }
}

class DanmakuButton extends StatelessWidget {
  const DanmakuButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => controller.hideDanmaku.toggle(),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.only(right: 6, left: 6),
        child: Obx(
          () => controller.hideDanmaku.value
              ? SvgPicture.asset(
                  'assets/images/video/danmu_close.svg',
                  // ignore: deprecated_member_use
                  color: Colors.white,
                )
              : SvgPicture.asset(
                  'assets/images/video/danmu_open.svg',
                  // ignore: deprecated_member_use
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}

class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        if (controller.isMenuOpen.value) return;
        controller.isMenuOpen.value = true;
        try {
          await Get.dialog<void>(
            SettingsPanel(controller: controller),
            barrierColor: Colors.black.withValues(alpha: 0.58),
            useSafeArea: true,
          );
        } finally {
          controller.isMenuOpen.value = false;
          controller.enableController();
        }
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.only(right: 6, left: 6),
        child: SvgPicture.asset(
          'assets/images/video/danmu_setting.svg',
          // ignore: deprecated_member_use
          color: Colors.white,
        ),
      ),
    );
  }
}

class ExpandWindowButton extends StatelessWidget {
  const ExpandWindowButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final expanded = GlobalPlayerState.to.isWindowFullscreen.value;
      return Semantics(
        button: true,
        label: i18n(playerWindowActionLabelKey(expanded)),
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: () => controller.toggleWindowFullScreen(),
          child: Container(
            alignment: Alignment.center,
            child: RotatedBox(
              quarterTurns: 1,
              child: Icon(
                expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class ExpandButton extends StatelessWidget {
  const ExpandButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final expanded = GlobalPlayerState.to.isFullscreen.value;
      return Semantics(
        button: true,
        label: i18n(fullscreenActionLabelKey(expanded)),
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: () => controller.toggleFullScreen(),
          child: Container(
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                expanded ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class AlwaysOnTopButton extends StatelessWidget {
  const AlwaysOnTopButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final onTop = controller.isWindowAlwaysOnTop.value;
      return IconButton(
        tooltip: i18n(onTop ? 'playback_window_cancel_always_on_top' : 'playback_window_always_on_top'),
        visualDensity: VisualDensity.compact,
        iconSize: 21,
        color: onTop ? const Color(0xFFFFD166) : Colors.white,
        onPressed: () {
          controller.enableController();
          unawaited(controller.toggleWindowAlwaysOnTop());
        },
        icon: Icon(onTop ? Remix.pushpin_fill : Remix.pushpin_line),
      );
    });
  }
}

class AudioOnlyButton extends StatelessWidget {
  const AudioOnlyButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    // Child builds run outside the parent's Obx dependency collector. Keep
    // mode and in-flight state subscribed here, including failure completion.
    return Obx(() {
      final switching = controller.audioModeSwitching.value;
      final audioOnly = controller.isAudioOnly;
      return IconButton(
        tooltip: i18n(audioOnly ? 'restore_video_mode' : 'switch_audio_only_mode'),
        visualDensity: VisualDensity.compact,
        iconSize: 21,
        color: audioOnly ? const Color(0xFFFFD166) : Colors.white,
        onPressed: switching
            ? null
            : () {
                controller.enableController();
                controller.toggleAudioOnly();
              },
        // The headphone always means room-scoped audio-only. A television icon
        // is reserved exclusively for casting so the two actions stay distinct.
        icon: Icon(audioOnly ? Remix.headphone_fill : Remix.headphone_line),
      );
    });
  }
}

class CastButton extends StatelessWidget {
  const CastButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: i18n('cast_screen'),
      visualDensity: VisualDensity.compact,
      iconSize: 21,
      color: Colors.white,
      onPressed: () {
        controller.enableController();
        LiveUrlTool.castPlayUrlByRoomId(
          context: context,
          roomId: controller.room.roomId ?? '',
          platform: controller.room.platform ?? '',
          isCurrentRoom: () => controller.status != PlayerStatus.disposed,
        );
      },
      icon: const Icon(Remix.tv_2_line),
    );
  }
}

class FavoriteButton extends StatelessWidget {
  const FavoriteButton({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final room = controller.room;
      final favoriteRooms = SettingsService.to.fav.favoriteRooms.value;
      final isFavorite = favoriteRooms.any((candidate) => candidate.hasSameIdentity(room));
      return GestureDetector(
        onTap: () {
          controller.enableController();
          final changed = isFavorite ? SettingsService.to.fav.removeRoom(room) : SettingsService.to.fav.addRoom(room);
          if (changed) EventBus.instance.emit('changeFavorite', true);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 2),
          alignment: Alignment.center,
          height: 25,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(isFavorite ? Icons.check_rounded : Icons.close, color: Colors.white, size: 15),
              Text(isFavorite ? i18n('followed') : i18n('follow'), style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    });
  }
}

// Settings panel widgets

class VideoFitSetting extends StatefulWidget {
  const VideoFitSetting({super.key, required this.controller});
  final VideoController controller;
  @override
  State<VideoFitSetting> createState() => _VideoFitSettingState();
}

/// 视频比例：对齐音量控件的悬浮交互——鼠标移入即在按钮上方弹出
/// 比例选项面板，点击选项生效，移出后延迟收起；不再点击循环切换。
class _VideoFitSettingState extends State<VideoFitSetting> {
  /// 宽度上下限：由最长选项文本测量得出，极端长文本在上限处省略。
  static const double _minPanelWidth = 110.0;
  static const double _maxPanelWidth = 200.0;
  static const double _itemHeight = 32.0;

  VideoController get controller => widget.controller;

  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInButton = false;
  bool _isMouseInPanel = false;
  Timer? _hideTimer;

  /// 面板展示期间绑定的控制器，移除面板时向其归还 isMenuOpen 状态。
  VideoController? _panelOwner;

  @override
  void didUpdateWidget(covariant VideoFitSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, controller)) return;
    _hideTimer?.cancel();
    _removeOverlay(owner: oldWidget.controller);
    _isMouseInButton = false;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showPanel() {
    if (_overlayEntry != null || !mounted) return;
    final owner = controller;
    _panelOwner = owner;
    owner.isMenuOpen.value = true;
    owner.stopHideController();

    final options = AppConsts().videoFitType;
    // 高度 = 选项数 × 行高 + 底部间隙 padding 6；宽度按最长选项标签测量。
    final panelHeight = options.length * _itemHeight + 6;
    final panelWidth = _computePanelWidth(context);

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: panelWidth,
        height: panelHeight,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, 6),
          child: MouseRegion(
            onEnter: (_) {
              _isMouseInPanel = true;
              owner.stopHideController();
            },
            onExit: (_) {
              _isMouseInPanel = false;
              owner.enableController();
              _startHideTimer();
            },
            child: _buildPanel(context),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_isMouseInButton && !_isMouseInPanel) {
        _removeOverlay();
      }
    });
  }

  void _removeOverlay({VideoController? owner}) {
    _hideTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    _isMouseInPanel = false;
    final target = owner ?? _panelOwner ?? controller;
    if (target.status != PlayerStatus.disposed) {
      target.isMenuOpen.value = false;
      target.enableController();
    }
    _panelOwner = null;
  }

  /// 按最长选项文本测量面板宽度：标签 + 横向内边距 24 + 勾选图标 16 + 间隙 4。
  double _computePanelWidth(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    var maxLabelWidth = 0.0;
    for (final option in AppConsts().videoFitType) {
      maxLabelWidth = math.max(
        maxLabelWidth,
        _measureTextWidth(
          context,
          i18n(option['desc'] as String),
          textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    }
    return (maxLabelWidth + 44).clamp(_minPanelWidth, _maxPanelWidth).toDouble();
  }

  Widget _buildPanel(BuildContext context) {
    final player = SettingsService.to.player;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colorScheme.surface,
        elevation: 8,
        shadowColor: Colors.black45,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Obx(() {
          final options = AppConsts().videoFitType;
          final current = player.resolvedVideoFitIndex;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < options.length; i++)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: i == current
                      ? null
                      : () {
                          player.videoFitIndex.v = i;
                          controller.setVideoFit(i);
                        },
                  child: SizedBox(
                    height: _itemHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              i18n(options[i]['desc'] as String),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: i == current ? FontWeight.w700 : FontWeight.w500,
                                color: i == current ? colorScheme.primary : colorScheme.onSurface,
                              ),
                            ),
                          ),
                          if (i == current) Icon(Icons.check_rounded, size: 16, color: colorScheme.primary),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = SettingsService.to.player;

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          _isMouseInButton = true;
          _showPanel();
        },
        onExit: (_) {
          _isMouseInButton = false;
          _startHideTimer();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 2),
          alignment: Alignment.center,
          height: 25,
          child: Obx(() {
            final descriptionKey = player.resolvedVideoFitDescriptionKey;
            return Text(
              descriptionKey.isEmpty ? '' : i18n(descriptionKey),
              style: AppTextStyles.t15.copyWith(color: Colors.white),
            );
          }),
        ),
      ),
    );
  }
}

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.controller});

  final DanmakuSettingsBinding controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final compactLandscape = isLandscape && size.height < 620;
    final targetWidth = isLandscape
        ? (size.width * (compactLandscape ? 0.44 : 0.38)).clamp(340.0, compactLandscape ? 460.0 : 540.0).toDouble()
        : (size.width * 0.92).clamp(300.0, 560.0).toDouble();
    final targetHeight = isLandscape ? size.height - (compactLandscape ? 12 : 24) : size.height * 0.84;
    final panelColor = colorScheme.surface;

    return Dialog(
      alignment: isLandscape ? Alignment.centerRight : Alignment.center,
      backgroundColor: Colors.transparent,
      shadowColor: theme.shadowColor.withValues(alpha: 0.45),
      elevation: 24,
      insetPadding: EdgeInsets.symmetric(horizontal: isLandscape ? 6 : 12, vertical: isLandscape ? 6 : 12),
      child: Container(
        key: const ValueKey('fullscreen-danmaku-settings-panel'),
        width: targetWidth,
        height: targetHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: isLandscape
              ? const BorderRadius.horizontal(left: Radius.circular(18), right: Radius.circular(8))
              : BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.7), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, compactLandscape ? 6 : 10, 6, compactLandscape ? 6 : 10),
              child: Row(
                children: [
                  Container(
                    width: 3.5,
                    height: 18,
                    decoration: BoxDecoration(color: colorScheme.primary, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          i18n('settings_danmaku_title'),
                          style: AppTextStyles.t16Bold.copyWith(color: colorScheme.onSurface),
                        ),
                        Text(
                          i18n('danmaku_realtime_hint'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.t12.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('fullscreen-danmaku-settings-close'),
                    tooltip: i18n('close'),
                    color: colorScheme.onSurfaceVariant,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.7), height: 1, thickness: 0.8),
            Expanded(
              // PiP has a dedicated settings/preview page. Keeping those
              // controls out of the short landscape sheet leaves the live
              // picture visible and avoids a confusing nested long form.
              child: DanmakuSettingsContent(controller: controller, embedded: true, includePipSettings: false),
            ),
          ],
        ),
      ),
    );
  }
}
