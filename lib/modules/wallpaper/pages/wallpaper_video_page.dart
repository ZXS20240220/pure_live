import 'dart:math' as math;

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_video_controller.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_video_preview_page.dart';
import 'package:pure_live/modules/wallpaper/services/itab_wallpaper_client.dart';

/// 动态壁纸库页面
///
/// 复用项目统一的分页骨架：桌面端显示页码分页条，移动端下拉刷新，
/// 鼠标拖拽可滚动内容，页码区域支持滚轮翻页。
class WallpaperVideoPage extends StatefulWidget {
  const WallpaperVideoPage({super.key});

  @override
  State<WallpaperVideoPage> createState() => _WallpaperVideoPageState();
}

class _WallpaperVideoPageState extends State<WallpaperVideoPage> {
  late final WallpaperVideoController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(WallpaperVideoController());
    controller.refreshData();
  }

  @override
  void dispose() {
    Get.delete<WallpaperVideoController>();
    super.dispose();
  }

  void _openPreview(int index) {
    Get.to<void>(
      () => WallpaperVideoPreviewPage(items: List<VideoWallpaperItem>.from(controller.list), initialIndex: index),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: SettingsCrumbs.wallpaperVideo)),
      body: BasePageView<WallpaperVideoController, VideoWallpaperItem>(
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
        emptyBuilder: (context) => const EmptyView(icon: Remix.film_line, title: '暂无动态壁纸', subtitle: ''),
        contentBuilder: (context, displayList, scrollController) {
          return buildCommonPullToRefresh(
            refreshKey: 'wallpaper_video_grid',
            onRefresh: controller.refreshData,
            controller: controller.easyRefreshController,
            childBuilder: (_, physics) => _buildGrid(displayList, scrollController, physics),
          );
        },
      ),
    );
  }

  Widget _buildGrid(List<VideoWallpaperItem> displayList, ScrollController scrollController, ScrollPhysics? physics) {
    return LayoutBuilder(
      builder: (context, constraint) {
        const crossAxisExtent = 260.0;
        const crossAxisSpacing = 10.0;
        const mainAxisSpacing = 10.0;

        final width = constraint.maxWidth;
        final crossAxisCount = math.max(1, ((width - 12) / (crossAxisExtent + crossAxisSpacing)).ceil());

        final itemWidth = (width - 12 - crossAxisSpacing * (crossAxisCount - 1)) / crossAxisCount;
        final mainAxisExtent = itemWidth * 9 / 16;

        final rowExtent = mainAxisExtent + mainAxisSpacing;
        final rows = ((constraint.maxHeight - 10 + mainAxisSpacing) / rowExtent).floor();
        controller.applyViewportPageSize(rows.clamp(1, 999) * crossAxisCount);

        return ScrollConfiguration(
          behavior: const MouseDraggableScrollBehavior(),
          child: GridView.builder(
            key: const PageStorageKey('wallpaper_video_grid'),
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
              return _VideoTile(item: displayList[index], onTap: () => _openPreview(index));
            },
          ),
        );
      },
    );
  }
}

/// 动态壁纸条目卡片
class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.item, required this.onTap});

  final VideoWallpaperItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumbnail(theme),
            const Center(child: Icon(Icons.play_circle_outline, size: 40, color: Colors.white70)),
            if (item.name != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                  child: Text(
                    item.name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(ThemeData theme) {
    final thumb = item.thumb ?? item.poster;
    if (thumb != null && thumb.isNotEmpty) {
      return Image.network(
        thumb,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image, color: Colors.white38)),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        },
      );
    }
    return Center(child: Icon(Icons.video_library, color: theme.colorScheme.onSurfaceVariant));
  }
}
