import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_presets.dart';

/// 纯色/渐变壁纸分页控制器
///
/// 数据全部编译在应用内，首次拉取返回完整列表，后续由 [ServerAllPageController]
/// 在本地切片分页，不触发网络请求。
class WallpaperColorController extends ServerAllPageController<ColorEntry> {
  static WallpaperColorController get to => Get.find<WallpaperColorController>();

  Timer? _viewportPageDebounce;

  /// 视口动态分页：每页数量 = 窗口可完整容纳的行数 × 每行列数。
  /// 防抖：窗口拖动过程中尺寸连续变化，避免频繁重切分页。
  void applyViewportPageSize(int capacity) {
    if (isClosed) return;
    final target = capacity < 10 ? 10 : capacity;
    if (pageSize.value == target) return;
    _viewportPageDebounce?.cancel();
    _viewportPageDebounce = Timer(const Duration(milliseconds: 150), () {
      if (isClosed) return;
      setPageSize(target);
    });
  }

  @override
  void onClose() {
    _viewportPageDebounce?.cancel();
    super.onClose();
  }

  @override
  Future<List<ColorEntry>> fetchAllServerData() async {
    return <ColorEntry>[
      for (final hex in kWallpaperSolidPalette) SolidEntry(hex),
      for (final g in kWallpaperGradients) GradientEntry(g),
    ];
  }

  /// 数据为编译期静态常量，刷新不需要重新拉取，仅展示短暂加载动画。
  /// 首次进入时列表为空，仍需委托父类完成真实加载。
  @override
  Future<void> refreshData() async {
    if (isClosed) return;
    if (localItemCount == 0) {
      await super.refreshData();
      return;
    }
    loadding.value = true;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (isClosed) return;
    loadding.value = false;
    easyRefreshController.finishRefresh(IndicatorResult.success);
  }
}

/// 色板条目基类
sealed class ColorEntry {
  const ColorEntry();
  ColorWallpaperData toColorData();
}

/// 纯色条目
class SolidEntry extends ColorEntry {
  const SolidEntry(this.hex);
  final String hex;

  @override
  ColorWallpaperData toColorData() => ColorWallpaperData.solid(parseHexColor(hex));
}

/// 渐变条目
class GradientEntry extends ColorEntry {
  const GradientEntry(this.gradient);
  final WallpaperGradient gradient;

  @override
  ColorWallpaperData toColorData() {
    final colors = gradient.stops.map((s) => parseHexColor(s.$1)).toList();
    return ColorWallpaperData(colors: colors, direction: degToDirection(gradient.deg));
  }
}

/// 解析 hex 颜色字符串（支持 #RRGGBB 和 #AARRGGBB）
Color parseHexColor(String hex) {
  final cleaned = hex.replaceAll('#', '');
  if (cleaned.length == 6) {
    return Color(int.parse('FF$cleaned', radix: 16));
  }
  return Color(int.parse(cleaned, radix: 16));
}

/// 将 CSS 渐变角度（0=向上，顺时针）映射到 GradientDirection 枚举
GradientDirection degToDirection(int deg) {
  final normalized = ((deg % 360) + 360) % 360;
  if (normalized >= 337.5 || normalized < 22.5) return GradientDirection.bottomToTop;
  if (normalized < 67.5) return GradientDirection.bottomRightToTopLeft;
  if (normalized < 112.5) return GradientDirection.rightToLeft;
  if (normalized < 157.5) return GradientDirection.topRightToBottomLeft;
  if (normalized < 202.5) return GradientDirection.topToBottom;
  if (normalized < 247.5) return GradientDirection.topLeftToBottomRight;
  if (normalized < 292.5) return GradientDirection.leftToRight;
  return GradientDirection.bottomLeftToTopRight;
}
