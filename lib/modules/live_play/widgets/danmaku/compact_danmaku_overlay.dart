import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/utils/compact_danmaku_metrics.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/main_danmaku_metrics.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';

class CompactDanmakuOverlay extends StatelessWidget {
  const CompactDanmakuOverlay({super.key, required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final settings = SettingsService.to.danmaku;
      final enabled = settings.enablePipDanmaku.v;
      final hidden = controller.hideDanmaku.value;
      if (!enabled || hidden) {
        return const SizedBox.shrink();
      }
      return CompactDanmakuSurface(
        barrageController: controller.pipDanmakuController,
        autoScale: settings.pipDanmakuAutoScale.v,
        noEmojiMode: settings.pipDanmakuNoEmojiMode.v,
        configuredFontSize: settings.pipDanmakuFontSize.v,
        configuredFontWeight: settings.pipDanmakuFontWeight.value,
        area: settings.pipDanmakuArea.v,
        speed: settings.pipDanmakuSpeed.v,
        opacity: settings.pipDanmakuOpacity.v,
        densityMode: settings.danmakuDensityMode.v,
        fps: settings.resolvedDanmakuFps(pip: true, refreshRateMode: SettingsService.to.app.refreshRateMode),
        maxVisibleCount: settings.pipDanmakuMaxVisibleCount.v,
        emitInterval: settings.pipDanmakuEmitInterval.v,
        fontFamily: controller.danmakuFontFamilyName.value,
        showStroke: controller.enableDanmakuStroke.value,
        strokeWidth: controller.danmakuFontBorder.value,
      );
    });
  }
}

/// 不依赖 [VideoController] 的紧凑弹幕层。
///
/// 用于从房间卡片直接打开的悬浮窗：此时不存在直播播放页路由，也就没有
/// LivePlayController/VideoController。样式参数全部直接读取全局弹幕设置
/// （VideoController 上的同名字段在常规路由中也是这些设置的镜像）。
class StandaloneCompactDanmakuOverlay extends StatelessWidget {
  const StandaloneCompactDanmakuOverlay({super.key, required this.barrageController});

  final BarrageController barrageController;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final settings = SettingsService.to.danmaku;
      final enabled = settings.enablePipDanmaku.v;
      final hidden = settings.hideDanmaku.v;
      if (!enabled || hidden) {
        return const SizedBox.shrink();
      }
      return CompactDanmakuSurface(
        barrageController: barrageController,
        autoScale: settings.pipDanmakuAutoScale.v,
        noEmojiMode: settings.pipDanmakuNoEmojiMode.v,
        configuredFontSize: settings.pipDanmakuFontSize.v,
        configuredFontWeight: settings.pipDanmakuFontWeight.value,
        area: settings.pipDanmakuArea.v,
        speed: settings.pipDanmakuSpeed.v,
        opacity: settings.pipDanmakuOpacity.v,
        densityMode: settings.danmakuDensityMode.v,
        fps: settings.resolvedDanmakuFps(pip: true, refreshRateMode: SettingsService.to.app.refreshRateMode),
        maxVisibleCount: settings.pipDanmakuMaxVisibleCount.v,
        emitInterval: settings.pipDanmakuEmitInterval.v,
        fontFamily: settings.danmakuFontFamilyName.v,
        showStroke: settings.enableDanmakuStroke.v,
        strokeWidth: settings.danmakuFontBorder.v,
      );
    });
  }
}

/// 画中画/悬浮窗弹幕的共享渲染面。保持无状态：所有样式均为上层 Obx
/// 解析后的快照值，设置变化时由上层重建。
class CompactDanmakuSurface extends StatelessWidget {
  const CompactDanmakuSurface({
    super.key,
    required this.barrageController,
    required this.autoScale,
    required this.noEmojiMode,
    required this.configuredFontSize,
    required this.configuredFontWeight,
    required this.area,
    required this.speed,
    required this.opacity,
    required this.densityMode,
    required this.fps,
    required this.maxVisibleCount,
    required this.emitInterval,
    required this.fontFamily,
    required this.showStroke,
    required this.strokeWidth,
  });

  final BarrageController barrageController;
  final bool autoScale;
  final bool noEmojiMode;
  final double configuredFontSize;
  final int configuredFontWeight;
  final double area;
  final double speed;
  final double opacity;
  final int densityMode;
  final int fps;
  final int maxVisibleCount;
  final double emitInterval;
  final String fontFamily;
  final bool showStroke;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    // Keep all reactive reads in the Obx callback. LayoutBuilder executes
    // later, outside GetX dependency collection, so deferred reads would
    // leave the active PiP overlay on its previous style until another UI
    // rebuild happened.
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 350.0;
          final metrics = CompactDanmakuMetrics.resolve(
            width: width,
            autoScale: autoScale,
            configuredFontSize: configuredFontSize,
            configuredSpeed: speed,
          );
          final typography = CompactDanmakuTypography.resolve(
            configuredFontWeight: configuredFontWeight,
            configuredFontFamily: fontFamily,
            showStroke: showStroke,
            configuredStrokeWidth: strokeWidth,
          );

          return RepaintBoundary(
            child: FlameBarrageWidget(
              controller: barrageController,
              config: BarrageConfig(
                fontSize: metrics.fontSize,
                fontWeight: FontWeight(typography.fontWeight),
                fontFamily: typography.fontFamily,
                area: area,
                baseSpeed: metrics.baseSpeed,
                opacity: (opacity * MainDanmakuMetrics.resolveOpacityMultiplier(densityMode))
                    .clamp(0.0, 1.0)
                    .toDouble(),
                showStroke: typography.showStroke,
                noEmojiMode: noEmojiMode,
                strokeWidth: typography.strokeWidth,
                fps: fps,
                safeArea: false,
                trackHeight: metrics.trackHeight,
                emojiSize: metrics.emojiSize,
                maxVisibleCount: maxVisibleCount,
                maxPendingCount: 36,
                maxPendingAge: const Duration(seconds: 3),
                emitInterval: emitInterval,
                overlapSafeGap: metrics.overlapSafeGap * MainDanmakuMetrics.resolveSafeGapMultiplier(densityMode),
                allowOverlap: MainDanmakuMetrics.resolveAllowOverlap(densityMode),
                // PiP only exposes a handful of tracks. Keeping desktop-size
                // pools here retained hundreds of paragraphs/pictures after
                // an overnight compact session and made repeated PiP cycles
                // look like a leak on both Windows and Android.
                barragePoolMaxSize: 32,
                pictureCacheMaxSize: 48,
                textCacheMaxSize: 160,
              ),
              emojiAtlas: EmojiAtlas.instance,
            ),
          );
        },
      ),
    );
  }
}
