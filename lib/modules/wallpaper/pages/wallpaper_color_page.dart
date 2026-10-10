import 'dart:math' as math;

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_color_controller.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';

/// 纯色渐变壁纸选择页
///
/// 复用项目统一的分页骨架：桌面端显示页码分页条，移动端下拉刷新，
/// 鼠标拖拽可滚动内容，页码区域支持滚轮翻页。
class WallpaperColorPage extends StatefulWidget {
  const WallpaperColorPage({super.key});

  @override
  State<WallpaperColorPage> createState() => _WallpaperColorPageState();
}

class _WallpaperColorPageState extends State<WallpaperColorPage> {
  late final WallpaperColorController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(WallpaperColorController());
    controller.refreshData();
  }

  @override
  void dispose() {
    Get.delete<WallpaperColorController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: SettingsCrumbs.wallpaperColor)),
      body: BasePageView<WallpaperColorController, ColorEntry>(
        controller: controller,
        enableRefresh: true,
        enableLoadMore: true,
        wrapMobileRefresh: false,
        showScrollToTopBtn: false,
        showPageSizeSelector: false,
        showGotoButton: false,
        customDesktopBottomPadding: 135,
        customMobileBottomPadding: 85,
        pageSizeOptions: SettingsService.to.page.pageSizeOptions,
        emptyBuilder: (context) => const EmptyView(icon: Icons.palette_outlined, title: '暂无色板', subtitle: ''),
        contentBuilder: (context, displayList, scrollController) {
          return buildCommonPullToRefresh(
            context: context,
            refreshKey: 'wallpaper_color_grid',
            onRefresh: controller.refreshData,
            controller: controller.easyRefreshController,
            childBuilder: (_, physics) => _buildColorGrid(displayList, scrollController, physics),
          );
        },
      ),
    );
  }

  Widget _buildColorGrid(List<ColorEntry> displayList, ScrollController scrollController, ScrollPhysics? physics) {
    return LayoutBuilder(
      builder: (context, constraint) {
        const crossAxisExtent = 220.0;
        const crossAxisSpacing = 10.0;
        const mainAxisSpacing = 10.0;

        final width = constraint.maxWidth;
        final crossAxisCount = math.max(1, ((width - 12) / (crossAxisExtent + crossAxisSpacing)).ceil());

        final itemWidth = (width - 12 - crossAxisSpacing * (crossAxisCount - 1)) / crossAxisCount;
        final mainAxisExtent = itemWidth / 1.62;

        final rowExtent = mainAxisExtent + mainAxisSpacing;
        final rows = ((constraint.maxHeight - 10 + mainAxisSpacing) / rowExtent).floor();
        controller.applyViewportPageSize(rows.clamp(1, 999) * crossAxisCount);

        return ScrollConfiguration(
          behavior: const MouseDraggableScrollBehavior(),
          child: GridView.builder(
            key: const PageStorageKey('wallpaper_color_grid'),
            controller: scrollController,
            physics: physics,
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: crossAxisSpacing,
              mainAxisSpacing: mainAxisSpacing,
              mainAxisExtent: mainAxisExtent,
            ),
            itemCount: displayList.length,
            itemBuilder: (context, index) {
              final entry = displayList[index];
              return _ColorTile(entry: entry, onTap: () => _apply(entry));
            },
          ),
        );
      },
    );
  }

  Future<void> _apply(ColorEntry entry) async {
    await WallpaperSettingsController.to.applyColorWallpaper(entry.toColorData());
    SmartDialog.showToast('已设为壁纸');
  }
}

/// 颜色色块组件
class _ColorTile extends StatelessWidget {
  const _ColorTile({required this.entry, required this.onTap});

  final ColorEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: entry is GradientEntry ? _buildGradient(entry as GradientEntry) : null,
            color: entry is SolidEntry ? parseHexColor((entry as SolidEntry).hex) : null,
          ),
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.all(8),
          child: _StrokedLabel(
            entry is SolidEntry ? (entry as SolidEntry).hex : (entry as GradientEntry).gradient.name,
          ),
        ),
      ),
    );
  }

  Gradient? _buildGradient(GradientEntry entry) {
    final g = entry.gradient;
    final colors = g.stops.map((s) => parseHexColor(s.$1)).toList();
    final stops = g.stops.map((s) => s.$2 / 100.0).toList();
    final (begin, end) = _degToAlignment(g.deg);
    return LinearGradient(colors: colors, stops: stops, begin: begin, end: end);
  }

  /// 统一标签样式：白色字体 + 黑色描边 + 阴影，确保在任意底色上可读
  static const TextStyle _fillStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    shadows: <Shadow>[Shadow(color: Colors.black54, offset: Offset(1, 1), blurRadius: 2)],
  );

  static final Paint _strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeJoin = StrokeJoin.round
    ..color = Colors.black;
}

/// 带黑色描边的白色标签文字：底层描边 + 顶层填充，叠加阴影
class _StrokedLabel extends StatelessWidget {
  const _StrokedLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(text, style: _ColorTile._fillStyle.copyWith(foreground: _ColorTile._strokePaint)),
        Text(text, style: _ColorTile._fillStyle),
      ],
    );
  }
}

/// 将 CSS 渐变角度（0=向上，顺时针）转换为 Flutter Alignment 的 begin/end
(Alignment, Alignment) _degToAlignment(int deg) {
  final rad = deg * math.pi / 180;
  final dx = math.sin(rad);
  final dy = -math.cos(rad);
  return (Alignment(-dx, dy), Alignment(dx, -dy));
}
