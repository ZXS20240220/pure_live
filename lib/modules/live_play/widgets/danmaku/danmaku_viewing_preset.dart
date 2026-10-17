import 'dart:convert';

class DanmakuViewingPreset {
  const DanmakuViewingPreset({
    required this.id,
    required this.labelKey,
    required this.area,
    required this.top,
    required this.bottom,
    required this.speed,
    required this.fontSize,
    required this.fontWeight,
    required this.fontBorder,
    required this.opacity,
    required this.stroke,
  });

  final String id;
  final String labelKey;
  final double area;
  final double top;
  final double bottom;
  final double speed;
  final double fontSize;
  final int fontWeight;
  final double fontBorder;
  final double opacity;
  final bool stroke;

  static const values = <DanmakuViewingPreset>[
    DanmakuViewingPreset(
      id: 'best',
      labelKey: 'danmaku_template_best',
      area: 0.20,
      top: 0,
      bottom: 0,
      speed: 118,
      fontSize: 16,
      fontWeight: 500,
      fontBorder: 1.5,
      opacity: 0.92,
      stroke: true,
    ),
    DanmakuViewingPreset(
      id: 'comfort',
      labelKey: 'danmaku_template_comfort',
      area: 0.35,
      top: 0,
      bottom: 0,
      speed: 105,
      fontSize: 17,
      fontWeight: 500,
      fontBorder: 1.5,
      opacity: 0.90,
      stroke: true,
    ),
    DanmakuViewingPreset(
      id: 'dense',
      labelKey: 'danmaku_template_dense',
      area: 0.55,
      top: 0,
      bottom: 0,
      speed: 138,
      fontSize: 15,
      fontWeight: 500,
      fontBorder: 1.2,
      opacity: 0.88,
      stroke: true,
    ),
    DanmakuViewingPreset(
      id: 'default',
      labelKey: 'reset',
      area: 1,
      top: 0,
      bottom: 0,
      speed: 120,
      fontWeight: 500,
      fontSize: 16,
      fontBorder: 1.5,
      opacity: 1,
      stroke: true,
    ),
  ];

  bool matches({
    required double area,
    required double top,
    required double bottom,
    required double speed,
    required double fontSize,
    required int fontWeight,
    required double fontBorder,
    required double opacity,
    required bool stroke,
    required bool autoFps,
  }) {
    bool close(double left, double right) => (left - right).abs() < 0.001;
    return autoFps &&
        stroke == this.stroke &&
        fontWeight == this.fontWeight &&
        close(area, this.area) &&
        close(top, this.top) &&
        close(bottom, this.bottom) &&
        close(speed, this.speed) &&
        close(fontSize, this.fontSize) &&
        close(fontBorder, this.fontBorder) &&
        close(opacity, this.opacity);
  }
}

/// A validated, transaction-ready snapshot of every danmaku setting that the
/// user can directly adjust on the live danmaku settings surface — main room
/// visual style, repeat/filter policy, tap interaction, and the entire PiP
/// danmaku sub-section. Local interaction mode and preset selection buttons
/// are intentionally excluded (those are actions, not visual values).
///
/// Decoding finishes before the settings surface mutates any Rx value. This
/// prevents a damaged saved template from applying only the fields that happen
/// to precede the malformed entry.
class DanmakuViewingTemplate {
  const DanmakuViewingTemplate({
    required this.noEmojiMode,
    required this.area,
    required this.top,
    required this.bottom,
    required this.speed,
    required this.fontSize,
    required this.fontWeight,
    required this.fontBorder,
    required this.opacity,
    required this.stroke,
    required this.fps,
    required this.autoFps,
    required this.densityMode,
    required this.widthAdaptiveSpeed,
    required this.maxVisibleCount,
    required this.massMode,
    required this.letterSpacing,
    required this.aggregateRepeatedDanmaku,
    required this.collapseRepeatedDanmaku,
    required this.repeatedDanmakuWindowSeconds,
    required this.enableDanmakuTapInteraction,
    required this.enablePipDanmaku,
    required this.pipDanmakuNoEmojiMode,
    required this.pipDanmakuAutoScale,
    required this.pipDanmakuUseOriginalColor,
    required this.pipDanmakuColor,
    required this.pipDanmakuFontSize,
    required this.pipDanmakuFontWeight,
    required this.pipDanmakuSpeed,
    required this.pipDanmakuOpacity,
    required this.pipDanmakuArea,
    required this.pipDanmakuMaxVisibleCount,
    required this.pipDanmakuEmitInterval,
    required this.pipDanmakuAutoFps,
    required this.pipDanmakuFps,
  });

  static const int schemaVersion = 3;

  final bool noEmojiMode;
  final double area;
  final double top;
  final double bottom;
  final double speed;
  final double fontSize;
  final int fontWeight;
  final double fontBorder;
  final double opacity;
  final bool stroke;
  final int fps;
  final bool autoFps;

  final int densityMode;
  final bool widthAdaptiveSpeed;
  final int maxVisibleCount;
  final bool massMode;
  final double letterSpacing;
  final bool aggregateRepeatedDanmaku;
  final bool collapseRepeatedDanmaku;
  final int repeatedDanmakuWindowSeconds;
  final bool enableDanmakuTapInteraction;

  final bool enablePipDanmaku;
  final bool pipDanmakuNoEmojiMode;
  final bool pipDanmakuAutoScale;
  final bool pipDanmakuUseOriginalColor;
  final int pipDanmakuColor;
  final double pipDanmakuFontSize;
  final int pipDanmakuFontWeight;
  final double pipDanmakuSpeed;
  final double pipDanmakuOpacity;
  final double pipDanmakuArea;
  final int pipDanmakuMaxVisibleCount;
  final double pipDanmakuEmitInterval;
  final bool pipDanmakuAutoFps;
  final int pipDanmakuFps;

  String encode() => jsonEncode({
    'version': schemaVersion,
    'noEmojiMode': noEmojiMode,
    'area': area,
    'top': top,
    'bottom': bottom,
    'speed': speed,
    'fontSize': fontSize,
    'fontWeight': fontWeight,
    'fontBorder': fontBorder,
    'opacity': opacity,
    'stroke': stroke,
    'fps': fps,
    'autoFps': autoFps,
    'densityMode': densityMode,
    'widthAdaptiveSpeed': widthAdaptiveSpeed,
    'maxVisibleCount': maxVisibleCount,
    'massMode': massMode,
    'letterSpacing': letterSpacing,
    'aggregateRepeatedDanmaku': aggregateRepeatedDanmaku,
    'collapseRepeatedDanmaku': collapseRepeatedDanmaku,
    'repeatedDanmakuWindowSeconds': repeatedDanmakuWindowSeconds,
    'enableDanmakuTapInteraction': enableDanmakuTapInteraction,
    'enablePipDanmaku': enablePipDanmaku,
    'pipDanmakuNoEmojiMode': pipDanmakuNoEmojiMode,
    'pipDanmakuAutoScale': pipDanmakuAutoScale,
    'pipDanmakuUseOriginalColor': pipDanmakuUseOriginalColor,
    'pipDanmakuColor': pipDanmakuColor,
    'pipDanmakuFontSize': pipDanmakuFontSize,
    'pipDanmakuFontWeight': pipDanmakuFontWeight,
    'pipDanmakuSpeed': pipDanmakuSpeed,
    'pipDanmakuOpacity': pipDanmakuOpacity,
    'pipDanmakuArea': pipDanmakuArea,
    'pipDanmakuMaxVisibleCount': pipDanmakuMaxVisibleCount,
    'pipDanmakuEmitInterval': pipDanmakuEmitInterval,
    'pipDanmakuAutoFps': pipDanmakuAutoFps,
    'pipDanmakuFps': pipDanmakuFps,
  });

  static DanmakuViewingTemplate? tryDecode(
    String raw, {
    required bool fallbackNoEmojiMode,
    required int fallbackFontWeight,
    required bool fallbackStroke,
    required int fallbackFps,
    required bool fallbackAutoFps,
    required int fallbackDensityMode,
    required bool fallbackWidthAdaptiveSpeed,
    required int fallbackMaxVisibleCount,
    required bool fallbackMassMode,
    required double fallbackLetterSpacing,
    required bool fallbackAggregateRepeatedDanmaku,
    required bool fallbackCollapseRepeatedDanmaku,
    required int fallbackRepeatedDanmakuWindowSeconds,
    required bool fallbackEnableDanmakuTapInteraction,
    required bool fallbackEnablePipDanmaku,
    required bool fallbackPipDanmakuNoEmojiMode,
    required bool fallbackPipDanmakuAutoScale,
    required bool fallbackPipDanmakuUseOriginalColor,
    required int fallbackPipDanmakuColor,
    required double fallbackPipDanmakuFontSize,
    required int fallbackPipDanmakuFontWeight,
    required double fallbackPipDanmakuSpeed,
    required double fallbackPipDanmakuOpacity,
    required double fallbackPipDanmakuArea,
    required int fallbackPipDanmakuMaxVisibleCount,
    required double fallbackPipDanmakuEmitInterval,
    required bool fallbackPipDanmakuAutoFps,
    required int fallbackPipDanmakuFps,
  }) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return DanmakuViewingTemplate(
        noEmojiMode: _optionalBool(decoded, 'noEmojiMode', fallbackNoEmojiMode),
        area: _requiredDouble(decoded, 'area', 0, 1),
        top: _requiredDouble(decoded, 'top', 0, 300),
        bottom: _requiredDouble(decoded, 'bottom', 0, 300),
        speed: _requiredDouble(decoded, 'speed', 20, 400),
        fontSize: _requiredDouble(decoded, 'fontSize', 10, 30),
        fontWeight: _optionalFontWeight(decoded, fallbackFontWeight),
        fontBorder: _requiredDouble(decoded, 'fontBorder', 0, 4),
        opacity: _requiredDouble(decoded, 'opacity', 0, 1),
        stroke: _optionalBool(decoded, 'stroke', fallbackStroke),
        fps: _optionalInt(decoded, 'fps', fallbackFps, 30, 240),
        autoFps: _optionalBool(decoded, 'autoFps', fallbackAutoFps),
        densityMode: _optionalInt(decoded, 'densityMode', fallbackDensityMode, 0, 2),
        widthAdaptiveSpeed: _optionalBool(decoded, 'widthAdaptiveSpeed', fallbackWidthAdaptiveSpeed),
        maxVisibleCount: _optionalInt(decoded, 'maxVisibleCount', fallbackMaxVisibleCount, 10, 200),
        massMode: _optionalBool(decoded, 'massMode', fallbackMassMode),
        letterSpacing: _optionalDouble(decoded, 'letterSpacing', fallbackLetterSpacing, -2, 8),
        aggregateRepeatedDanmaku: _optionalBool(decoded, 'aggregateRepeatedDanmaku', fallbackAggregateRepeatedDanmaku),
        collapseRepeatedDanmaku: _optionalBool(decoded, 'collapseRepeatedDanmaku', fallbackCollapseRepeatedDanmaku),
        repeatedDanmakuWindowSeconds: _optionalInt(
          decoded,
          'repeatedDanmakuWindowSeconds',
          fallbackRepeatedDanmakuWindowSeconds,
          1,
          30,
        ),
        enableDanmakuTapInteraction: _optionalBool(
          decoded,
          'enableDanmakuTapInteraction',
          fallbackEnableDanmakuTapInteraction,
        ),
        enablePipDanmaku: _optionalBool(decoded, 'enablePipDanmaku', fallbackEnablePipDanmaku),
        pipDanmakuNoEmojiMode: _optionalBool(decoded, 'pipDanmakuNoEmojiMode', fallbackPipDanmakuNoEmojiMode),
        pipDanmakuAutoScale: _optionalBool(decoded, 'pipDanmakuAutoScale', fallbackPipDanmakuAutoScale),
        pipDanmakuUseOriginalColor: _optionalBool(
          decoded,
          'pipDanmakuUseOriginalColor',
          fallbackPipDanmakuUseOriginalColor,
        ),
        pipDanmakuColor: _optionalInt(decoded, 'pipDanmakuColor', fallbackPipDanmakuColor, 0, 0xFFFFFFFF),
        pipDanmakuFontSize: _optionalDouble(decoded, 'pipDanmakuFontSize', fallbackPipDanmakuFontSize, 8, 40),
        pipDanmakuFontWeight: _optionalFontWeight(decoded, fallbackPipDanmakuFontWeight, key: 'pipDanmakuFontWeight'),
        pipDanmakuSpeed: _optionalDouble(decoded, 'pipDanmakuSpeed', fallbackPipDanmakuSpeed, 20, 400),
        pipDanmakuOpacity: _optionalDouble(decoded, 'pipDanmakuOpacity', fallbackPipDanmakuOpacity, 0.1, 1),
        pipDanmakuArea: _optionalDouble(decoded, 'pipDanmakuArea', fallbackPipDanmakuArea, 0.1, 1),
        pipDanmakuMaxVisibleCount: _optionalInt(
          decoded,
          'pipDanmakuMaxVisibleCount',
          fallbackPipDanmakuMaxVisibleCount,
          1,
          80,
        ),
        pipDanmakuEmitInterval: _optionalDouble(
          decoded,
          'pipDanmakuEmitInterval',
          fallbackPipDanmakuEmitInterval,
          0.05,
          2,
        ),
        pipDanmakuAutoFps: _optionalBool(decoded, 'pipDanmakuAutoFps', fallbackPipDanmakuAutoFps),
        pipDanmakuFps: _optionalInt(decoded, 'pipDanmakuFps', fallbackPipDanmakuFps, 15, 240),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static double _requiredDouble(Map<String, dynamic> value, String key, double min, double max) {
    final raw = value[key];
    if (raw is! num) throw FormatException('Missing numeric template field: $key');
    final result = raw.toDouble();
    if (!result.isFinite || result < min || result > max) {
      throw FormatException('Template field out of range: $key');
    }
    return result;
  }

  static double _optionalDouble(Map<String, dynamic> value, String key, double fallback, double min, double max) {
    if (!value.containsKey(key)) return fallback.clamp(min, max).toDouble();
    final raw = value[key];
    if (raw is! num || !raw.toDouble().isFinite) {
      throw FormatException('Invalid numeric template field: $key');
    }
    final result = raw.toDouble();
    if (result < min || result > max) throw FormatException('Template field out of range: $key');
    return result;
  }

  static bool _optionalBool(Map<String, dynamic> value, String key, bool fallback) {
    if (!value.containsKey(key)) return fallback;
    final raw = value[key];
    if (raw is! bool) throw FormatException('Invalid boolean template field: $key');
    return raw;
  }

  static int _optionalInt(Map<String, dynamic> value, String key, int fallback, int min, int max) {
    if (!value.containsKey(key)) return fallback.clamp(min, max).toInt();
    final raw = value[key];
    if (raw is! num || !raw.toDouble().isFinite) {
      throw FormatException('Invalid integer template field: $key');
    }
    final result = raw.toInt();
    if (raw.toDouble() != result.toDouble()) {
      throw FormatException('Non-integer template field: $key');
    }
    if (result < min || result > max) throw FormatException('Template field out of range: $key');
    return result;
  }

  static int _optionalFontWeight(Map<String, dynamic> value, int fallback, {String key = 'fontWeight'}) {
    if (!value.containsKey(key)) return _normalizeFontWeight(fallback);
    final raw = value[key];
    if (raw == null) return _normalizeFontWeight(fallback);
    if (raw is! num || !raw.toDouble().isFinite || raw.toDouble() != raw.toInt().toDouble() || raw < 100 || raw > 900) {
      throw FormatException('Invalid font-weight template field: $key');
    }
    return _normalizeFontWeight(raw.toInt());
  }

  static int _normalizeFontWeight(int value) => ((value.clamp(100, 900) / 100).round() * 100).clamp(100, 900).toInt();
}
