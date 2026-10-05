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

  Future<void> enterPiP(double videoRatio) {
    final activeTransition = _pipTransition;
    if (activeTransition != null) return activeTransition;
    if (currentMode == WindowLayoutMode.pip) return Future<void>.value();

    late final Future<void> transition;
    transition =
        _serializeHostOperation(() async {
          if (currentMode == WindowLayoutMode.pip) return;
          await _enterPiP(videoRatio);
        }).whenComplete(() {
          if (identical(_pipTransition, transition)) _pipTransition = null;
        });
    _pipTransition = transition;
    return transition;
  }

  Future<void> _enterPiP(double videoRatio) async {
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

    if (ratio > 1.05) {
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

    final bounds = resolveWindowsPipBounds(
      defaultSize: Size(w, h),
      primaryWorkArea: Rect.fromLTWH(safeOffset.dx, safeOffset.dy, safeSize.width, safeSize.height),
      workAreas: workAreas,
      savedBounds: savedBounds,
    );

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
