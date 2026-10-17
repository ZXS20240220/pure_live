import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_viewing_preset.dart';

void main() {
  test('each viewing preset only matches its actual rendered values', () {
    for (final preset in DanmakuViewingPreset.values) {
      expect(
        preset.matches(
          area: preset.area,
          top: preset.top,
          bottom: preset.bottom,
          speed: preset.speed,
          fontSize: preset.fontSize,
          fontWeight: preset.fontWeight,
          fontBorder: preset.fontBorder,
          opacity: preset.opacity,
          stroke: preset.stroke,
          autoFps: true,
        ),
        isTrue,
        reason: preset.id,
      );
      expect(
        preset.matches(
          area: preset.area + 0.01,
          top: preset.top,
          bottom: preset.bottom,
          speed: preset.speed,
          fontSize: preset.fontSize,
          fontWeight: preset.fontWeight,
          fontBorder: preset.fontBorder,
          opacity: preset.opacity,
          stroke: preset.stroke,
          autoFps: true,
        ),
        isFalse,
        reason: '${preset.id} must clear selection after manual edits',
      );
    }
  });

  test('preset selection clears when dynamic FPS is disabled', () {
    final preset = DanmakuViewingPreset.values.first;
    expect(
      preset.matches(
        area: preset.area,
        top: preset.top,
        bottom: preset.bottom,
        speed: preset.speed,
        fontSize: preset.fontSize,
        fontWeight: preset.fontWeight,
        fontBorder: preset.fontBorder,
        opacity: preset.opacity,
        stroke: preset.stroke,
        autoFps: false,
      ),
      isFalse,
    );
  });

  const fallbacks = (
    fallbackNoEmojiMode: false,
    fallbackFontWeight: 500,
    fallbackStroke: true,
    fallbackFps: 60,
    fallbackAutoFps: true,
    fallbackDensityMode: 0,
    fallbackWidthAdaptiveSpeed: true,
    fallbackMaxVisibleCount: 60,
    fallbackMassMode: false,
    fallbackLetterSpacing: 0.0,
    fallbackAggregateRepeatedDanmaku: false,
    fallbackCollapseRepeatedDanmaku: false,
    fallbackRepeatedDanmakuWindowSeconds: 5,
    fallbackEnableDanmakuTapInteraction: true,
    fallbackEnablePipDanmaku: false,
    fallbackPipDanmakuNoEmojiMode: false,
    fallbackPipDanmakuAutoScale: true,
    fallbackPipDanmakuUseOriginalColor: true,
    fallbackPipDanmakuColor: 0xFFFFFFFF,
    fallbackPipDanmakuFontSize: 14.0,
    fallbackPipDanmakuFontWeight: 500,
    fallbackPipDanmakuSpeed: 100.0,
    fallbackPipDanmakuOpacity: 0.8,
    fallbackPipDanmakuArea: 0.6,
    fallbackPipDanmakuMaxVisibleCount: 20,
    fallbackPipDanmakuEmitInterval: 0.15,
    fallbackPipDanmakuAutoFps: true,
    fallbackPipDanmakuFps: 60,
  );

  DanmakuViewingTemplate? decode(String raw) => DanmakuViewingTemplate.tryDecode(
    raw,
    fallbackNoEmojiMode: fallbacks.fallbackNoEmojiMode,
    fallbackFontWeight: fallbacks.fallbackFontWeight,
    fallbackStroke: fallbacks.fallbackStroke,
    fallbackFps: fallbacks.fallbackFps,
    fallbackAutoFps: fallbacks.fallbackAutoFps,
    fallbackDensityMode: fallbacks.fallbackDensityMode,
    fallbackWidthAdaptiveSpeed: fallbacks.fallbackWidthAdaptiveSpeed,
    fallbackMaxVisibleCount: fallbacks.fallbackMaxVisibleCount,
    fallbackMassMode: fallbacks.fallbackMassMode,
    fallbackLetterSpacing: fallbacks.fallbackLetterSpacing,
    fallbackAggregateRepeatedDanmaku: fallbacks.fallbackAggregateRepeatedDanmaku,
    fallbackCollapseRepeatedDanmaku: fallbacks.fallbackCollapseRepeatedDanmaku,
    fallbackRepeatedDanmakuWindowSeconds: fallbacks.fallbackRepeatedDanmakuWindowSeconds,
    fallbackEnableDanmakuTapInteraction: fallbacks.fallbackEnableDanmakuTapInteraction,
    fallbackEnablePipDanmaku: fallbacks.fallbackEnablePipDanmaku,
    fallbackPipDanmakuNoEmojiMode: fallbacks.fallbackPipDanmakuNoEmojiMode,
    fallbackPipDanmakuAutoScale: fallbacks.fallbackPipDanmakuAutoScale,
    fallbackPipDanmakuUseOriginalColor: fallbacks.fallbackPipDanmakuUseOriginalColor,
    fallbackPipDanmakuColor: fallbacks.fallbackPipDanmakuColor,
    fallbackPipDanmakuFontSize: fallbacks.fallbackPipDanmakuFontSize,
    fallbackPipDanmakuFontWeight: fallbacks.fallbackPipDanmakuFontWeight,
    fallbackPipDanmakuSpeed: fallbacks.fallbackPipDanmakuSpeed,
    fallbackPipDanmakuOpacity: fallbacks.fallbackPipDanmakuOpacity,
    fallbackPipDanmakuArea: fallbacks.fallbackPipDanmakuArea,
    fallbackPipDanmakuMaxVisibleCount: fallbacks.fallbackPipDanmakuMaxVisibleCount,
    fallbackPipDanmakuEmitInterval: fallbacks.fallbackPipDanmakuEmitInterval,
    fallbackPipDanmakuAutoFps: fallbacks.fallbackPipDanmakuAutoFps,
    fallbackPipDanmakuFps: fallbacks.fallbackPipDanmakuFps,
  );

  test('saved viewing template round trips all main-room and pip fields', () {
    const template = DanmakuViewingTemplate(
      noEmojiMode: true,
      area: 0.42,
      top: 12,
      bottom: 34,
      speed: 180,
      fontSize: 21,
      fontWeight: 700,
      fontBorder: 2.5,
      opacity: 0.64,
      stroke: false,
      fps: 144,
      autoFps: false,
      densityMode: 1,
      widthAdaptiveSpeed: false,
      maxVisibleCount: 120,
      massMode: true,
      letterSpacing: 1.5,
      aggregateRepeatedDanmaku: true,
      collapseRepeatedDanmaku: false,
      repeatedDanmakuWindowSeconds: 12,
      enableDanmakuTapInteraction: false,
      enablePipDanmaku: true,
      pipDanmakuNoEmojiMode: true,
      pipDanmakuAutoScale: false,
      pipDanmakuUseOriginalColor: false,
      pipDanmakuColor: 0xFF00A0FF,
      pipDanmakuFontSize: 18.5,
      pipDanmakuFontWeight: 600,
      pipDanmakuSpeed: 150,
      pipDanmakuOpacity: 0.55,
      pipDanmakuArea: 0.75,
      pipDanmakuMaxVisibleCount: 40,
      pipDanmakuEmitInterval: 0.35,
      pipDanmakuAutoFps: false,
      pipDanmakuFps: 90,
    );

    final decoded = decode(template.encode());

    expect(decoded, isNotNull);
    expect(decoded!.noEmojiMode, isTrue);
    expect(decoded.area, 0.42);
    expect(decoded.top, 12);
    expect(decoded.bottom, 34);
    expect(decoded.speed, 180);
    expect(decoded.fontSize, 21);
    expect(decoded.fontWeight, 700);
    expect(decoded.fontBorder, 2.5);
    expect(decoded.opacity, 0.64);
    expect(decoded.stroke, isFalse);
    expect(decoded.fps, 144);
    expect(decoded.autoFps, isFalse);
    expect(decoded.densityMode, 1);
    expect(decoded.widthAdaptiveSpeed, isFalse);
    expect(decoded.maxVisibleCount, 120);
    expect(decoded.massMode, isTrue);
    expect(decoded.letterSpacing, 1.5);
    expect(decoded.aggregateRepeatedDanmaku, isTrue);
    expect(decoded.collapseRepeatedDanmaku, isFalse);
    expect(decoded.repeatedDanmakuWindowSeconds, 12);
    expect(decoded.enableDanmakuTapInteraction, isFalse);
    expect(decoded.enablePipDanmaku, isTrue);
    expect(decoded.pipDanmakuNoEmojiMode, isTrue);
    expect(decoded.pipDanmakuAutoScale, isFalse);
    expect(decoded.pipDanmakuUseOriginalColor, isFalse);
    expect(decoded.pipDanmakuColor, 0xFF00A0FF);
    expect(decoded.pipDanmakuFontSize, 18.5);
    expect(decoded.pipDanmakuFontWeight, 600);
    expect(decoded.pipDanmakuSpeed, 150);
    expect(decoded.pipDanmakuOpacity, 0.55);
    expect(decoded.pipDanmakuArea, 0.75);
    expect(decoded.pipDanmakuMaxVisibleCount, 40);
    expect(decoded.pipDanmakuEmitInterval, 0.35);
    expect(decoded.pipDanmakuAutoFps, isFalse);
    expect(decoded.pipDanmakuFps, 90);
  });

  test('legacy template preserves fields that were not stored yet', () {
    final decoded = decode(
      '{"area":0.2,"top":0,"bottom":0,"speed":118,"fontSize":16,'
      '"fontBorder":1.5,"opacity":0.92}',
    );

    expect(decoded, isNotNull);
    expect(decoded!.noEmojiMode, fallbacks.fallbackNoEmojiMode);
    expect(decoded.fontWeight, fallbacks.fallbackFontWeight);
    expect(decoded.stroke, fallbacks.fallbackStroke);
    expect(decoded.fps, fallbacks.fallbackFps);
    expect(decoded.autoFps, fallbacks.fallbackAutoFps);
    expect(decoded.densityMode, fallbacks.fallbackDensityMode);
    expect(decoded.widthAdaptiveSpeed, fallbacks.fallbackWidthAdaptiveSpeed);
    expect(decoded.maxVisibleCount, fallbacks.fallbackMaxVisibleCount);
    expect(decoded.massMode, fallbacks.fallbackMassMode);
    expect(decoded.letterSpacing, fallbacks.fallbackLetterSpacing);
    expect(decoded.enablePipDanmaku, fallbacks.fallbackEnablePipDanmaku);
    expect(decoded.pipDanmakuFps, fallbacks.fallbackPipDanmakuFps);
  });

  test('malformed and out-of-range templates are rejected as a whole', () {
    expect(
      decode(
        '{"area":0.2,"top":0,"bottom":0,"speed":118,"fontSize":16,'
        '"fontBorder":1.5,"opacity":"bad"}',
      ),
      isNull,
    );
    expect(
      decode(
        '{"area":0.2,"top":0,"bottom":0,"speed":999,"fontSize":16,'
        '"fontBorder":1.5,"opacity":0.9}',
      ),
      isNull,
    );
    expect(
      decode(
        '{"area":0.2,"top":0,"bottom":0,"speed":118,"fontSize":16,'
        '"fontBorder":1.5,"opacity":0.9,"fps":59.5}',
      ),
      isNull,
    );
    expect(decode('[1,2,3]'), isNull);
    expect(
      decode(
        '{"area":0.2,"top":0,"bottom":0,"speed":118,"fontSize":16,'
        '"fontBorder":1.5,"opacity":0.9,"densityMode":99}',
      ),
      isNull,
    );
    expect(
      decode(
        '{"area":0.2,"top":0,"bottom":0,"speed":118,"fontSize":16,'
        '"fontBorder":1.5,"opacity":0.9,"pipDanmakuOpacity":2.5}',
      ),
      isNull,
    );
  });
}
