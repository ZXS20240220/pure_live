import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/compact_danmaku_overlay.dart';

class LocalPlaybackDanmakuOverlay extends StatelessWidget {
  const LocalPlaybackDanmakuOverlay({super.key, required this.barrageController, required this.enabled});

  final BarrageController barrageController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.to.danmaku;
    final appSettings = SettingsService.to.app;

    return Obx(() {
      if (!enabled || settings.hideDanmaku.v || !settings.enableDanmakuDisplay.v) {
        return const SizedBox.shrink();
      }
      return CompactDanmakuSurface(
        barrageController: barrageController,
        autoScale: true,
        noEmojiMode: settings.noEmojiMode.v,
        configuredFontSize: settings.danmakuFontSize.v,
        configuredFontWeight: settings.danmakuFontWeight.v,
        area: settings.danmakuArea.v,
        speed: settings.danmakuSpeed.v,
        opacity: settings.danmakuOpacity.v,
        densityMode: settings.danmakuDensityMode.v,
        fps: settings.resolvedDanmakuFps(pip: false, refreshRateMode: appSettings.refreshRateMode),
        maxVisibleCount: settings.effectiveMaxVisibleCount,
        emitInterval: 0.05,
        fontFamily: settings.danmakuFontFamilyName.v,
        showStroke: settings.enableDanmakuStroke.v,
        strokeWidth: settings.danmakuFontBorder.v,
        letterSpacing: settings.danmakuLetterSpacing.v,
      );
    });
  }
}
