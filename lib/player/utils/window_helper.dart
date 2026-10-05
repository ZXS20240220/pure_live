import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/services/settings/window_size_controller.dart';

enum WindowLayoutMode { normal, pip }

@immutable
class WindowsPipDisplay {
  const WindowsPipDisplay({required this.id, required this.size, this.visiblePosition, this.visibleSize});

  factory WindowsPipDisplay.fromDisplay(Display display) {
    return WindowsPipDisplay(
      id: display.id,
      size: display.size,
      visiblePosition: display.visiblePosition,
      visibleSize: display.visibleSize,
    );
  }

  final String id;
  final Size size;
  final Offset? visiblePosition;
  final Size? visibleSize;
}

@immutable
class WindowsPipPreferences {
  const WindowsPipPreferences({
    required this.rememberPosition,
    required this.alwaysOnTop,
    required this.savedDisplayId,
    this.savedBounds,
  });

  final bool rememberPosition;
  final bool alwaysOnTop;
  final String savedDisplayId;
  final Rect? savedBounds;
}

class WindowsPipHost {
  const WindowsPipHost({
    required this.getSize,
    required this.getPosition,
    required this.isAlwaysOnTop,
    required this.isMinimized,
    required this.isMaximized,
    required this.isFullScreen,
    required this.getDisplays,
    required this.getPrimaryDisplay,
    required this.setAlwaysOnTop,
    required this.setMinimumSize,
    required this.setSize,
    required this.setPosition,
    required this.setAspectRatio,
  });

  factory WindowsPipHost.system() {
    return WindowsPipHost(
      getSize: windowManager.getSize,
      getPosition: windowManager.getPosition,
      isAlwaysOnTop: windowManager.isAlwaysOnTop,
      isMinimized: windowManager.isMinimized,
      isMaximized: windowManager.isMaximized,
      isFullScreen: windowManager.isFullScreen,
      getDisplays: () async =>
          (await screenRetriever.getAllDisplays()).map(WindowsPipDisplay.fromDisplay).toList(growable: false),
      getPrimaryDisplay: () async => WindowsPipDisplay.fromDisplay(await screenRetriever.getPrimaryDisplay()),
      setAlwaysOnTop: windowManager.setAlwaysOnTop,
      setMinimumSize: windowManager.setMinimumSize,
      setSize: windowManager.setSize,
      setPosition: windowManager.setPosition,
      setAspectRatio: windowManager.setAspectRatio,
    );
  }

  final Future<Size> Function() getSize;
  final Future<Offset> Function() getPosition;
  final Future<bool> Function() isAlwaysOnTop;
  final Future<bool> Function() isMinimized;
  final Future<bool> Function() isMaximized;
  final Future<bool> Function() isFullScreen;
  final Future<List<WindowsPipDisplay>> Function() getDisplays;
  final Future<WindowsPipDisplay> Function() getPrimaryDisplay;
  final Future<void> Function(bool value) setAlwaysOnTop;
  final Future<void> Function(Size size) setMinimumSize;
  final Future<void> Function(Size size) setSize;
  final Future<void> Function(Offset position) setPosition;
  final Future<void> Function(double aspectRatio) setAspectRatio;
}

typedef WindowsPipPreferencesReader = WindowsPipPreferences Function();
typedef WindowsPipGeometryWriter = void Function(Size size, Offset position, String displayId);
typedef WindowsNormalWindowSizeWriter = void Function(Size size);

WindowsPipPreferences _readWindowsPipPreferences() {
  final windowSettings = SettingsService.to.window;
  final pip = windowSettings.windowsPip;
  return WindowsPipPreferences(
    rememberPosition: windowSettings.rememberPipPosition.value,
    alwaysOnTop: SettingsService.to.player.windowsPipAlwaysOnTop.value,
    savedDisplayId: pip.displayId.value,
    savedBounds: pip.hasValidBounds
        ? Rect.fromLTWH(
            pip.windowsPipX.value,
            pip.windowsPipY.value,
            pip.windowsPipWidth.value,
            pip.windowsPipHeight.value,
          )
        : null,
  );
}

void _writeWindowsPipGeometry(Size size, Offset position, String displayId) {
  SettingsService.to.window.windowsPip.update(size, position, displayId);
}

/// Smallest user-resizable PiP window for a given content aspect ratio.
/// Uses the same 350 long-edge ladder as the in-app floating window so manual
/// dragging cannot shrink a Windows mini player below the compact baseline.
@visibleForTesting
Size resolveWindowsPipMinSize(double aspectRatio) {
  const minLongEdge = 350.0;
  const minShortEdge = 120.0;
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  if (ratio >= 1) return Size(minLongEdge, minLongEdge / ratio);
  var height = minLongEdge * 1.2;
  var width = height * ratio;
  if (width < minShortEdge) {
    width = minShortEdge;
    height = width / ratio;
  }
  return Size(width, height);
}

@visibleForTesting
Rect resolveWindowsPipBounds({
  required Size defaultSize,
  required Rect primaryWorkArea,
  required List<Rect> workAreas,
  Rect? savedBounds,
}) {
  final availableAreas = workAreas.where((area) => !area.isEmpty && area.isFinite).toList(growable: false);

  final fallbackArea = primaryWorkArea.isEmpty ? const Rect.fromLTWH(0, 0, 1280, 720) : primaryWorkArea;

  final areas = availableAreas.isEmpty ? <Rect>[fallbackArea] : availableAreas;

  final validSavedBounds = savedBounds != null && savedBounds.isFinite && !savedBounds.isEmpty ? savedBounds : null;

  Rect? targetArea;

  if (validSavedBounds != null) {
    for (final area in areas) {
      final overlap = validSavedBounds.intersect(area);

      if (overlap.width >= 48 && overlap.height >= 48) {
        targetArea = area;
        break;
      }
    }
  }

  targetArea ??= areas.firstWhere(
    (area) => area.overlaps(fallbackArea) || area.contains(fallbackArea.center),
    orElse: () => areas.first,
  );

  final requested = validSavedBounds?.size ?? defaultSize;

  final minWidth = targetArea.width < 140 ? targetArea.width : 140.0;
  final minHeight = targetArea.height < 90 ? targetArea.height : 90.0;

  final width = requested.width.clamp(minWidth, targetArea.width).toDouble();

  final height = requested.height.clamp(minHeight, targetArea.height).toDouble();

  final defaultLeft = targetArea.right - width - 20;
  final defaultTop = targetArea.bottom - height - 20;

  final left = (validSavedBounds?.left ?? defaultLeft).clamp(targetArea.left, targetArea.right - width).toDouble();

  final top = (validSavedBounds?.top ?? defaultTop).clamp(targetArea.top, targetArea.bottom - height).toDouble();

  return Rect.fromLTWH(left, top, width, height);
}

/// 根据视频实际像素尺寸计算宽高比完全一致的整数窗口尺寸。
///
/// 原生窗口尺寸必须为整数像素；若按浮点比例乘出再取整，宽高比会有 1px 级
/// 偏差，BoxFit.contain 下出现细黑边。这里用 GCD 将视频尺寸约分到最简比，
/// 再按目标长边取整数倍，保证窗口比例与视频逐像素一致。
@visibleForTesting
({int width, int height}) exactIntegerSizeForRatio({
  required int videoWidth,
  required int videoHeight,
  required double targetLongSide,
}) {
  if (videoWidth <= 0 || videoHeight <= 0) {
    return (width: 160, height: 90);
  }
  var a = videoWidth;
  var b = videoHeight;
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  final gcd = a;
  final baseW = videoWidth ~/ gcd;
  final baseH = videoHeight ~/ gcd;
  final longBase = baseW >= baseH ? baseW : baseH;
  final safeTarget = targetLongSide > 0 ? targetLongSide : 360.0;
  final k = (safeTarget / longBase).round().clamp(1, 1 << 20);
  return (width: baseW * k, height: baseH * k);
}

class WindowHelper {
  static final WindowHelper instance = WindowHelper._internal();

  WindowHelper._internal()
    : this._withDependencies(
        WindowsPipHost.system(),
        _readWindowsPipPreferences,
        _writeWindowsPipGeometry,
        Platform.isWindows,
      );

  @visibleForTesting
  factory WindowHelper.test({
    required WindowsPipHost host,
    required WindowsPipPreferencesReader readPreferences,
    WindowsPipGeometryWriter? writeGeometry,
    bool isWindows = true,
  }) {
    return WindowHelper._withDependencies(host, readPreferences, writeGeometry ?? ((_, _, _) {}), isWindows);
  }

  WindowHelper._withDependencies(this._host, this._readPreferences, this._writeGeometry, this._isWindows);

  final WindowsPipHost _host;
  final WindowsPipPreferencesReader _readPreferences;
  final WindowsPipGeometryWriter _writeGeometry;
  final bool _isWindows;

  final Size defaultSize = const Size(1280, 720);

  WindowLayoutMode currentMode = WindowLayoutMode.normal;

  Size _savedSize = const Size(1280, 720);
  Offset _savedPosition = Offset.zero;
  bool _savedAlwaysOnTop = false;
  Future<void> _hostQueue = Future<void>.value();
  Future<void>? _pipTransition;

  /// 当前 PiP 窗口锁定的宽高比；非 PiP 模式下为 null。
  double? _pipAspectRatio;

  Future<void> togglePiP(double videoRatio) async {
    if (!_isWindows) return;

    if (currentMode == WindowLayoutMode.normal) {
      await enterPiP(videoRatio);
    } else {
      await exitPiP();
    }
  }

  Future<void> enterPiP(double videoRatio, {int? videoWidth, int? videoHeight}) {
    final activeTransition = _pipTransition;
    if (activeTransition != null) return activeTransition;
    if (currentMode == WindowLayoutMode.pip) return Future<void>.value();

    late final Future<void> transition;
    transition =
        _serializeHostOperation(() async {
          if (currentMode == WindowLayoutMode.pip) return;
          await _enterPiP(videoRatio, videoWidth: videoWidth, videoHeight: videoHeight);
        }).whenComplete(() {
          if (identical(_pipTransition, transition)) _pipTransition = null;
        });
    _pipTransition = transition;
    return transition;
  }

  Future<void> _enterPiP(double videoRatio, {int? videoWidth, int? videoHeight}) async {
    final normalSize = await _host.getSize();
    final normalPosition = await _host.getPosition();
    final normalAlwaysOnTop = await _host.isAlwaysOnTop();

    final displays = await _host.getDisplays();

    final primaryDisplay = await _host.getPrimaryDisplay();

    final currentDisplay = _findDisplayForPosition(displays, normalPosition) ?? primaryDisplay;

    final safeSize = currentDisplay.visibleSize ?? currentDisplay.size;

    final safeOffset = currentDisplay.visiblePosition ?? Offset.zero;

    final ratio = videoRatio.isFinite && videoRatio > 0 ? videoRatio : 16 / 9;

    double w;
    double h;

    // 优先用视频实际像素尺寸通过 GCD 约分，得到宽高比完全一致的整数窗口尺寸。
    // 原生窗口尺寸必须为整数像素，若直接用浮点比例乘出再取整，会产生 1px 级
    // 比例偏差，BoxFit.contain 下表现为上下/左右细黑边。
    final hasExactDims = videoWidth != null && videoHeight != null && videoWidth > 0 && videoHeight > 0;
    if (hasExactDims) {
      final exact = exactIntegerSizeForRatio(
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        targetLongSide: ratio >= 1 ? 360.0 : 380.0,
      );
      w = exact.width.toDouble();
      h = exact.height.toDouble();
    } else if (ratio > 1.05) {
      const maxSide = 360.0;

      w = maxSide;
      h = maxSide / ratio;
    } else if (ratio < 0.95) {
      const maxSide = 380.0;

      h = maxSide;
      w = h * ratio;

      if (w < 140) {
        w = 140;
        h = w / ratio;
      }
    } else {
      const maxSide = 280.0;

      if (ratio >= 1.0) {
        w = maxSide;
        h = maxSide / ratio;
      } else {
        h = maxSide;
        w = h * ratio;
      }
    }

    final preferences = _readPreferences();
    final rememberPosition = preferences.rememberPosition;

    Rect? savedBounds;

    final savedDisplayMatches = preferences.savedDisplayId.isEmpty || preferences.savedDisplayId == currentDisplay.id;

    if (rememberPosition && preferences.savedBounds != null && savedDisplayMatches) {
      savedBounds = preferences.savedBounds;
    }

    final workAreas = displays
        .map((display) {
          final size = display.visibleSize ?? display.size;

          final position = display.visiblePosition ?? Offset.zero;

          return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
        })
        .toList(growable: false);

    var bounds = resolveWindowsPipBounds(
      defaultSize: Size(w, h),
      primaryWorkArea: Rect.fromLTWH(safeOffset.dx, safeOffset.dy, safeSize.width, safeSize.height),
      workAreas: workAreas,
      savedBounds: savedBounds,
    );

    // 保存的窗口尺寸可能来自上一次不同比例的会话（如横屏直播保存后，
    // 竖屏直播再次进入）。若沿用旧尺寸会导致画面比例错乱（横屏窗口
    // 播放竖屏视频）。此时用当前视频比例重算尺寸，保留保存的左上角位置。
    final boundsRatio = bounds.height > 0 ? bounds.width / bounds.height : ratio;
    if ((boundsRatio - ratio).abs() > 0.05) {
      // 按当前视频比例的精确整数尺寸（已在上方通过 GCD 计算）。
      final ratioWidth = w;
      final ratioHeight = h;
      // 找到包含该窗口左上角的工作区，用于钳制尺寸与位置避免超出屏幕。
      var areaLeft = safeOffset.dx;
      var areaTop = safeOffset.dy;
      var areaWidth = safeSize.width;
      var areaHeight = safeSize.height;
      for (final area in workAreas) {
        if (bounds.left >= area.left &&
            bounds.left < area.right &&
            bounds.top >= area.top &&
            bounds.top < area.bottom) {
          areaLeft = area.left;
          areaTop = area.top;
          areaWidth = area.width;
          areaHeight = area.height;
          break;
        }
      }
      final clampedWidth = ratioWidth.clamp(0.0, areaWidth).toDouble();
      final clampedHeight = ratioHeight.clamp(0.0, areaHeight).toDouble();
      final clampedLeft = bounds.left.clamp(areaLeft, areaLeft + areaWidth - clampedWidth).toDouble();
      final clampedTop = bounds.top.clamp(areaTop, areaTop + areaHeight - clampedHeight).toDouble();
      bounds = Rect.fromLTWH(clampedLeft, clampedTop, clampedWidth, clampedHeight);
    }

    // A remembered size from an older release (or the square-entry branch)
    // can be smaller than the compact baseline; enlarge it when applying so
    // neither entry nor later manual resizing can break the floor.
    final pipMinSize = resolveWindowsPipMinSize(ratio);
    final effectiveSize = Size(
      bounds.width < pipMinSize.width ? pipMinSize.width : bounds.width,
      bounds.height < pipMinSize.height ? pipMinSize.height : bounds.height,
    );

    try {
      await _host.setAlwaysOnTop(preferences.alwaysOnTop);
      await _host.setMinimumSize(pipMinSize);
      await _host.setSize(effectiveSize);
      await _host.setPosition(bounds.topLeft);
      // 锁定窗口宽高比，使拖拽边缘调整大小时保持画面比例（0 表示不约束）。
      await _host.setAspectRatio(ratio);

      if (rememberPosition) {
        final resolvedDisplay = _findDisplayForPosition(displays, bounds.topLeft) ?? currentDisplay;
        _writeGeometry(effectiveSize, bounds.topLeft, resolvedDisplay.id);
      }
    } catch (error, stackTrace) {
      await _restoreHostWindow(
        alwaysOnTop: normalAlwaysOnTop,
        minimumSize: const Size(WindowSizeController.minWindowWidth, WindowSizeController.minWindowHeight),
        size: normalSize,
        position: normalPosition,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }

    _savedSize = normalSize;
    _savedPosition = normalPosition;
    _savedAlwaysOnTop = normalAlwaysOnTop;
    _pipAspectRatio = ratio;
    currentMode = WindowLayoutMode.pip;
  }

  Future<void> exitPiP() {
    final activeTransition = _pipTransition;
    if (activeTransition != null) return activeTransition;
    if (currentMode == WindowLayoutMode.normal) return Future<void>.value();

    late final Future<void> transition;
    transition =
        _serializeHostOperation(() async {
          if (currentMode == WindowLayoutMode.normal) return;
          await _exitPiP();
        }).whenComplete(() {
          if (identical(_pipTransition, transition)) _pipTransition = null;
        });
    _pipTransition = transition;
    return transition;
  }

  Future<void> _exitPiP() async {
    final pipSize = await _host.getSize();
    final pipPosition = await _host.getPosition();
    final pipAlwaysOnTop = await _host.isAlwaysOnTop();

    try {
      // 恢复进入 PiP 前的窗口置顶状态（可能是直播间播放页的置顶开关），
      // 而非强制关闭，避免退出小窗后丢失用户的置顶偏好。
      await _host.setAlwaysOnTop(_savedAlwaysOnTop);
      await _host.setMinimumSize(const Size(WindowSizeController.minWindowWidth, WindowSizeController.minWindowHeight));
      await _host.setSize(_savedSize);
      await _host.setPosition(_savedPosition);
      // 退出 PiP 后解除宽高比锁定，恢复普通窗口的自由缩放。
      await _host.setAspectRatio(0);
    } catch (error, stackTrace) {
      await _restoreHostWindow(
        alwaysOnTop: pipAlwaysOnTop,
        minimumSize: Size.zero,
        size: pipSize,
        position: pipPosition,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }

    _pipAspectRatio = null;
    currentMode = WindowLayoutMode.normal;
  }

  Future<void> setPiPAlwaysOnTop(bool value) {
    if (!_isWindows || currentMode != WindowLayoutMode.pip) {
      return Future<void>.value();
    }

    return _serializeHostOperation(() async {
      if (currentMode != WindowLayoutMode.pip) return;
      await _host.setAlwaysOnTop(value);
    });
  }

  /// 运行时更新 PiP 窗口的宽高比锁定（例如切换为竖屏直播流时）。
  /// 仅在 PiP 模式下生效；ratio 非法时回退到 16:9。
  Future<void> updatePiPAspectRatio(double videoRatio) {
    if (!_isWindows || currentMode != WindowLayoutMode.pip) {
      return Future<void>.value();
    }
    final ratio = videoRatio.isFinite && videoRatio > 0 ? videoRatio : 16 / 9;
    return _serializeHostOperation(() async {
      if (currentMode != WindowLayoutMode.pip) return;
      if ((_pipAspectRatio ?? 0) == ratio) return;
      await _host.setAspectRatio(ratio);
      // setAspectRatio 仅锁定比例不立即改尺寸；若视频比例切换（如横→竖），
      // 必须同步调整窗口大小，否则旧比例窗口内会出现黑边。保持长边不变。
      final currentSize = await _host.getSize();
      final longSide = currentSize.width > currentSize.height ? currentSize.width : currentSize.height;
      final newWidth = ratio >= 1.0 ? longSide : longSide * ratio;
      final newHeight = ratio >= 1.0 ? longSide / ratio : longSide;
      await _host.setSize(Size(newWidth, newHeight));
      _pipAspectRatio = ratio;
    });
  }

  Future<void> capturePiPGeometry() {
    if (!_isWindows || currentMode != WindowLayoutMode.pip) {
      return Future<void>.value();
    }

    return _serializeHostOperation(_capturePiPGeometry);
  }

  Future<void> captureWindowGeometry(WindowsNormalWindowSizeWriter writeNormalSize) {
    if (!_isWindows) return Future<void>.value();

    return _serializeHostOperation(() async {
      if (currentMode == WindowLayoutMode.pip) {
        await _capturePiPGeometry();
        return;
      }

      if (!await _isRestorableNormalWindow()) return;
      final size = await _host.getSize();
      if (currentMode != WindowLayoutMode.normal || !await _isRestorableNormalWindow()) return;
      writeNormalSize(size);
    });
  }

  Future<void> _capturePiPGeometry() async {
    if (currentMode != WindowLayoutMode.pip) return;
    final preferences = _readPreferences();

    if (!preferences.rememberPosition) return;

    final size = await _host.getSize();
    final position = await _host.getPosition();

    final displays = await _host.getDisplays();

    final display = _findDisplayForPosition(displays, position) ?? await _host.getPrimaryDisplay();

    if (currentMode == WindowLayoutMode.pip) {
      _writeGeometry(size, position, display.id);
    }
  }

  Future<bool> _isRestorableNormalWindow() async {
    if (await _host.isMinimized()) return false;
    if (await _host.isMaximized()) return false;
    return !await _host.isFullScreen();
  }

  Future<void> _serializeHostOperation(Future<void> Function() operation) {
    final result = _hostQueue.then((_) => operation());
    _hostQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _restoreHostWindow({
    required bool alwaysOnTop,
    required Size minimumSize,
    required Size size,
    required Offset position,
  }) async {
    final restoreOperations = <Future<void> Function()>[
      () => _host.setMinimumSize(minimumSize),
      () => _host.setSize(size),
      () => _host.setPosition(position),
      () => _host.setAlwaysOnTop(alwaysOnTop),
      // 回滚时一并解除宽高比锁定，避免约束泄漏到普通窗口。
      () => _host.setAspectRatio(0),
    ];
    for (final restore in restoreOperations) {
      try {
        await restore();
      } catch (error, stackTrace) {
        debugPrint('Windows PiP host rollback step failed: $error\n$stackTrace');
      }
    }
  }

  WindowsPipDisplay? _findDisplayForPosition(List<WindowsPipDisplay> displays, Offset position) {
    for (final display in displays) {
      final offset = display.visiblePosition ?? Offset.zero;

      final size = display.visibleSize ?? display.size;

      final right = offset.dx + size.width;
      final bottom = offset.dy + size.height;

      if (position.dx >= offset.dx && position.dx < right && position.dy >= offset.dy && position.dy < bottom) {
        return display;
      }
    }

    for (final display in displays) {
      final offset = display.visiblePosition ?? Offset.zero;

      final size = display.visibleSize ?? display.size;

      final right = offset.dx + size.width;
      final bottom = offset.dy + size.height;

      if (position.dx < right && position.dx + 1 > offset.dx && position.dy < bottom && position.dy + 1 > offset.dy) {
        return display;
      }
    }

    return null;
  }
}
