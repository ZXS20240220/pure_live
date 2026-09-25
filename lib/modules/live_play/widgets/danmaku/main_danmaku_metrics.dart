/// Geometry and density policy shared by the main video surface danmaku
/// renderer (DanmakuViewer) and the engine config pushed from VideoController.
///
/// Width-adaptive speed scales the configured px/s velocity with the surface
/// width so a message needs roughly the same time to cross windows of
/// different sizes (the same policy the PiP overlay already applies via
/// CompactDanmakuMetrics, with a main-view reference width).
///
/// Density presets mirror bilibili's "正常 / 较多 / 重叠" ladder:
///  - normal: current layout rules, lane allocation unchanged;
///  - dense:  halve the horizontal safe gap so lanes accept closer followers;
///  - overlap: dense + allow sharing lanes without clearance + reduced global
///    opacity so stacked messages stay readable.
final class MainDanmakuMetrics {
  const MainDanmakuMetrics._();

  /// Velocity reference width: at this surface width the configured speed is
  /// used verbatim; wider surfaces scale up, narrower ones scale down.
  static const double referenceWidth = 1280;

  static double resolveSpeedScale({required double width, required bool adaptive}) {
    if (!adaptive) return 1.0;
    final safeWidth = width.isFinite && width > 0 ? width : referenceWidth;
    return (safeWidth / referenceWidth).clamp(0.4, 1.5).toDouble();
  }

  /// Fixed clearance between tailgating items. The previous constant 40 px
  /// ignored the font size; small text got wasteful gaps while large text
  /// collided, so derive it from the size instead.
  static double resolveOverlapSafeGap(double fontSize) {
    return (fontSize * 1.5).clamp(16.0, 40.0).toDouble();
  }

  static double resolveSafeGapMultiplier(int densityMode) => densityMode >= 1 ? 0.5 : 1.0;

  static bool resolveAllowOverlap(int densityMode) => densityMode >= 2;

  /// Global alpha multiplier for the overlap preset so stacked lanes remain
  /// readable (bilibili dims overlapping danmaku the same way).
  static double resolveOpacityMultiplier(int densityMode) => densityMode >= 2 ? 0.55 : 1.0;
}
