import 'dart:async';
import 'dart:ffi' hide Size; // AllocatorAlloc 扩展：使 ffi.calloc<T>() 语法可用
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:ffi/ffi.dart' as ffi;
import 'package:flutter/gestures.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/panel_size_controller.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_tab.dart';
import 'package:pure_live/modules/live_play/widgets/layout/live_play_video.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/layout/panel_popup_scope.dart';
import 'package:pure_live/modules/live_play/widgets/layout/panel_resize_divider.dart';
import 'package:pure_live/modules/live_play/widgets/resolution_selector/resolutions_row.dart';
import 'package:win32/win32.dart' as win32;

class LivePlayShell extends StatefulWidget {
  const LivePlayShell({super.key, required this.controller, this.showPanel = true});

  final LivePlayController controller;
  final bool showPanel;

  @override
  State<LivePlayShell> createState() => _LivePlayShellState();
}

class _LivePlayShellState extends State<LivePlayShell> with SingleTickerProviderStateMixin {
  late final ValueNotifier<double> _panelWidthNotifier;
  late final AnimationController _drawerController;

  LivePlayController get controller => widget.controller;

  bool get showPanel => widget.showPanel;

  bool _panelOpen = false;
  bool _panelLocked = false;
  bool _edgeControlsVisible = false;
  Timer? _hideTimer;
  Timer? _openTimer;
  int _openPanelPopups = 0;
  // 桌面端鼠标跟踪健壮性：事件驱动的 enter/exit 在指针快速划过区域或离开
  // 程序窗口时会丢失，因此辅以悬停调和（最新指针位置）与 Win32 光标探测
  // （决策点地面真值），并由看门狗兜底关闭。
  Offset? _lastHoverLocal;
  Timer? _cursorWatchdog;
  bool _dividerHovering = false;
  bool _isDesktopLayout = false;

  /// 边缘控制区透明度轨道高度（垂直），对应音量控制条水平轨道的长度。
  static const double _opacityTrackHeight = 100.0;

  /// 锁定按钮（黑色胶囊背景）边长，透明度胶囊宽度与其一致。
  static const double _lockButtonSize = 40.0;

  /// 边缘控制区宽度 == 锁定按钮背景宽度，保证控件与区域完全对齐。
  static const double _edgeZoneWidth = _lockButtonSize;

  @override
  void initState() {
    super.initState();
    final screenWidth = MediaQuery.sizeOf(context).width;
    _panelWidthNotifier = ValueNotifier<double>(
      SettingsService.to.panel.clampWidth(SettingsService.to.panel.panelWidth, screenWidth),
    );
    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 240),
    );
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _hideTimer?.cancel();
    _stopCursorWatchdog();
    _panelWidthNotifier.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showPanel) {
      return const _VideoHost();
    }

    final size = MediaQuery.sizeOf(context);
    final isSmallScreen = size.shortestSide < 600;
    _isDesktopLayout = !isSmallScreen;

    return ValueListenableBuilder<double>(
      valueListenable: _panelWidthNotifier,
      builder: (context, panelWidth, _) {
        return ClipRect(
          child: AnimatedBuilder(
            animation: _drawerController,
            builder: (context, child) {
              final progress = Curves.easeInOutCubic.transform(_drawerController.value);

              if (isSmallScreen) {
                return _buildMobileLayout(progress);
              }

              return _buildDesktopLayout(progress, panelWidth);
            },
          ),
        );
      },
    );
  }

  Widget _buildDesktopLayout(double progress, double panelWidth) {
    final panelOpacity = SettingsService.to.panel.immersiveOpacity;

    // 悬停调和层：任何指针移动都用最新位置重新推导定时器状态，
    // 自愈 enter/exit 事件丢失（快速划过或移出窗口边缘）。
    return MouseRegion(
      onHover: _handleShellHover,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(child: _VideoHost()),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: panelWidth,
            child: IgnorePointer(
              ignoring: progress < 0.01,
              child: MouseRegion(
                onEnter: (_) => _cancelHideTimer(),
                onExit: (_) {
                  _scheduleHide();
                  _hideEdgeControls();
                },
                child: SlideTransition(
                  position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
                    CurvedAnimation(parent: _drawerController, curve: Curves.easeInOutCubic),
                  ),
                  child: Opacity(opacity: panelOpacity, child: _buildPanelContent()),
                ),
              ),
            ),
          ),
          if (progress > 0.01)
            Positioned(
              right: panelWidth,
              top: 0,
              bottom: 0,
              width: 6,
              child: MouseRegion(
                onEnter: (_) {
                  _cancelHideTimer();
                  _dividerHovering = true;
                },
                onExit: (_) {
                  _dividerHovering = false;
                  _scheduleHide();
                },
                child: Opacity(
                  opacity: progress,
                  child: PanelResizeDivider(
                    currentWidth: panelWidth,
                    clampWidth: (width, screenWidth) =>
                        SettingsService.to.panel.clampWidth(width, screenWidth),
                    onResize: (newWidth) {
                      _panelWidthNotifier.value = newWidth;
                    },
                    onDragEnd: (finalWidth) {
                      final screenWidth = MediaQuery.sizeOf(context).width;
                      SettingsService.to.panel.setPanelWidth(finalWidth, screenWidth);
                    },
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            bottom: 0,
            right: panelWidth + 6,
            width: _edgeZoneWidth,
            child: IgnorePointer(
              ignoring: progress < 0.01,
              child: MouseRegion(
                onEnter: (_) {
                  _cancelHideTimer();
                  _showEdgeControls();
                },
                onExit: (_) {
                  _hideEdgeControls();
                  _scheduleHide();
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: (_edgeControlsVisible && progress >= 0.01)
                      ? _buildEdgeControls()
                      : const SizedBox.expand(key: ValueKey('hidden-edge-zone')),
                ),
              ),
            ),
          ),
          if (progress < 0.5)
            Positioned(
              top: 60,
              right: 0,
              bottom: 100,
              width: 80,
              child: MouseRegion(
                onEnter: (_) {
                  _cancelHideTimer();
                  _openTimer?.cancel();
                  _openTimer = Timer(const Duration(milliseconds: 300), _handleOpenTimer);
                },
                onExit: (_) {
                  _openTimer?.cancel();
                },
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEdgeControls() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [_buildLockButton(), const SizedBox(height: 20), _buildOpacityControl()],
      ),
    );
  }

  /// 锁定按钮：样式对齐宽屏模式播放器右侧的 LockButton
  /// （StadiumBorder 胶囊形、black38 背景、白色 28px 图标）。
  /// 用 tightFor 强制背景为精确的 40x40 正方形：minimumSize 只是下限，
  /// 图标 28 + 默认内边距 16 = 44 会把背景撑成 40x44 的竖椭圆导致图标偏位。
  Widget _buildLockButton() {
    final locked = _panelLocked;
    return Tooltip(
      message: locked ? i18n('unlock_panel') : i18n('lock_panel'),
      child: IconButton(
        onPressed: _toggleLock,
        icon: Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded, size: 28),
        color: Colors.white,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: _lockButtonSize, height: _lockButtonSize),
        style: IconButton.styleFrom(backgroundColor: Colors.black38, shape: const StadiumBorder()),
      ),
    );
  }

  /// 透明度控制：样式对齐播放器音量控制条（BrightnessVolumnDargArea 的
  /// 圆角轨道 + 百分比文本），音量条为水平布局，此处为垂直布局，
  /// 轨道填充自下而上，透明度越高填充越满；背景与锁定按钮一致（black38 胶囊）。
  Widget _buildOpacityControl() {
    final panelOpacity = SettingsService.to.panel.immersiveOpacity;
    final int percentage = (panelOpacity * 100).round();
    final fillFraction =
        ((panelOpacity - PanelSizeController.kMinImmersiveOpacity) /
                (PanelSizeController.kMaxImmersiveOpacity -
                    PanelSizeController.kMinImmersiveOpacity))
            .clamp(0.0, 1.0);
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final current = SettingsService.to.panel.immersiveOpacity;
          final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
          SettingsService.to.panel.immersiveOpacity = current + delta;
          setState(() {});
        }
      },
      child: Container(
        width: _lockButtonSize,
        decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$percentage',
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                final deltaRatio = -details.delta.dy / _opacityTrackHeight;
                final current = SettingsService.to.panel.immersiveOpacity;
                SettingsService.to.panel.immersiveOpacity = current + deltaRatio;
                setState(() {});
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 20,
                  height: _opacityTrackHeight,
                  child: Stack(
                    children: [
                      const Positioned.fill(child: ColoredBox(color: Colors.white38)),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(
                          height: _opacityTrackHeight * fillFraction,
                          child: const ColoredBox(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout(double progress) {
    return Stack(
      fit: StackFit.expand,
      children: [_buildMobileFlip(progress), _buildToggleButton(progress, 0)],
    );
  }

  Widget _buildMobileFlip(double progress) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.0018)
          ..rotateY(math.pi * progress);

        return Center(
          child: Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: Stack(
              fit: StackFit.expand,
              children: [_buildMobileVideoFace(progress), _buildMobilePanelFace(progress)],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMobileVideoFace(double progress) {
    final opacity = progress <= 0.5 ? 1.0 : 0.0;

    return IgnorePointer(
      ignoring: progress > 0.5,
      child: Opacity(opacity: opacity, child: const _VideoHost()),
    );
  }

  Widget _buildMobilePanelFace(double progress) {
    final opacity = progress >= 0.5 ? 1.0 : 0.0;
    final matrix = Matrix4.identity()..rotateY(math.pi);

    return IgnorePointer(
      ignoring: progress < 0.5,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.center,
          transform: matrix,
          child: _buildPanelContent(),
        ),
      ),
    );
  }

  Widget _buildToggleButton(double progress, double panelWidth) {
    final isDesktop = MediaQuery.sizeOf(context).shortestSide >= 600;
    final rightOffset = isDesktop ? panelWidth * progress : 0;

    return Positioned(
      top: 0,
      bottom: 0,
      right: rightOffset + 16,
      child: Center(
        child: SafeArea(
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: IconButton(
              tooltip: _panelOpen ? i18n('close_panel') : i18n('open_panel'),
              onPressed: _togglePanel,
              icon: AnimatedRotation(
                turns: _panelOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.keyboard_double_arrow_left, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelContent() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: PanelPopupScope(
        onPopupOpened: _handlePanelPopupOpened,
        onPopupClosed: _handlePanelPopupClosed,
        child: SafeArea(
          left: false,
          child: Column(
            children: [
              _buildResolution(),
              const Divider(height: 1),
              Expanded(child: _buildDanmaku()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResolution() {
    return Obx(() {
      final state = controller.state.value;
      final detail = state.room.detail;

      if (detail == null || detail.platform == Sites.iptvSite) {
        return const SizedBox.shrink();
      }

      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ResolutionsRow(),
      );
    });
  }

  Widget _buildDanmaku() {
    return Obx(() {
      final state = controller.state.value;

      // 与普通布局 (_buildDanmakuContent) 对齐：连接失败/未开播时
      // 房间信息已拉取成功（detail 非空），侧栏仍正常显示，不整体空掉。
      if (state.room.detail == null || controller.site == Sites.iptvSite) {
        return const SizedBox.shrink();
      }

      return const DanmakuTabView();
    });
  }

  Future<void> _togglePanel() async {
    if (_drawerController.isAnimating) return;

    if (_panelOpen) {
      await _closePanel();
    } else {
      await _openPanel();
    }
  }

  Future<void> _openPanel() async {
    _openTimer?.cancel();
    if (_panelOpen || !mounted) return;

    setState(() => _panelOpen = true);
    if (_isDesktopLayout) _startCursorWatchdog();
    await _drawerController.forward();
  }

  Future<void> _closePanel() async {
    if (!_panelOpen || _drawerController.isAnimating) return;

    _stopCursorWatchdog();
    _cancelHideTimer();
    _hideEdgeControls();

    await _drawerController.reverse();

    if (!mounted) return;

    setState(() => _panelOpen = false);
  }

  void _toggleLock() {
    setState(() => _panelLocked = !_panelLocked);
    if (_panelLocked) {
      _cancelHideTimer();
      _stopCursorWatchdog();
    } else if (_panelOpen && _isDesktopLayout) {
      _startCursorWatchdog();
    }
  }

  void _showEdgeControls() {
    if (!_edgeControlsVisible) {
      setState(() => _edgeControlsVisible = true);
    }
  }

  void _hideEdgeControls() {
    if (_edgeControlsVisible) {
      setState(() => _edgeControlsVisible = false);
    }
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _scheduleHide() {
    if (_panelLocked) return;
    _cancelHideTimer();
    _hideTimer = Timer(const Duration(milliseconds: 300), _handleHideTimer);
  }

  /// Deferred hide decision. Popups spawned from the panel (overlay dropdown
  /// menus, modal sheets, dialogs) steal the pointer from the panel's
  /// MouseRegion and fire onExit as soon as their barrier appears, so the
  /// hide must wait until every popup has closed. Re-checking inside the
  /// timer callback is race-free: popups open synchronously, long before the
  /// 300ms timer fires.
  void _handleHideTimer() {
    if (!mounted) return;
    if (_isHideBlockedByPopup) {
      _hideTimer = Timer(const Duration(milliseconds: 300), _handleHideTimer);
      return;
    }
    // 决策点地面真值：指针可能早已离开窗口（exit 事件丢失），
    // 若光标实际仍停留在面板/分隔条/边缘区内则放弃本次隐藏。
    final cursor = _probeCursorStackLocal();
    if (cursor != null && _isInsideKeepAliveRect(cursor)) return;
    _closePanel();
  }

  bool get _isHideBlockedByPopup {
    if (_openPanelPopups > 0) return true;
    final route = ModalRoute.of(context);
    return route != null && !route.isCurrent;
  }

  void _handlePanelPopupOpened() => _openPanelPopups++;

  void _handlePanelPopupClosed() {
    if (_openPanelPopups > 0) _openPanelPopups--;
  }

  /// 悬停调和：每次指针移动都以最新位置校准隐藏定时器。
  /// enter/exit 事件在指针快速划过或移出窗口时不可靠，这里按
  /// “光标在保活区内则不隐藏、在区外则计划隐藏”持续自愈。
  void _handleShellHover(PointerHoverEvent event) {
    _lastHoverLocal = event.localPosition;
    if (!_panelOpen || _panelLocked || _drawerController.isAnimating) return;
    if (_isHideBlockedByPopup) return;
    if (_isInsideKeepAliveRect(event.localPosition)) {
      // 补救丢失的 onEnter：事件丢失时残留的隐藏定时器会被取消。
      if (_hideTimer != null) _cancelHideTimer();
    } else if (_hideTimer == null) {
      // 补救丢失的 onExit：事件丢失时这里补上隐藏计划。
      _scheduleHide();
    }
  }

  /// 触发区 500ms 延迟到点：以 OS 光标位置做地面真值校验。
  /// 指针划过触发区后快速离开窗口时 onExit 会丢失，若无校验
  /// 面板会在鼠标已出窗后被误打开。
  void _handleOpenTimer() {
    _openTimer = null;
    if (!mounted) return;
    final cursor = _probeCursorStackLocal();
    if (cursor != null) {
      if (!_isInsideTriggerRect(cursor)) return;
    } else if (_lastHoverLocal != null && !_isInsideTriggerRect(_lastHoverLocal!)) {
      // 非 Windows 平台无法探测光标，退回最近一次悬停位置。
      return;
    }
    _openPanel();
  }

  void _startCursorWatchdog() {
    _cursorWatchdog?.cancel();
    _cursorWatchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _cursorWatchdogTick();
    });
  }

  void _stopCursorWatchdog() {
    _cursorWatchdog?.cancel();
    _cursorWatchdog = null;
  }

  /// 看门狗兜底：面板打开期间周期性询问 OS 光标真实位置，若光标既不在
  /// 面板也不在分隔条/边缘区（例如已移出窗口而 exit 事件丢失），则直接
  /// 关闭面板，不依赖任何事件。
  void _cursorWatchdogTick() {
    if (!mounted || !_panelOpen || _panelLocked || !_isDesktopLayout) {
      _stopCursorWatchdog();
      return;
    }
    if (_drawerController.isAnimating || _isHideBlockedByPopup) return;
    final cursor = _probeCursorStackLocal();
    if (cursor == null || _isInsideKeepAliveRect(cursor)) return;
    _closePanel();
  }

  Size _shellSize() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return Size.zero;
    return renderObject.size;
  }

  /// 面板打开期间光标允许停留（不隐藏面板）的区域：
  /// 面板本体 ∪ 6px 分隔条 ∪ 面板旁 40px 边缘控制区，以及分隔条拖拽中。
  /// 严格限制在 shell 边界内：光标越过窗口边缘（坐标出界）不算保活。
  bool _isInsideKeepAliveRect(Offset local) {
    if (_dividerHovering) return true;
    final size = _shellSize();
    if (size.isEmpty) return false;
    if (local.dx < 0 || local.dx > size.width) return false;
    if (local.dy < 0 || local.dy > size.height) return false;
    return local.dx >= size.width - _panelWidthNotifier.value - 6 - _edgeZoneWidth;
  }

  /// 触发区几何：与桌面布局中 80px 宽触发 Positioned 一致
  /// （top: 60, bottom: 100, right: 0, width: 80）。
  bool _isInsideTriggerRect(Offset local) {
    final size = _shellSize();
    if (size.isEmpty) return false;
    return local.dx >= size.width - 80 &&
        local.dx <= size.width &&
        local.dy >= 60 &&
        local.dy <= size.height - 100;
  }

  /// OS 光标位置换算到本 shell 的本地逻辑坐标；探测不可用
  /// （非 Windows 平台或探测失败）时返回 null，调用方回退事件位置。
  Offset? _probeCursorStackLocal() {
    final clientLogical = _CursorProbe.clientLogical(View.of(context).devicePixelRatio);
    if (clientLogical == null) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return clientLogical - renderObject.localToGlobal(Offset.zero);
  }
}

class _VideoHost extends StatelessWidget {
  const _VideoHost();

  @override
  Widget build(BuildContext context) {
    final shell = context.findAncestorStateOfType<_LivePlayShellState>();

    if (shell == null) {
      return const SizedBox.shrink();
    }

    return LivePlayVideo(controller: shell.controller, expandToParent: !shell.showPanel);
  }
}

/// Win32 光标探测：GetCursorPos + ScreenToClient 提供“决策点地面真值”，
/// 免疫 Flutter MouseTracker 事件丢失（指针快速移动或移出窗口边缘）。
class _CursorProbe {
  _CursorProbe._();

  // 缓存 HWND，使窗口失焦（非激活）时仍可完成 ScreenToClient 换算。
  static win32.HWND? _cachedHwnd;

  /// 光标相对窗口客户区原点的逻辑坐标；不可用时返回 null。
  static Offset? clientLogical(double devicePixelRatio) {
    if (!Platform.isWindows) return null;
    try {
      final hwnd = _resolveHwnd();
      if (hwnd == null || hwnd.isNull) return null;
      final point = ffi.calloc<win32.POINT>();
      try {
        if (!win32.GetCursorPos(point).value) return null;
        if (!win32.ScreenToClient(hwnd, point)) return null;
        return Offset(point.ref.x / devicePixelRatio, point.ref.y / devicePixelRatio);
      } finally {
        ffi.calloc.free(point);
      }
    } catch (_) {
      return null;
    }
  }

  static win32.HWND? _resolveHwnd() {
    final cached = _cachedHwnd;
    if (cached != null && !cached.isNull) return cached;
    final active = win32.GetActiveWindow();
    if (active.isNull) return cached;
    _cachedHwnd = active;
    return active;
  }
}
