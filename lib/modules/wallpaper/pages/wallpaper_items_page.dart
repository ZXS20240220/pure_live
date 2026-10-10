import 'dart:math' as math;

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_catalog_items_controller.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_catalog_preview_page.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_repository.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_tile.dart';

/// 壁纸网格页
///
/// 展示某个图源/分组的壁纸列表，点击进入预览页。
/// 复用项目统一的分页骨架。
class WallpaperItemsPage extends StatefulWidget {
  const WallpaperItemsPage({super.key, required this.sourceId, this.groupId});

  final String sourceId;
  final String? groupId;

  @override
  State<WallpaperItemsPage> createState() => _WallpaperItemsPageState();
}

class _WallpaperItemsPageState extends State<WallpaperItemsPage> {
  late final WallpaperCatalogItemsController controller;
  late final CatalogWallpaperSource _source;
  late final CatalogWallpaperGroup? _group;

  @override
  void initState() {
    super.initState();
    final catalog = WallpaperRepository.instance.loadCatalog();
    _source = catalog.sourceById(widget.sourceId)!;
    _group = _pickGroup(_source, widget.groupId);
    controller = Get.put(
      WallpaperCatalogItemsController(sourceId: widget.sourceId, groupId: widget.groupId ?? ''),
      tag: _controllerTag,
    );
    controller.refreshData();
  }

  String get _controllerTag => 'wallpaper_items_${widget.sourceId}_${widget.groupId ?? 'all'}';

  @override
  void dispose() {
    Get.delete<WallpaperCatalogItemsController>(tag: _controllerTag);
    super.dispose();
  }

  String get _title {
    if (_group == null || !_source.categorized) return wallpaperSourceName(_source.id);
    return wallpaperGroupName(_source.id, _group.id);
  }

  void _openPreview(int index) {
    Get.to<void>(
      () => WallpaperCatalogPreviewPage(
        items: List<CatalogWallpaperItem>.from(controller.list),
        kind: _source.kind,
        title: _title,
        initialIndex: index,
      ),
    );
  }

  SettingsCrumb get _crumb {
    return SettingsCrumb(
      labelText: _title,
      routeName: '/settings/wallpaper/library/items',
      pageBuilder: () => widget,
      parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperLibrary],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: _crumb)),
      body: BasePageView<WallpaperCatalogItemsController, CatalogWallpaperItem>(
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
        emptyBuilder: (context) => const EmptyView(icon: Remix.image_2_line, title: '暂无壁纸', subtitle: ''),
        contentBuilder: (context, displayList, scrollController) {
          return buildCommonPullToRefresh(
            refreshKey: 'wallpaper_items_${widget.sourceId}_${widget.groupId ?? 'all'}',
            onRefresh: controller.refreshData,
            controller: controller.easyRefreshController,
            childBuilder: (_, physics) => _buildGrid(displayList, scrollController, physics),
          );
        },
      ),
    );
  }

  Widget _buildGrid(List<CatalogWallpaperItem> displayList, ScrollController scrollController, ScrollPhysics? physics) {
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

        final background = Get.find<WallpaperSettingsController>();

        return ScrollConfiguration(
          behavior: const MouseDraggableScrollBehavior(),
          child: GridView.builder(
            key: PageStorageKey('wallpaper_items_${widget.sourceId}_${widget.groupId ?? 'all'}'),
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
              return WallpaperTile(
                item: item,
                kind: _source.kind,
                selected: background.usesWallpaper(item),
                onTap: () => _openPreview(index),
              );
            },
          ),
        );
      },
    );
  }

  static CatalogWallpaperGroup? _pickGroup(CatalogWallpaperSource source, String? wanted) {
    final groups = source.visibleGroups;
    if (groups.isEmpty) return null;
    if (wanted == null) return groups.first;
    for (final group in groups) {
      if (group.id == wanted) return group;
    }
    return groups.first;
  }
}
