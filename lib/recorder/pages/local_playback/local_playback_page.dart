import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:media_kit_video/media_kit_video.dart' as mk_video;
import 'package:path/path.dart' as p;
import 'package:pure_live/common/consts/app_consts.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:pure_live/recorder/pages/local_playback/local_playback_controller.dart';
import 'package:pure_live/recorder/models/recording_group.dart';
import 'package:pure_live/recorder/widgets/danmaku/local_playback_danmaku_overlay.dart';
import 'package:pure_live/modules/live_play/pages/danmaku_settings_page.dart';
import 'package:pure_live/modules/live_play/widgets/layout/control_hover_region.dart';
import 'package:pure_live/modules/live_play/widgets/layout/bottom_control_surface.dart';
import 'package:pure_live/recorder/widgets/danmaku/local_playback_danmaku_binding.dart';
import 'package:remixicon/remixicon.dart';

class LocalPlaybackPage extends GetView<LocalPlaybackController> {
  const LocalPlaybackPage({super.key});

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ShortcutFocusGuard(
      child: Obx(() {
        final isPip = controller.isPipMode.value;
        if (isPip) {
          return _buildPipOverlay(context);
        }
        final immersive = controller.isWindowFullscreen.value || controller.isFullscreen.value;
        final wallpaperActive = SettingsService.hasWallpaper;
        return Scaffold(
          backgroundColor: wallpaperActive ? Colors.transparent : null,
          body: Column(
            children: [
              if (!immersive) _buildAppBar(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildVideoArea()),
                    if (!immersive) _buildPlaylistPanel(context),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildPipOverlay(BuildContext context) {
    return _LocalPlayerInteractions(
      controller: controller,
      child: Theme(
        data: Theme.of(context).copyWith(brightness: Brightness.dark),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: MouseRegion(
            onEnter: (_) => controller.isPipHovered.value = true,
            onExit: (_) => controller.isPipHovered.value = false,
            child: _wrapPipWheel(
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(color: Colors.black),
                child: Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => windowManager.startDragging(),
                      onDoubleTap: () => controller.exitPiP(),
                      child: Obx(() {
                        final audioOnly = controller.isAudioOnly.value;
                        if (audioOnly) {
                          return Container(
                            color: Colors.black,
                            child: const Center(child: Icon(Remix.headphone_fill, color: Colors.white38, size: 48)),
                          );
                        }
                        return Container(
                          color: Colors.black,
                          child: mk_video.Video(
                            controller: controller.videoController,
                            fit: BoxFit.cover,
                            fill: Colors.black,
                            controls: null,
                          ),
                        );
                      }),
                    ),
                    Obx(
                      () => LocalPlaybackDanmakuOverlay(
                        barrageController: controller.barrageController,
                        enabled: controller.danmakuEnabled.value,
                      ),
                    ),
                    Positioned(left: 0, right: 0, bottom: 0, child: _buildPipProgressBar()),
                    _buildPipPlaybackControls(),
                    Positioned(bottom: 40, child: _buildPipSpeedHud()),
                    _buildPipChrome(),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Obx(
                        () => AnimatedOpacity(
                          opacity: controller.isPipHovered.value ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(
                            ignoring: !controller.isPipHovered.value,
                            child: IconButton(
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.all(8),
                              style: IconButton.styleFrom(backgroundColor: Colors.black45),
                              tooltip: controller.isPipAlwaysOnTop.value ? '取消置顶' : '置顶小窗',
                              icon: Icon(
                                controller.isPipAlwaysOnTop.value ? Icons.push_pin : Icons.push_pin_outlined,
                                color: Colors.white,
                              ),
                              onPressed: controller.togglePipAlwaysOnTop,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Obx(
                        () => AnimatedOpacity(
                          opacity: controller.isPipHovered.value ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(
                            ignoring: !controller.isPipHovered.value,
                            child: IconButton(
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.all(8),
                              style: IconButton.styleFrom(backgroundColor: Colors.black45),
                              tooltip: '退出小窗',
                              icon: const Icon(Icons.close, color: Colors.white),
                              onPressed: controller.exitPiP,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapPipWheel(Widget child) {
    return Builder(
      builder: (context) => Listener(
        onPointerSignal: _handlePipWheel,
        onPointerUp: (event) {
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.attached || box.size.isEmpty) return;
          final local = box.globalToLocal(event.position);
          final inside = local.dx >= 0 && local.dy >= 0 && local.dx <= box.size.width && local.dy <= box.size.height;
          if (!inside) controller.isPipHovered.value = false;
        },
        onPointerCancel: (event) {
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.attached || box.size.isEmpty) return;
          final local = box.globalToLocal(event.position);
          final inside = local.dx >= 0 && local.dy >= 0 && local.dx <= box.size.width && local.dy <= box.size.height;
          if (!inside) controller.isPipHovered.value = false;
        },
        child: child,
      ),
    );
  }

  void _handlePipWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    if (HardwareKeyboard.instance.isControlPressed) {
      final step = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
      final next = (controller.playbackSpeed.value + step).clamp(0.5, 3.0);
      controller.setSpeed((next * 10).round() / 10);
      return;
    }
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    final next = (controller.volume.value + delta).clamp(0.0, 1.0);
    controller.setVolume(next);
  }

  Widget _buildPipPlaybackControls() {
    Widget pauseButton() {
      return Obx(() {
        final isPlay = controller.isPlaying.value;
        return IconButton(
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
          style: IconButton.styleFrom(backgroundColor: Colors.black45),
          icon: Icon(isPlay ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white),
          onPressed: controller.togglePlayPause,
        );
      });
    }

    return Center(
      child: Obx(() {
        final hovered = controller.isPipHovered.value;
        final volume = controller.volume.value;
        final muted = volume <= 0.001;
        final icon = muted ? Icons.volume_off : (volume < 0.5 ? Icons.volume_down : Icons.volume_up);
        return AnimatedOpacity(
          opacity: hovered ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !hovered,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pauseButton(),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  onDoubleTap: () {},
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.only(left: 2, right: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(7),
                          iconSize: 22,
                          tooltip: muted ? '取消静音' : '静音',
                          icon: Icon(icon, color: Colors.white),
                          onPressed: controller.toggleMute,
                        ),
                        _buildPipVolumeTrack(),
                        const SizedBox(width: 8),
                        Text(
                          '${(volume * 100).round()}%',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _buildPipVolumeTrack() {
    const trackWidth = 84.0;
    void updateFromPosition(double dx) {
      final ratio = (dx / trackWidth).clamp(0.0, 1.0).toDouble();
      controller.setVolume(ratio);
    }

    return Obx(() {
      final clamped = controller.volume.value.clamp(0.0, 1.0).toDouble();
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _handlePipWheel,
          onPointerDown: (event) => updateFromPosition(event.localPosition.dx),
          onPointerMove: (event) {
            if (event.buttons != 0) updateFromPosition(event.localPosition.dx);
          },
          child: SizedBox(
            width: trackWidth,
            height: 20,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: clamped,
                    minHeight: 5,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                Positioned(
                  left: (clamped * trackWidth - 6).clamp(0.0, trackWidth - 12),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2)],
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

  Widget _buildPipChrome() {
    return Positioned(
      left: 8,
      right: 8,
      top: 8,
      child: Obx(
        () => AnimatedOpacity(
          opacity: controller.isPipHovered.value ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            child: Row(
              children: [
                const SizedBox(width: 44),
                Expanded(
                  child: Align(alignment: Alignment.topCenter, child: _buildPipFileLabel()),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPipFileLabel() {
    final entry = controller.currentEntry;
    if (entry == null) return const SizedBox.shrink();
    final name = p.basenameWithoutExtension(entry.path);
    if (name.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPipProgressBar() {
    return Builder(
      builder: (context) {
        void seekFromPosition(double dx, double width) {
          final ratio = (dx / width).clamp(0.0, 1.0).toDouble();
          final dur = controller.totalDuration.value;
          if (dur > Duration.zero) {
            controller.seekTo(dur * ratio);
          }
        }

        return Obx(() {
          final dur = controller.totalDuration.value;
          final pos = controller.currentPosition.value;
          final ratio = dur > Duration.zero ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
          final hovered = controller.isPipHovered.value;

          return AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !hovered,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: _handlePipWheel,
                onPointerDown: (event) {
                  final box = context.findRenderObject();
                  if (box is RenderBox) seekFromPosition(event.localPosition.dx, box.size.width);
                },
                onPointerMove: (event) {
                  if (event.buttons != 0) {
                    final box = context.findRenderObject();
                    if (box is RenderBox) seekFromPosition(event.localPosition.dx, box.size.width);
                  }
                },
                child: Container(
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  color: Colors.black26,
                  child: Center(
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(height: 3, color: Colors.white24),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(height: 3, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  Widget _buildPipSpeedHud() {
    return Obx(() {
      final visible = controller.isSpeedHudVisible.value;
      final speed = controller.playbackSpeed.value;
      return Align(
        alignment: Alignment.center,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: !visible,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Text(
                '${speed.toStringAsFixed(1)}x',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildAppBar() {
    final theme = Get.theme;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(onPressed: () => Get.back(), icon: const Icon(Icons.arrow_back_rounded)),
          const SizedBox(width: 4),
          Obx(() {
            final g = controller.group.value;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(6)),
                  child: Text(
                    g.platform.toUpperCase(),
                    style: AppTextStyles.t11.copyWith(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                CommonAvatar(avatarUrl: g.avatar, radius: 14, fallbackName: g.displayNick),
                const SizedBox(width: 8),
                Text(g.displayNick, style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w600)),
              ],
            );
          }),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    final immersive = controller.isWindowFullscreen.value || controller.isFullscreen.value;
    final videoBgColor = SettingsService.hasWallpaper ? Colors.transparent : Colors.black;
    return Container(
      color: immersive ? videoBgColor : Colors.transparent,
      child: Obx(() {
        // 监听视频尺寸变化以便切换视频时重建。不再用 AspectRatio 约束播放区域：
        // 纹理已按内容精确渲染，透明填充让壁纸透出，顶栏/底栏控件也能获得完整宽度。
        controller.videoWidth.value;
        controller.videoHeight.value;
        final videoInner = _LocalPlayerInteractions(
          controller: controller,
          child: MouseRegion(
            onHover: (_) => controller.enableController(),
            onExit: (_) => controller.enableController(),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent) return;
                if (HardwareKeyboard.instance.isControlPressed) {
                  final step = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
                  final next = (controller.playbackSpeed.value + step).clamp(0.5, 3.0);
                  controller.setSpeed((next * 10).round() / 10);
                  controller.enableController();
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Obx(() {
                    final audioOnly = controller.isAudioOnly.value;
                    if (audioOnly) {
                      return Container(
                        color: Colors.black,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Remix.headphone_fill, color: Colors.white38, size: 72),
                              const SizedBox(height: 16),
                              Text('纯音频模式', style: AppTextStyles.t14.copyWith(color: Colors.white38)),
                            ],
                          ),
                        ),
                      );
                    }
                    final hasVideo = controller.currentMp4Path != null;
                    if (!hasVideo) {
                      return Center(
                        child: Text('加载中…', style: AppTextStyles.t14.copyWith(color: Colors.white54)),
                      );
                    }
                    final fitIndex = SettingsService.to.player.videoFitIndex.v;
                    final fitList = SettingsService.to.player.videoFitArray;
                    final fit = (fitIndex >= 0 && fitIndex < fitList.length) ? fitList[fitIndex] : BoxFit.contain;
                    return Container(
                      color: videoBgColor,
                      child: mk_video.Video(
                        controller: controller.videoController,
                        fit: fit,
                        fill: videoBgColor,
                        controls: null,
                      ),
                    );
                  }),
                  Obx(
                    () => LocalPlaybackDanmakuOverlay(
                      barrageController: controller.barrageController,
                      enabled: controller.danmakuEnabled.value,
                    ),
                  ),
                  GestureDetector(
                    onTapDown: (_) => controller.enableController(),
                    onDoubleTap: () {
                      if (HardwareKeyboard.instance.isControlPressed) return;
                      if (controller.isWindowFullscreen.value) {
                        controller.toggleWindowFullScreen();
                      } else {
                        controller.toggleFullScreen();
                      }
                    },
                    child: _VolumeDragArea(controller: controller),
                  ),
                  _SpeedHudOverlay(controller: controller),
                  _buildLeftScreenshotButton(),
                  _buildTopOverlayBar(),
                  _buildBottomBar(),
                ],
              ),
            ),
          ),
        );
        return SizedBox.expand(child: videoInner);
      }),
    );
  }

  Widget _buildTitleChip() {
    return Obx(() {
      final total = controller.group.value.mp4s.length;
      final index = controller.currentIndex.value + 1;
      final entry = controller.currentEntry;
      final name = entry != null ? p.basenameWithoutExtension(entry.path) : '';
      final text = total > 0 ? '$index / $total  $name' : name;
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      );
    });
  }

  Widget _buildLeftScreenshotButton() {
    return Positioned(
      left: 20,
      top: 0,
      bottom: 0,
      child: Center(
        child: Obx(() {
          final visible = controller.showController.value;
          return AnimatedOpacity(
            opacity: visible ? 0.9 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: AbsorbPointer(
              absorbing: !visible,
              child: MouseRegion(
                onEnter: (_) => controller.holdController(),
                onExit: (_) => controller.releaseController(),
                child: IconButton(
                  tooltip: '截图',
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
        }),
      ),
    );
  }

  Widget _buildTopOverlayBar() {
    return Obx(() {
      final visible = controller.showController.value && !controller.showLocked.value;
      final immersive = controller.isWindowFullscreen.value || controller.isFullscreen.value;
      return AnimatedPositioned(
        top: visible ? 0 : -56,
        left: 0,
        right: 0,
        height: 56,
        duration: const Duration(milliseconds: 300),
        child: ControlHoverRegion(
          enabled: visible,
          onEnter: controller.onMouseEnterController,
          onExit: controller.onMouseExitController,
          child: Container(
            height: 56,
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
                if (immersive)
                  IconButton(
                    onPressed: controller.isFullscreen.value
                        ? controller.toggleFullScreen
                        : controller.toggleWindowFullScreen,
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    tooltip: '返回',
                  ),
                _buildTitleChip(),
                const Spacer(),
                _TopRightActions(controller: controller),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildBottomBar() {
    return Obx(() {
      final visible = (controller.showController.value || controller.isMenuOpen.value) && !controller.showLocked.value;
      return BottomControlSurface(
        visible: visible,
        height: 56 + 28,
        child: ControlHoverRegion(
          enabled: visible,
          onEnter: controller.onMouseEnterController,
          onExit: controller.onMouseExitController,
          child: Container(
            height: 56 + 28,
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
                _ProgressBar(controller: controller, formatDuration: _formatDuration),
                SizedBox(
                  height: 56,
                  child: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        _LeftActions(controller: controller),
                        const Spacer(),
                        _RightActions(controller: controller),
                      ],
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

  Widget _buildPlaylistPanel(BuildContext context) {
    final theme = Get.theme;
    final wallpaperActive = SettingsService.hasWallpaper;
    final surface = theme.colorScheme.surface;
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: wallpaperActive ? surface.withValues(alpha: 0.6) : surface,
        border: Border(left: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.08))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text('播放列表', style: AppTextStyles.t13.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: controller.openCurrentDirectory,
                  icon: const Icon(Remix.folder_open_line, size: 18),
                  tooltip: '打开所在目录',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(28, 28),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          Obx(() {
            final mp4s = controller.group.value.mp4s;
            return Expanded(
              child: ScrollConfiguration(
                behavior: const MouseDraggableScrollBehavior(),
                child: buildCommonPullToRefresh(
                  context: context,
                  refreshKey: 'local_playback_playlist',
                  onRefresh: controller.refreshPlaylist,
                  controller: controller.playlistRefreshController,
                  childBuilder: (_, physics) {
                    return ListView.separated(
                      physics: physics,
                      itemCount: mp4s.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final entry = mp4s[index];
                        final hasXml = File(p.setExtension(entry.path, '.xml')).existsSync();
                        return Obx(
                          () => _PlaylistItem(
                            entry: entry,
                            isCurrent: index == controller.currentIndex.value,
                            hasDanmaku: hasXml,
                            onTap: () => controller.playAt(index),
                            onDelete: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                useRootNavigator: false,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('删除视频'),
                                  content: Text('确定要删除「${p.basename(entry.path)}」吗？此操作不可恢复。'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(i18n('cancel'))),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: Text(i18n('confirm')),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) await controller.deleteEntryAt(index);
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _TopRightActions extends StatelessWidget {
  final LocalPlaybackController controller;
  const _TopRightActions({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '键盘快捷键',
          visualDensity: VisualDensity.compact,
          iconSize: 21,
          color: Colors.white,
          onPressed: () {
            controller.enableController();
            showKeyboardShortcutsDialog(context);
          },
          icon: const Icon(Icons.keyboard_rounded),
        ),
        Obx(() {
          final onTop = controller.isAlwaysOnTop.value;
          return IconButton(
            tooltip: onTop ? '取消窗口置顶' : '窗口置顶',
            visualDensity: VisualDensity.compact,
            iconSize: 21,
            color: onTop ? const Color(0xFFFFD166) : Colors.white,
            onPressed: () {
              controller.enableController();
              controller.toggleAlwaysOnTop();
            },
            icon: Icon(onTop ? Remix.pushpin_fill : Remix.pushpin_line),
          );
        }),
        Obx(() {
          final audioOnly = controller.isAudioOnly.value;
          return IconButton(
            tooltip: audioOnly ? '恢复视频模式' : '纯音频模式',
            visualDensity: VisualDensity.compact,
            iconSize: 21,
            color: audioOnly ? const Color(0xFFFFD166) : Colors.white,
            onPressed: () {
              controller.enableController();
              controller.toggleAudioOnly();
            },
            icon: Icon(audioOnly ? Remix.headphone_fill : Remix.headphone_line),
          );
        }),
        Obx(() {
          final disabled = controller.isPipMode.value;
          return IconButton(
            tooltip: disabled ? '小窗已激活' : '小窗播放',
            color: Colors.white,
            onPressed: disabled
                ? null
                : () {
                    controller.enableController();
                    controller.togglePiP();
                  },
            icon: const Icon(CustomIcons.float_window),
          );
        }),
      ],
    );
  }
}

class _ProgressBar extends StatefulWidget {
  final LocalPlaybackController controller;
  final String Function(Duration) formatDuration;
  const _ProgressBar({required this.controller, required this.formatDuration});

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  static const double _barHeight = 3.5;
  static const double _hitAreaHeight = 22.0;
  bool _isDragging = false;
  double _dragFrac = 0;

  double get _currentFrac {
    final pos = widget.controller.currentPosition.value.inMilliseconds.toDouble();
    final dur = widget.controller.totalDuration.value.inMilliseconds.toDouble();
    if (dur <= 0) return 0;
    return (pos / dur).clamp(0.0, 1.0);
  }

  void _seekFromFrac(double frac) {
    final dur = widget.controller.totalDuration.value;
    widget.controller.seekTo(Duration(milliseconds: (frac.clamp(0.0, 1.0) * dur.inMilliseconds).round()));
  }

  double _fracFromPosition(Offset localPosition, double width) {
    if (width <= 0) return 0;
    return (localPosition.dx / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 16, bottom: 2),
      child: SizedBox(
        height: _hitAreaHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Obx(() {
                final frac = _isDragging ? _dragFrac : _currentFrac;
                final dur = controller.totalDuration.value;
                final display = _isDragging
                    ? Duration(milliseconds: (frac * dur.inMilliseconds).round())
                    : controller.currentPosition.value;
                return Text(
                  widget.formatDuration(display),
                  style: const TextStyle(
                    color: Color(0xFFF4F4F4),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                    decoration: TextDecoration.none,
                    height: 1.0,
                  ),
                );
              }),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      final frac = _fracFromPosition(details.localPosition, width);
                      _seekFromFrac(frac);
                      controller.enableController();
                    },
                    onHorizontalDragStart: (details) {
                      setState(() {
                        _isDragging = true;
                        _dragFrac = _fracFromPosition(details.localPosition, width);
                      });
                      controller.holdController();
                    },
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _dragFrac = _fracFromPosition(details.localPosition + Offset(details.delta.dx, 0), width);
                      });
                    },
                    onHorizontalDragEnd: (details) {
                      _seekFromFrac(_dragFrac);
                      setState(() {
                        _isDragging = false;
                      });
                      controller.releaseController();
                    },
                    child: Center(
                      child: SizedBox(
                        height: _barHeight + (_isDragging ? 3 : 0),
                        child: Obx(() {
                          final frac = _isDragging ? _dragFrac : _currentFrac;
                          return CustomPaint(
                            painter: _ProgressPainter(currentFrac: frac, isDragging: _isDragging),
                            size: Size.infinite,
                          );
                        }),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Obx(
                () => Text(
                  widget.formatDuration(controller.totalDuration.value),
                  style: const TextStyle(
                    color: Color(0xFFF4F4F4),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                    decoration: TextDecoration.none,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double currentFrac;
  final bool isDragging;

  _ProgressPainter({required this.currentFrac, required this.isDragging});

  static final Color _trackColor = Colors.white.withValues(alpha: 0.18);
  static final Color _playedColor = Colors.white.withValues(alpha: 0.92);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final y = h / 2;
    final frac = currentFrac.clamp(0.0, 1.0);
    final stroke = h;

    final trackPaint = Paint()
      ..color = _trackColor
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final playedPaint = Paint()
      ..color = _playedColor
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(0, y), Offset(w, y), trackPaint);
    if (frac > 0) {
      canvas.drawLine(Offset(0, y), Offset(frac * w, y), playedPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter oldDelegate) {
    return currentFrac != oldDelegate.currentFrac || isDragging != oldDelegate.isDragging;
  }
}

class _LeftActions extends StatelessWidget {
  final LocalPlaybackController controller;
  const _LeftActions({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(
          tooltip: '播放/暂停',
          onTap: controller.togglePlayPause,
          icon: Obx(
            () => Icon(
              controller.isPlaying.value ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
        _IconAction(
          tooltip: '后退 10 秒',
          onTap: () => controller.seekRelative(const Duration(seconds: -10)),
          icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
        ),
        _IconAction(
          tooltip: '前进 10 秒',
          onTap: () => controller.seekRelative(const Duration(seconds: 10)),
          icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
        ),
        Obx(() {
          final canPrev = controller.currentIndex.value > 0;
          return _IconAction(
            tooltip: '上一段',
            onTap: canPrev ? controller.prevFile : null,
            icon: Icon(Remix.skip_back_line, color: canPrev ? Colors.white : Colors.white38),
          );
        }),
        Obx(() {
          final canNext = controller.currentIndex.value < controller.group.value.mp4s.length - 1;
          return _IconAction(
            tooltip: '下一段',
            onTap: canNext ? controller.nextFile : null,
            icon: Icon(Remix.skip_forward_line, color: canNext ? Colors.white : Colors.white38),
          );
        }),
        const SizedBox(width: 6),
        _DanmakuToggleButton(controller: controller),
        _IconAction(
          tooltip: '弹幕设置',
          onTap: () async {
            controller.isMenuOpen.value = true;
            controller.stopHideController();
            try {
              final binding = LocalPlaybackDanmakuBinding(SettingsService.to.danmaku);
              await Get.dialog(
                Dialog(
                  child: SizedBox(width: 420, height: 560, child: DanmakuSettingsPage(controller: binding)),
                ),
                barrierColor: Colors.black.withValues(alpha: 0.58),
              );
            } finally {
              controller.isMenuOpen.value = false;
              controller.enableController();
            }
          },
          icon: SvgPicture.asset(
            'assets/images/video/danmu_setting.svg',
            // ignore: deprecated_member_use
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _DanmakuToggleButton extends StatelessWidget {
  final LocalPlaybackController controller;
  const _DanmakuToggleButton({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final enabled = controller.danmakuEnabled.value;
      return Tooltip(
        message: enabled ? '关闭弹幕' : '开启弹幕',
        child: GestureDetector(
          onTap: controller.toggleDanmaku,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(right: 6, left: 6),
            child: enabled
                ? SvgPicture.asset(
                    'assets/images/video/danmu_open.svg',
                    // ignore: deprecated_member_use
                    color: Colors.white,
                  )
                : SvgPicture.asset(
                    'assets/images/video/danmu_close.svg',
                    // ignore: deprecated_member_use
                    color: Colors.white,
                  ),
          ),
        ),
      );
    });
  }
}

class _RightActions extends StatelessWidget {
  final LocalPlaybackController controller;
  const _RightActions({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SpeedControl(controller: controller),
        _VideoFitSetting(controller: controller),
        _OverlayVolumeControl(controller: controller),
        Obx(() {
          if (controller.isFullscreen.value) return const SizedBox.shrink();
          final expanded = controller.isWindowFullscreen.value;
          return Tooltip(
            message: expanded ? '退出窗口全屏' : '窗口全屏',
            child: GestureDetector(
              onTap: controller.toggleWindowFullScreen,
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.only(left: 6),
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
        }),
        Obx(() {
          if (controller.isWindowFullscreen.value) return const SizedBox.shrink();
          final expanded = controller.isFullscreen.value;
          return Tooltip(
            message: expanded ? '退出全屏' : '全屏',
            child: GestureDetector(
              onTap: controller.toggleFullScreen,
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  expanded ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onTap;
  final Widget icon;

  const _IconAction({required this.tooltip, required this.onTap, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(alignment: Alignment.center, padding: const EdgeInsets.only(right: 6), child: icon),
      ),
    );
  }
}

class _OverlayVolumeControl extends StatefulWidget {
  final LocalPlaybackController controller;
  const _OverlayVolumeControl({required this.controller});

  @override
  State<_OverlayVolumeControl> createState() => _OverlayVolumeControlState();
}

class _OverlayVolumeControlState extends State<_OverlayVolumeControl> {
  double _volume = 0.5;
  double _lastVolume = 0.5;
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInIcon = false;
  bool _isMouseInBar = false;
  Timer? _hideTimer;
  Worker? _volumeWorker;

  static const double _barHeight = 150.0;
  static const double _barWidth = 44.0;

  @override
  void initState() {
    super.initState();
    _volume = widget.controller.volume.value;
    if (_volume > 0) _lastVolume = _volume;
    _volumeWorker = ever(widget.controller.volume, (v) {
      if (!mounted) return;
      setState(() {
        _volume = v;
        if (v > 0) _lastVolume = v;
      });
      _overlayEntry?.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    _volumeWorker?.dispose();
    _hideTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    super.dispose();
  }

  void _show() {
    if (_overlayEntry != null || !mounted) return;
    widget.controller.isMenuOpen.value = true;
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: _barWidth,
        height: _barHeight + 45,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, 5),
          child: MouseRegion(
            onEnter: (_) {
              _isMouseInBar = true;
              widget.controller.stopHideController();
            },
            onExit: (_) {
              _isMouseInBar = false;
              widget.controller.enableController();
              _startHideTimer();
            },
            child: _buildBarUI(),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_isMouseInIcon && !_isMouseInBar) _remove();
    });
  }

  void _remove() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    widget.controller.isMenuOpen.value = false;
    widget.controller.enableController();
  }

  Widget _buildBarUI() {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(220),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white10),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackHeight = constraints.maxHeight - 65;
              final percentage = (_volume * 100).round();
              return Column(
                children: [
                  const SizedBox(height: 12),
                  Text(
                    '$percentage%',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onVerticalDragUpdate: (details) => _handleDrag(details, trackHeight),
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 4,
                            margin: const EdgeInsets.only(top: 10, bottom: 20),
                            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                          ),
                          Positioned(
                            bottom: 20,
                            child: Container(
                              width: 4,
                              height: _volume * trackHeight,
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                          Positioned(
                            bottom: 20 + (_volume * trackHeight) - 6,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _handleDrag(DragUpdateDetails details, double trackHeight) {
    if (trackHeight <= 0) return;
    final deltaRatio = -details.delta.dy / trackHeight;
    final newVolume = (_volume + deltaRatio).clamp(0.0, 1.0);
    if (newVolume != _volume) {
      setState(() {
        _volume = newVolume;
        if (_volume > 0) _lastVolume = _volume;
      });
      _overlayEntry?.markNeedsBuild();
      widget.controller.setVolume(_volume);
    }
  }

  void _toggleMute() {
    setState(() {
      if (_volume > 0) {
        _lastVolume = _volume;
        _volume = 0;
      } else {
        _volume = _lastVolume > 0 ? _lastVolume : 0.5;
      }
    });
    widget.controller.setVolume(_volume);
  }

  @override
  Widget build(BuildContext context) {
    IconData icon = _volume == 0 ? Icons.volume_off : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up);

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          _isMouseInIcon = true;
          _show();
        },
        onExit: (_) {
          _isMouseInIcon = false;
          _startHideTimer();
        },
        child: IconButton(
          onPressed: _toggleMute,
          icon: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

class _SpeedControl extends StatefulWidget {
  final LocalPlaybackController controller;
  const _SpeedControl({required this.controller});

  @override
  State<_SpeedControl> createState() => _SpeedControlState();
}

class _SpeedControlState extends State<_SpeedControl> {
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInIcon = false;
  bool _isMouseInBar = false;
  Timer? _hideTimer;
  Worker? _speedWorker;

  double _currentSpeed = 1.0;

  static const double _barWidth = 44.0;
  static const double _barHeight = 150.0;
  static const double _minSpeed = 0.5;
  static const double _maxSpeed = 3.0;

  @override
  void initState() {
    super.initState();
    _currentSpeed = (widget.controller.playbackSpeed.value * 10).round() / 10;
    _speedWorker = ever(widget.controller.playbackSpeed, (v) {
      if (!mounted) return;
      final rounded = (v * 10).round() / 10;
      if ((rounded - _currentSpeed).abs() < 0.001) {
        _overlayEntry?.markNeedsBuild();
        return;
      }
      setState(() {
        _currentSpeed = rounded;
      });
      _overlayEntry?.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    _speedWorker?.dispose();
    _hideTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    super.dispose();
  }

  void _show() {
    if (_overlayEntry != null || !mounted) return;
    widget.controller.isMenuOpen.value = true;
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: _barWidth,
        height: _barHeight + 45,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, 5),
          child: MouseRegion(
            onEnter: (_) {
              _isMouseInBar = true;
              widget.controller.stopHideController();
            },
            onExit: (_) {
              _isMouseInBar = false;
              widget.controller.enableController();
              _startHideTimer();
            },
            child: _buildBarUI(),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_isMouseInIcon && !_isMouseInBar) _remove();
    });
  }

  void _remove() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    widget.controller.isMenuOpen.value = false;
    widget.controller.enableController();
  }

  double _speedToFrac(double speed) {
    return ((speed - _minSpeed) / (_maxSpeed - _minSpeed)).clamp(0.0, 1.0);
  }

  double _fracToSpeed(double frac) {
    return (_minSpeed + frac * (_maxSpeed - _minSpeed)).clamp(_minSpeed, _maxSpeed);
  }

  Widget _buildBarUI() {
    final frac = _speedToFrac(_currentSpeed);
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(220),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white10),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackHeight = constraints.maxHeight - 65;
              return Column(
                children: [
                  const SizedBox(height: 12),
                  Text(
                    '${_currentSpeed.toStringAsFixed(1)}x',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  Expanded(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _updateSpeedFromPosition(event.localPosition.dy, trackHeight),
                      onPointerMove: (event) {
                        if (event.buttons != 0) {
                          _updateSpeedFromPosition(event.localPosition.dy, trackHeight);
                        }
                      },
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 4,
                            margin: const EdgeInsets.only(top: 10, bottom: 20),
                            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                          ),
                          Positioned(
                            bottom: 20,
                            child: Container(
                              width: 4,
                              height: frac * trackHeight,
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                          Positioned(
                            bottom: 20 + (frac * trackHeight) - 6,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _updateSpeedFromPosition(double dy, double trackHeight) {
    if (trackHeight <= 0) return;
    // dy=0 是顶部（最大速度），dy=trackHeight 是底部（最小速度）
    final frac = (1.0 - (dy / trackHeight)).clamp(0.0, 1.0);
    final newSpeed = _fracToSpeed(frac);
    final rounded = (newSpeed * 10).round() / 10;
    if ((rounded - _currentSpeed).abs() < 0.001) return;
    setState(() {
      _currentSpeed = rounded;
    });
    _overlayEntry?.markNeedsBuild();
    widget.controller.setSpeed(rounded);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          _isMouseInIcon = true;
          _show();
        },
        onExit: (_) {
          _isMouseInIcon = false;
          _startHideTimer();
        },
        child: SizedBox(
          width: 48,
          height: 48,
          child: Container(
            alignment: Alignment.center,
            color: Colors.transparent,
            child: Obx(
              () => Text(
                '${widget.controller.playbackSpeed.value.toStringAsFixed(1)}x',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoFitSetting extends StatefulWidget {
  final LocalPlaybackController controller;
  const _VideoFitSetting({required this.controller});

  @override
  State<_VideoFitSetting> createState() => _VideoFitSettingState();
}

class _VideoFitSettingState extends State<_VideoFitSetting> {
  static const double _minPanelWidth = 110.0;
  static const double _maxPanelWidth = 200.0;
  static const double _itemHeight = 32.0;

  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInButton = false;
  bool _isMouseInPanel = false;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showPanel() {
    if (_overlayEntry != null || !mounted) return;
    widget.controller.isMenuOpen.value = true;
    widget.controller.stopHideController();

    final options = AppConsts().videoFitType;
    final panelHeight = options.length * _itemHeight + 6;
    final panelWidth = _computePanelWidth();

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
              widget.controller.stopHideController();
            },
            onExit: (_) {
              _isMouseInPanel = false;
              widget.controller.enableController();
              _startHideTimer();
            },
            child: _buildPanel(),
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

  void _removeOverlay() {
    _hideTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    _isMouseInPanel = false;
    widget.controller.isMenuOpen.value = false;
    widget.controller.enableController();
  }

  double _computePanelWidth() {
    final textTheme = Theme.of(context).textTheme;
    var maxLabelWidth = 0.0;
    for (final option in AppConsts().videoFitType) {
      final text = i18n(option['desc'] as String);
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      maxLabelWidth = math.max(maxLabelWidth, painter.width);
    }
    return (maxLabelWidth + 44).clamp(_minPanelWidth, _maxPanelWidth).toDouble();
  }

  Widget _buildPanel() {
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
                  onTap: i == current ? null : () => player.videoFitIndex.v = i,
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

class _PlaylistItem extends StatelessWidget {
  final Mp4Entry entry;
  final bool isCurrent;
  final bool hasDanmaku;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PlaylistItem({
    required this.entry,
    required this.isCurrent,
    required this.hasDanmaku,
    required this.onTap,
    required this.onDelete,
  });

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel =
        '${entry.modified.year}-${entry.modified.month.toString().padLeft(2, '0')}-${entry.modified.day.toString().padLeft(2, '0')} ${entry.modified.hour.toString().padLeft(2, '0')}:${entry.modified.minute.toString().padLeft(2, '0')}';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isCurrent ? theme.colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isCurrent ? theme.colorScheme.primary.withValues(alpha: 0.3) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isCurrent ? Icons.play_circle_filled_rounded : Icons.play_circle_outline_rounded,
                size: 20,
                color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      p.basename(entry.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.t12.copyWith(
                        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          dateLabel,
                          style: AppTextStyles.t11.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatSize(entry.size),
                          style: AppTextStyles.t11.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                        ),
                        if (hasDanmaku) ...[
                          const SizedBox(width: 6),
                          Icon(Remix.chat_3_line, size: 11, color: theme.colorScheme.primary),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDelete,
                icon: Icon(Remix.delete_bin_line, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                splashRadius: 16,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VolumeDragArea extends StatefulWidget {
  final LocalPlaybackController controller;
  const _VolumeDragArea({required this.controller});

  @override
  State<_VolumeDragArea> createState() => _VolumeDragAreaState();
}

class _VolumeDragAreaState extends State<_VolumeDragArea> {
  LocalPlaybackController get controller => widget.controller;

  Timer? _hideBVTimer;
  Timer? _activateTimer;
  bool _hideBVStuff = true;
  bool _isActivated = false;
  double _updateDargVarVal = 1.0;
  Worker? _volumeWorker;

  static const Duration _activateDelay = Duration(milliseconds: 300);

  static const double _dragPixelsPerFullRange = 560.0;
  static const double _wheelDyPerStep = 120.0;
  static const double _wheelStepRatio = 0.05;

  @override
  void initState() {
    super.initState();
    _updateDargVarVal = controller.volume.value;
    _volumeWorker = ever(controller.volume, (v) {
      if (!mounted) return;
      _updateDargVarVal = v;
      setState(() {});
      _cancelAndRestartHideBVTimer();
    });
  }

  @override
  void dispose() {
    _volumeWorker?.dispose();
    _hideBVTimer?.cancel();
    _activateTimer?.cancel();
    super.dispose();
  }

  void _cancelAndRestartHideBVTimer() {
    _hideBVTimer?.cancel();
    _hideBVTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _hideBVStuff = true);
    });
    setState(() => _hideBVStuff = false);
  }

  void _syncBaseValue() {
    _updateDargVarVal = controller.volume.value;
  }

  void _applyVerticalDelta(double dy) {
    double deltaValue = -(dy / _dragPixelsPerFullRange);
    double nextValue = (_updateDargVarVal + deltaValue).clamp(0.0, 1.0);

    if ((nextValue - _updateDargVarVal).abs() < 0.001) return;

    _updateDargVarVal = nextValue;
    controller.setVolume(nextValue);
    setState(() {});
  }

  void _applyScrollDelta(double dy) {
    double deltaValue = -(dy / _wheelDyPerStep) * _wheelStepRatio;
    double nextValue = (_updateDargVarVal + deltaValue).clamp(0.0, 1.0);

    if ((nextValue - _updateDargVarVal).abs() < 0.001) return;

    _updateDargVarVal = nextValue;
    controller.setVolume(nextValue);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    IconData iconData = _updateDargVarVal <= 0
        ? Icons.volume_mute
        : _updateDargVarVal < 0.5
        ? Icons.volume_down
        : Icons.volume_up;

    final int percentage = (_updateDargVarVal * 100).round();

    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryButton && HardwareKeyboard.instance.isControlPressed) return;
        if (event.buttons != kPrimaryButton) return;
        _syncBaseValue();
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
          if (HardwareKeyboard.instance.isControlPressed) return;
          _syncBaseValue();
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

class _SpeedHudOverlay extends StatelessWidget {
  final LocalPlaybackController controller;
  const _SpeedHudOverlay({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Obx(() {
        final visible = controller.isSpeedHudVisible.value;
        return AnimatedOpacity(
          opacity: visible ? 0.8 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            child: Card(
              color: Colors.black,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.speed, color: Colors.white),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 100,
                          height: 20,
                          child: LinearProgressIndicator(
                            value: ((controller.playbackSpeed.value - 0.5) / 2.5).clamp(0.0, 1.0),
                            backgroundColor: Colors.white38,
                            valueColor: const AlwaysStoppedAnimation(Colors.white),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      '${controller.playbackSpeed.value.toStringAsFixed(1)}x',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _LocalPlayerInteractions extends StatefulWidget {
  final LocalPlaybackController controller;
  final Widget child;
  const _LocalPlayerInteractions({required this.controller, required this.child});

  @override
  State<_LocalPlayerInteractions> createState() => _LocalPlayerInteractionsState();
}

class _LocalPlayerInteractionsState extends State<_LocalPlayerInteractions> {
  LocalPlaybackController get controller => widget.controller;

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
    if (escape && isShortcutsTargetFocused()) return false;

    final ctrlOrCmd = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

    if (event.logicalKey == LogicalKeyboardKey.space || event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      controller.togglePlayPause();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPlay) {
      controller.videoController.player.play();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.mediaPause) {
      controller.videoController.player.pause();
      return true;
    }

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyF) {
      if (controller.isFullscreen.value) return false;
      controller.toggleWindowFullScreen();
      return true;
    }

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyS) {
      unawaited(controller.takeScreenshot());
      return true;
    }

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyD) {
      controller.toggleDanmaku();
      return true;
    }

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
      unawaited(controller.toggleMute());
      return true;
    }

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyB) {
      unawaited(controller.togglePiP());
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _adjustVolume(0.05);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _adjustVolume(-0.05);
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      controller.enableController();
      final bigStep = HardwareKeyboard.instance.isShiftPressed;
      final step = bigStep ? const Duration(seconds: 30) : const Duration(seconds: 5);
      if (controller.totalDuration.value > Duration.zero) {
        controller.seekRelative(-step);
      }
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      controller.enableController();
      final bigStep = HardwareKeyboard.instance.isShiftPressed;
      final step = bigStep ? const Duration(seconds: 30) : const Duration(seconds: 5);
      if (controller.totalDuration.value > Duration.zero) {
        controller.seekRelative(step);
      }
      return true;
    }

    if (!escape) return false;

    if (controller.isPipMode.value) {
      unawaited(controller.exitPiP());
      return true;
    }
    if (controller.isFullscreen.value) {
      controller.toggleFullScreen();
      return true;
    }
    if (controller.isWindowFullscreen.value) {
      controller.toggleWindowFullScreen();
      return true;
    }
    Navigator.of(context).maybePop();
    return true;
  }

  Future<void> _adjustVolume(double delta) async {
    final next = (controller.volume.value + delta).clamp(0.0, 1.0);
    await controller.setVolume(next);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
