import 'dart:math' as math;

import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/pip/mini_pip_controller.dart';
import 'package:pure_live/player/widgets/video_output_viewport_sizer.dart';

/// 侧栏"切换直播间"选台的统一入口：
/// 普通点击切换主窗房间；按住 Ctrl 点击则在进程内小窗中打开（不切换主窗）。
void selectRoomWithMiniPip(LivePlayController controller, LiveRoom room) {
  if (HardwareKeyboard.instance.isControlPressed) {
    controller.miniPip.open(room);
  } else {
    controller.switchRoom(room);
  }
}

/// 进程内小窗宿主：渲染在播放页内容之上（沉浸模式时由 LivePlayShell
/// 挂在视频层与侧栏层之间，因此侧栏展开时始终盖住小窗）。
///
/// 透明区域不参与命中测试，事件直达下层播放控制；Z 序即槽位列表顺序，
/// 指针按下任意小窗会把该槽位置于列表尾部（最前）。
class MiniPipHost extends StatelessWidget {
  const MiniPipHost({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = _maybeManager();
    if (manager == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final hostSize = Size(constraints.maxWidth, constraints.maxHeight);
        // 宿主尺寸变化时，将所有小窗位置 clamp 回可视区域，避免跑出窗口外。
        // 只在位置越界时写回，避免无谓的 Obx 重建。
        if (hostSize.isFinite && !hostSize.isEmpty) {
          for (final slot in manager.slots) {
            final pos = slot.position.value;
            if (pos == null) continue;
            final win = slot.size.value;
            final clamped = Offset(
              pos.dx.clamp(0.0, math.max(0.0, hostSize.width - win.width)).toDouble(),
              pos.dy.clamp(0.0, math.max(0.0, hostSize.height - win.height)).toDouble(),
            );
            if (clamped != pos) slot.position.value = clamped;
          }
        }
        return Obx(
          () => Stack(
            clipBehavior: Clip.none,
            children: [
              for (final slot in manager.slots)
                _PositionedMiniPip(
                  key: ValueKey('mini_pip_${slot.room.platform}_${slot.room.roomId}'),
                  manager: manager,
                  slot: slot,
                  hostSize: hostSize.isFinite ? hostSize : Size.zero,
                ),
            ],
          ),
        );
      },
    );
  }

  static MiniPipController? _maybeManager() {
    if (!Get.isRegistered<LivePlayController>()) return null;
    return Get.find<LivePlayController>().miniPip;
  }
}

class _PositionedMiniPip extends StatelessWidget {
  const _PositionedMiniPip({super.key, required this.manager, required this.slot, required this.hostSize});

  final MiniPipController manager;
  final MiniPipSlot slot;
  final Size hostSize;

  /// 初始锚点：左下角开始，多窗向右上错位层叠。
  Offset _initialPosition(int index, Size host, Size win) {
    if (host.isEmpty) return Offset.zero;
    const margin = 20.0;
    const cascade = 32.0;
    final left = (margin + index * cascade).clamp(0.0, math.max(0.0, host.width - win.width)).toDouble();
    final top = (host.height - win.height - margin - index * cascade)
        .clamp(0.0, math.max(0.0, host.height - win.height))
        .toDouble();
    return Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    final index = manager.slots.indexOf(slot);
    return Obx(() {
      final winSize = slot.size.value;
      // 首帧位置回退：宿主尺寸在 LayoutBuilder 中才可知。
      // 关键：将计算出的初始位置写回 slot.position，否则首次拖拽时
      // _startDrag 读到 null 会用 Offset.zero，导致窗口瞬移到左上角。
      var position = slot.position.value;
      position ??= _initialPosition(index < 0 ? 0 : index, hostSize, winSize);
      if (slot.position.value == null) {
        slot.position.value = position;
      }
      return Positioned(
        left: position.dx,
        top: position.dy,
        width: winSize.width,
        height: winSize.height,
        child: _MiniPipWindow(manager: manager, slot: slot, hostSize: hostSize),
      );
    });
  }
}

class _MiniPipWindow extends StatefulWidget {
  const _MiniPipWindow({required this.manager, required this.slot, required this.hostSize});

  final MiniPipController manager;
  final MiniPipSlot slot;
  final Size hostSize;

  @override
  State<_MiniPipWindow> createState() => _MiniPipWindowState();
}

class _MiniPipWindowState extends State<_MiniPipWindow> {
  /// 拖拽中：窗口整体透明度降至 0.8（与旧悬浮窗 dragOpacity 一致）。
  bool _dragging = false;

  /// 八方向边缘缩放：按下即锁定起始几何，指针移动时按方向更新尺寸（保持 16:9）。
  /// [handle] 用位标记组合表示命中的边（left/right/top/bottom）。
  void _startResize(PointerDownEvent event, int handle) {
    widget.manager.focus(widget.slot);
    final startPos = widget.slot.position.value ?? Offset.zero;
    final startSize = widget.slot.size.value;
    final router = GestureBinding.instance.pointerRouter;
    final pointer = event.pointer;
    // e.delta 是单帧增量，需累加为自按下起的总位移。
    double accDx = 0;
    double accDy = 0;
    late final void Function(PointerEvent) route;
    route = (PointerEvent e) {
      if (e is PointerMoveEvent) {
        accDx += e.delta.dx;
        accDy += e.delta.dy;
        var newLeft = startPos.dx;
        var newTop = startPos.dy;
        var newWidth = startSize.width;
        var newHeight = startSize.height;
        const aspect = 16.0 / 9.0;

        if ((handle & _edgeRight) != 0) {
          newWidth = (startSize.width + accDx).clamp(MiniPipController.minSize.width, MiniPipController.maxSize.width);
        }
        if ((handle & _edgeLeft) != 0) {
          newWidth = (startSize.width - accDx).clamp(MiniPipController.minSize.width, MiniPipController.maxSize.width);
        }
        if ((handle & _edgeBottom) != 0) {
          newHeight = (startSize.height + accDy).clamp(
            MiniPipController.minSize.height,
            MiniPipController.maxSize.height,
          );
        }
        if ((handle & _edgeTop) != 0) {
          newHeight = (startSize.height - accDy).clamp(
            MiniPipController.minSize.height,
            MiniPipController.maxSize.height,
          );
        }

        // 保持 16:9。
        if ((handle & (_edgeLeft | _edgeRight)) != 0 && (handle & (_edgeTop | _edgeBottom)) != 0) {
          if (newWidth / aspect >= newHeight) {
            newHeight = newWidth / aspect;
          } else {
            newWidth = newHeight * aspect;
          }
        } else if ((handle & (_edgeLeft | _edgeRight)) != 0) {
          newHeight = newWidth / aspect;
        } else if ((handle & (_edgeTop | _edgeBottom)) != 0) {
          newWidth = newHeight * aspect;
        }

        // 左/上边缘缩放时同步修正位置，保持对边不动。
        if ((handle & _edgeLeft) != 0) {
          newLeft = startPos.dx + (startSize.width - newWidth);
        }
        if ((handle & _edgeTop) != 0) {
          newTop = startPos.dy + (startSize.height - newHeight);
        }

        final newSize = Size(newWidth, newHeight);
        widget.manager.updateSize(widget.slot, newSize);
        widget.slot.position.value = _clampIntoHost(Offset(newLeft, newTop), newSize);
      } else if (e is PointerUpEvent || e is PointerCancelEvent) {
        router.removeRoute(pointer, route);
      }
    };
    router.addRoute(pointer, route);
  }

  static const int _edgeLeft = 1;
  static const int _edgeRight = 2;
  static const int _edgeTop = 4;
  static const int _edgeBottom = 8;

  Offset _clampIntoHost(Offset position, [Size? win]) {
    final winSize = win ?? widget.slot.size.value;
    final host = widget.hostSize;
    if (host.isEmpty) return position;
    return Offset(
      position.dx.clamp(0.0, math.max(0.0, host.width - winSize.width)).toDouble(),
      position.dy.clamp(0.0, math.max(0.0, host.height - winSize.height)).toDouble(),
    );
  }

  /// 整个视频面可拖拽：按下即启动 pointerRouter 跟踪，指针移出小窗也不中断；
  /// 首次移动才标记为拖拽中（避免单击误触发透明度变化）。
  void _startDrag(PointerDownEvent event) {
    widget.manager.focus(widget.slot);
    final router = GestureBinding.instance.pointerRouter;
    final pointer = event.pointer;
    late final void Function(PointerEvent) route;
    route = (PointerEvent e) {
      if (e is PointerMoveEvent) {
        if (!_dragging && mounted) setState(() => _dragging = true);
        final current = widget.slot.position.value ?? Offset.zero;
        widget.slot.position.value = _clampIntoHost(current + e.delta);
      } else if (e is PointerUpEvent || e is PointerCancelEvent) {
        if (_dragging && mounted) setState(() => _dragging = false);
        router.removeRoute(pointer, route);
      }
    };
    router.addRoute(pointer, route);
  }

  /// Ctrl+滚轮缩放窗口尺寸（保持 16:9）；不处理普通滚轮，
  /// 避免与播放页音量等其他滚轮语义冲突。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    final oldWidth = widget.slot.size.value.width;
    final newWidth = (oldWidth + (-dy / 120.0) * MiniPipController.wheelWidthStep)
        .clamp(MiniPipController.minSize.width, MiniPipController.maxSize.width)
        .toDouble();
    final newSize = Size(newWidth, newWidth * 9.0 / 16.0);
    widget.manager.updateSize(widget.slot, newSize);
    final position = widget.slot.position.value;
    if (position != null) {
      widget.slot.position.value = _clampIntoHost(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    return Listener(
      onPointerSignal: _handlePointerSignal,
      child: MouseRegion(
        onEnter: (_) => slot.hovered.value = true,
        onExit: (_) => slot.hovered.value = false,
        child: Obx(() {
          // 基础透明度由左下角控制条决定（0.3~1.0）；拖拽时再叠加 0.8 系数。
          // 注意：透明度仅作用于视频画面/弹幕/黑底层，顶部/底部控制条、状态层、
          // 缩放手柄始终保持 100% 不透明，避免控件随视频一起变淡而难以操作。
          final baseOpacity = slot.opacity.value;
          final effectiveOpacity = (_dragging ? baseOpacity * 0.8 : baseOpacity)
              .clamp(MiniPipController.minOpacity, MiniPipController.maxOpacity)
              .toDouble();
          // 阴影保留在最外层（外边框已移除，避免与边缘拖拽命中区冲突）。
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 透明层：黑底 + 视频 + 弹幕 + 视频面拖拽/双击手势。
                  AnimatedOpacity(
                    opacity: effectiveOpacity,
                    duration: const Duration(milliseconds: 120),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        _buildVideo(),
                        _buildDanmaku(),
                        // 整个视频面：拖拽（Listener 原始事件） + 双击提升到主窗（手势）。
                        // 置于状态层与按钮层之下，确保重试/关闭等按钮优先命中。
                        Positioned.fill(
                          child: Listener(
                            onPointerDown: _startDrag,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onDoubleTap: () => widget.manager.promoteToMain(slot),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 以下控件始终不透明，叠在视频层之上。
                  _buildStatusOverlay(),
                  _buildTopChrome(),
                  _buildBottomControls(),
                  // 边缘缩放手柄置于最上层，仅占用边缘 6px 区域。
                  ..._buildResizeHandles(),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  /// 八方向缩放手柄：4 角 + 4 边。仅悬停时可命中（非悬停时穿透到拖拽层）。
  List<Widget> _buildResizeHandles() {
    const t = 6.0; // 边缘命中厚度
    return [
      // 四个角
      _resizeHandle(
        left: 0,
        top: 0,
        width: t,
        height: t,
        cursor: SystemMouseCursors.resizeUpLeft,
        handle: _edgeLeft | _edgeTop,
      ),
      _resizeHandle(
        right: 0,
        top: 0,
        width: t,
        height: t,
        cursor: SystemMouseCursors.resizeUpRight,
        handle: _edgeRight | _edgeTop,
      ),
      _resizeHandle(
        left: 0,
        bottom: 0,
        width: t,
        height: t,
        cursor: SystemMouseCursors.resizeDownLeft,
        handle: _edgeLeft | _edgeBottom,
      ),
      _resizeHandle(
        right: 0,
        bottom: 0,
        width: t,
        height: t,
        cursor: SystemMouseCursors.resizeDownRight,
        handle: _edgeRight | _edgeBottom,
      ),
      // 四条边（角已占，边留 t 避免与角冲突）
      _resizeHandle(left: t, top: 0, right: t, height: t, cursor: SystemMouseCursors.resizeUp, handle: _edgeTop),
      _resizeHandle(
        left: t,
        bottom: 0,
        right: t,
        height: t,
        cursor: SystemMouseCursors.resizeDown,
        handle: _edgeBottom,
      ),
      _resizeHandle(left: 0, top: t, width: t, bottom: t, cursor: SystemMouseCursors.resizeLeft, handle: _edgeLeft),
      _resizeHandle(right: 0, top: t, width: t, bottom: t, cursor: SystemMouseCursors.resizeRight, handle: _edgeRight),
    ];
  }

  Widget _resizeHandle({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required MouseCursor cursor,
    required int handle,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: Obx(() {
        final slot = widget.slot;
        final interactive = slot.hovered.value;
        return MouseRegion(
          cursor: interactive ? cursor : MouseCursor.defer,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: interactive ? (e) => _startResize(e, handle) : null,
          ),
        );
      }),
    );
  }

  Widget _buildVideo() {
    return Obx(() {
      final slot = widget.slot;
      final status = slot.status.value;
      final controller = slot.player?.videoController;
      if (status != MiniPipStatus.playing || controller == null) {
        return const SizedBox.shrink();
      }
      final video = Video(
        controller: controller,
        controls: NoVideoControls,
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
      );
      if (!PlatformUtils.isWindows) return video;
      return VideoOutputViewportSizer(
        outputIdentity: controller,
        sourceWidth: controller.player.stream.width,
        sourceHeight: controller.player.stream.height,
        fit: BoxFit.contain,
        onResize: (width, height, force) => controller.setSize(width: width, height: height, force: force),
        child: video,
      );
    });
  }

  Widget _buildDanmaku() {
    return Obx(() {
      final slot = widget.slot;
      final barrage = slot.danmakuEnabled.value ? slot.barrageController : null;
      if (barrage == null) return const SizedBox.shrink();
      return Positioned.fill(
        child: IgnorePointer(
          child: Obx(() {
            SettingsService.to.app.refreshRateModeName.v;
            return FlameBarrageWidget(
              controller: barrage,
              enablePointerEvents: false,
              config: _miniBarrageConfig(),
              emojiAtlas: EmojiAtlas.instance,
            );
          }),
        ),
      );
    });
  }

  Widget _buildStatusOverlay() {
    return Obx(() {
      switch (widget.slot.status.value) {
        case MiniPipStatus.playing:
          return const SizedBox.shrink();
        case MiniPipStatus.resolving:
          return const ColoredBox(
            color: Colors.black54,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white70),
              ),
            ),
          );
        case MiniPipStatus.offline:
        case MiniPipStatus.error:
          return _MiniPipErrorView(
            offline: widget.slot.status.value == MiniPipStatus.offline,
            onRetry: () => widget.manager.retry(widget.slot),
            onClose: () => widget.manager.close(widget.slot),
          );
      }
    });
  }

  /// 顶部悬停层：左上弹幕开关、顶部居中平台 logo+主播名、右上关闭。
  /// 静音/音量已移至底部音量条。
  Widget _buildTopChrome() {
    final slot = widget.slot;
    return Obx(() {
      final visible = slot.hovered.value || slot.status.value != MiniPipStatus.playing;
      return IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Stack(
            children: [
              Positioned(left: 6, top: 6, child: _chromeDanmakuButton(slot)),
              Positioned(left: 48, right: 48, top: 6, child: _buildRoomLabel()),
              Positioned(right: 6, top: 6, child: _chromeCloseButton(slot)),
            ],
          ),
        ),
      );
    });
  }

  /// 底部左侧：垂直透明度条。
  Widget _buildBottomControls() {
    final slot = widget.slot;
    return Obx(() {
      final visible = slot.hovered.value || slot.status.value != MiniPipStatus.playing;
      final child = IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Stack(
            children: [
              Positioned(left: 6, bottom: 6, child: _buildOpacityControl(slot)),
              Positioned(right: 6, bottom: 6, child: _buildVolumeControl(slot)),
              Positioned(left: 0, right: 0, bottom: 6, child: _buildCenterButtons(slot)),
            ],
          ),
        ),
      );
      // Positioned 必须是外层 Stack 的直接子节点。
      return Positioned(left: 0, right: 0, bottom: 0, top: 0, child: child);
    });
  }

  /// 左侧垂直透明度条：图标 + 垂直轨道 + 数值（无百分号）。范围 0.3~1.0。
  Widget _buildOpacityControl(MiniPipSlot slot) {
    return Obx(() {
      final opacity = slot.opacity.value;
      final ratio =
          ((opacity - MiniPipController.minOpacity) / (MiniPipController.maxOpacity - MiniPipController.minOpacity))
              .clamp(0.0, 1.0)
              .toDouble();
      return _MiniPipVerticalSlider(
        icon: Icon(
          opacity < 0.5 ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 16,
          color: Colors.white,
        ),
        value: ratio,
        trackHeight: 90,
        displayValue: '${(opacity * 100).round()}',
        onChanged: (r) => widget.manager.setOpacity(
          slot,
          MiniPipController.minOpacity + r * (MiniPipController.maxOpacity - MiniPipController.minOpacity),
        ),
      );
    });
  }

  /// 底部居中：播放/暂停 + 刷新。
  Widget _buildCenterButtons(MiniPipSlot slot) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Obx(() {
          final playing = slot.isPlaying.value;
          return Tooltip(
            message: i18n('play_or_pause'),
            child: InkResponse(
              onTap: () => widget.manager.togglePlayPause(slot),
              radius: 20,
              splashFactory: NoSplash.splashFactory,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey(playing),
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(width: 10),
        _MiniPipIconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20, color: Colors.white),
          tooltip: i18n('mini_pip_retry'),
          onTap: () => widget.manager.retry(slot),
          size: 36,
          circular: true,
        ),
      ],
    );
  }

  /// 右侧垂直音量条：静音图标 + 垂直轨道 + 数值（无百分号）。默认静音。
  Widget _buildVolumeControl(MiniPipSlot slot) {
    return Obx(() {
      final volume = slot.volume.value;
      final muted = slot.muted.value;
      final icon = muted
          ? Icons.volume_off_rounded
          : (volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
      // 静音时数值显示为 0，与轨道填充一致。
      final displayVolume = muted ? 0.0 : volume;
      return _MiniPipVerticalSlider(
        icon: Icon(icon, size: 16, color: Colors.white),
        value: displayVolume,
        trackHeight: 90,
        displayValue: '${(displayVolume * 100).round()}',
        onChanged: (r) => widget.manager.setVolume(slot, r),
        onIconTap: () => widget.manager.toggleMute(slot),
      );
    });
  }

  Widget _chromeDanmakuButton(MiniPipSlot slot) {
    return Obx(() {
      final on = slot.danmakuEnabled.value;
      return _MiniPipIconButton(
        icon: Icon(on ? Icons.subtitles_rounded : Icons.subtitles_outlined, size: 18, color: Colors.white),
        tooltip: i18n('mini_pip_toggle_danmaku'),
        onTap: () => widget.manager.toggleDanmaku(slot),
      );
    });
  }

  Widget _chromeCloseButton(MiniPipSlot slot) {
    return _MiniPipIconButton(
      icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
      tooltip: i18n('mini_pip_close'),
      onTap: () => widget.manager.close(slot),
    );
  }

  Widget _buildRoomLabel() {
    final room = widget.slot.room;
    final nick = room.nick?.trim() ?? '';
    final title = room.title?.trim() ?? '';
    final name = nick.isNotEmpty ? nick : title;
    if (name.isEmpty) return const SizedBox.shrink();
    final logo = room.platform != null ? Sites.logoOf(room.platform!) : null;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (logo != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Image.asset(
                    logo,
                    width: 18,
                    height: 18,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPipIconButton extends StatelessWidget {
  const _MiniPipIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 32,
    this.circular = false,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: size / 2 + 4,
        splashFactory: NoSplash.splashFactory,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black45,
            shape: circular ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: circular ? null : BorderRadius.circular(8),
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }
}

/// 小窗垂直滑块条：顶部功能图标 + 可点击/拖动的垂直轨道 + 底部数值。
/// 数值自下而上递增（底部=0，顶部=1）。[displayValue] 使用固定宽度容器，
/// 避免 90→100 等位数变化导致整体宽度跳动。
class _MiniPipVerticalSlider extends StatelessWidget {
  const _MiniPipVerticalSlider({
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.displayValue,
    this.trackHeight = 90,
    this.onIconTap,
  });

  final Widget icon;
  final double value; // 0.0 ~ 1.0
  final ValueChanged<double> onChanged;
  final String displayValue;
  final double trackHeight;
  final VoidCallback? onIconTap;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      onDoubleTap: () {},
      child: Container(
        width: 40,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onIconTap,
              child: SizedBox(width: 26, height: 26, child: Center(child: icon)),
            ),
            const SizedBox(height: 4),
            _buildVerticalTrack(clamped),
            const SizedBox(height: 4),
            // 固定宽度 + 居中，避免数值位数变化引起水平方向跳动。
            SizedBox(
              width: 28,
              child: Text(
                displayValue,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalTrack(double clamped) {
    void updateFromDy(double dy) {
      // dy=0 在顶部，值为 1；dy=trackHeight 在底部，值为 0。
      onChanged((1.0 - dy / trackHeight).clamp(0.0, 1.0).toDouble());
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => updateFromDy(event.localPosition.dy),
        onPointerMove: (event) {
          if (event.buttons != 0) updateFromDy(event.localPosition.dy);
        },
        child: SizedBox(
          width: 20,
          height: trackHeight,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // 背景轨道（垂直，5px 宽居中）
              Center(
                child: Container(
                  width: 5,
                  height: trackHeight,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              // 填充（从底部向上）
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      width: 5,
                      height: clamped * trackHeight,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(3)),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: (clamped * trackHeight - 6).clamp(0.0, trackHeight - 12),
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
  }
}

class _MiniPipErrorView extends StatelessWidget {
  const _MiniPipErrorView({required this.offline, required this.onRetry, required this.onClose});

  final bool offline;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(offline ? Icons.videocam_off_outlined : Icons.error_outline_rounded, color: Colors.white70, size: 22),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              i18n(offline ? 'mini_pip_offline' : 'mini_pip_play_failed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(i18n('mini_pip_retry'), style: const TextStyle(fontSize: 11.5)),
              ),
              TextButton(
                onPressed: onClose,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(i18n('mini_pip_close'), style: const TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 小窗弹幕配置：读取"小窗弹幕"（pipDanmaku*）设置，与 Windows PiP 弹幕同源；
/// 池容量按小窗尺寸缩减，降低多路小窗的渲染开销。
BarrageConfig _miniBarrageConfig() {
  final s = SettingsService.to.danmaku;
  final fontSize = s.pipDanmakuFontSize.v.clamp(8.0, 24.0).toDouble();
  return BarrageConfig(
    emitInterval: s.pipDanmakuEmitInterval.v,
    fontSize: fontSize,
    topAreaDistance: 0,
    area: s.pipDanmakuArea.v,
    bottomAreaDistance: 0,
    baseSpeed: s.pipDanmakuSpeed.v,
    opacity: s.pipDanmakuOpacity.v,
    fontWeight: FontWeight(s.pipDanmakuFontWeight.v),
    strokeWidth: s.danmakuFontBorder.v,
    showStroke: s.enableDanmakuStroke.v,
    noEmojiMode: s.pipDanmakuNoEmojiMode.v,
    fps: s.resolvedDanmakuFps(pip: true, refreshRateMode: SettingsService.to.app.refreshRateMode),
    maxVisibleCount: s.pipDanmakuMaxVisibleCount.v,
    maxPendingCount: 36,
    maxPendingAge: const Duration(seconds: 3),
    fontFamily: s.danmakuFontFamilyName.v,
    trackHeight: (fontSize * 1.55).clamp(20.0, 48.0).toDouble(),
    emojiSize: (fontSize * 1.3).clamp(14.0, 30.0).toDouble(),
    pictureCacheMaxSize: 32,
    barragePoolMaxSize: 24,
    textCacheMaxSize: 120,
  );
}
