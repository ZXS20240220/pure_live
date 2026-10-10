import 'dart:math' as math;

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/saved_wallpapers_controller.dart';
import 'package:pure_live/modules/wallpaper/widgets/saved_wallpaper_tile.dart';

/// 已保存壁纸页面
///
/// 展示 WALLPAPER 目录中所有应用过的壁纸（图片和视频），
/// 点击应用，悬停显示删除按钮。
class WallpaperHistoryPage extends StatefulWidget {
  const WallpaperHistoryPage({super.key});

  @override
  State<WallpaperHistoryPage> createState() => _WallpaperHistoryPageState();
}

class _WallpaperHistoryPageState extends State<WallpaperHistoryPage> {
  late final SavedWallpapersController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(SavedWallpapersController());
    controller.refreshData();
  }

  @override
  void dispose() {
    Get.delete<SavedWallpapersController>();
    super.dispose();
  }

  Future<void> _apply(SavedWallpaperItem item) async {
    await controller.apply(item);
    if (mounted) ToastUtil.show('已设为壁纸');
  }

  Future<void> _delete(SavedWallpaperItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除壁纸'),
        content: Text('确定要删除「${item.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.delete(item);
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空所有壁纸'),
        content: const Text('将删除所有已保存的壁纸文件，并清除当前壁纸。此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('清空', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearAll();
      if (mounted) ToastUtil.show('已清空所有壁纸');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SettingsBreadcrumbBar(node: SettingsCrumbs.wallpaperHistory),
        actions: [IconButton(tooltip: '清空所有壁纸', icon: const Icon(Remix.delete_bin_line), onPressed: _clearAll)],
      ),
      body: BasePageView<SavedWallpapersController, SavedWallpaperItem>(
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
        emptyBuilder: (context) =>
            const EmptyView(icon: Remix.image_2_line, title: '暂无保存的壁纸', subtitle: '应用过的壁纸会显示在这里'),
        contentBuilder: (context, displayList, scrollController) {
          return buildCommonPullToRefresh(
            context: context,
            refreshKey: 'wallpaper_history_grid',
            onRefresh: controller.refreshData,
            controller: controller.easyRefreshController,
            childBuilder: (_, physics) => _buildGrid(displayList, scrollController, physics),
          );
        },
      ),
    );
  }

  Widget _buildGrid(List<SavedWallpaperItem> displayList, ScrollController scrollController, ScrollPhysics? physics) {
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
            key: const PageStorageKey('wallpaper_history_grid'),
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
              final item = displayList[index];
              return Obx(() {
                final isCurrent = controller.isCurrent(item);
                return SavedWallpaperTile(
                  item: item,
                  isCurrent: isCurrent,
                  onTap: () => _apply(item),
                  onDelete: () => _delete(item),
                );
              });
            },
          ),
        );
      },
    );
  }
}
