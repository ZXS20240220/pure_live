import 'dart:math' as math;

import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/plugins/file_utils.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/saved_wallpapers_controller.dart';
import 'package:pure_live/modules/wallpaper/widgets/saved_wallpaper_tile.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_fullscreen_preview.dart';

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
  SavedWallpaperItem? _previewItem;

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
    if (mounted) ToastUtil.show(i18n('wallpaper_history_set_as_wallpaper'));
  }

  Future<void> _delete(SavedWallpaperItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n('wallpaper_history_delete_title')),
        content: Text(i18n('wallpaper_history_delete_confirm', args: {'name': item.name})),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(i18n('cancel'))),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n('remove'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
        title: Text(i18n('wallpaper_history_clear_all_title')),
        content: Text(i18n('wallpaper_history_clear_all_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(i18n('cancel'))),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n('wallpaper_history_clear'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearAll();
      if (mounted) ToastUtil.show(i18n('wallpaper_history_cleared_all'));
    }
  }

  Future<void> _openWallpaperDir() async {
    try {
      final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
      await FileUtils.openFileOrUrl(dir.path);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: SettingsBreadcrumbAppBar(
            node: SettingsCrumbs.wallpaperHistory,
            actions: [
              _ExtensionFilterButton(controller: controller),
              IconButton(
                tooltip: i18n('wallpaper_history_open_dir'),
                icon: const Icon(Remix.folder_open_line),
                onPressed: () => _openWallpaperDir(),
              ),
              IconButton(
                tooltip: i18n('wallpaper_history_clear_all_title'),
                icon: const Icon(Remix.delete_bin_line),
                onPressed: _clearAll,
              ),
            ],
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
            rightPaginationWidget: Obx(() {
              final total = controller.totalCount.value;
              if (total == null) return const SizedBox.shrink();
              return Center(
                child: Text(
                  i18n('wallpaper_history_total_count', args: {'total': total.toString()}),
                  style: AppTextStyles.t13Muted,
                ),
              );
            }),
            leftPaginationWidget: Center(
              child: Text(i18n('wallpaper_history_right_click_hint'), style: AppTextStyles.t13Muted),
            ),
            collapseLeftPaginationWidget: false,
            emptyBuilder: (context) => EmptyView(
              icon: Remix.image_2_line,
              title: i18n('wallpaper_history_empty_title'),
              subtitle: i18n('wallpaper_history_empty_subtitle'),
            ),
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
        ),
        if (_previewItem != null)
          WallpaperFullscreenPreview(item: _previewItem!, onClose: () => setState(() => _previewItem = null)),
      ],
    );
  }

  Widget _buildGrid(List<SavedWallpaperItem> displayList, ScrollController scrollController, ScrollPhysics? physics) {
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
                  onPreview: () => setState(() => _previewItem = item),
                );
              });
            },
          ),
        );
      },
    );
  }
}

/// 扩展名筛选下拉按钮
///
/// 点击展开多选面板，支持按扩展名筛选已保存壁纸。
/// 默认全部显示（selectedExtensions 为空），选中一个或多个扩展名后仅显示对应类型。
class _ExtensionFilterButton extends StatefulWidget {
  final SavedWallpapersController controller;

  const _ExtensionFilterButton({required this.controller});

  @override
  State<_ExtensionFilterButton> createState() => _ExtensionFilterButtonState();
}

class _ExtensionFilterButtonState extends State<_ExtensionFilterButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  bool get _isOpen => _overlayEntry != null;

  void _toggle() {
    if (_isOpen) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    final buttonHeight = renderBox?.size.height ?? 40;

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _close),
          ),
          Positioned(
            width: 200,
            child: CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              offset: Offset(0, buttonHeight + 6),
              child: _buildPanel(),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _close() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() {});
  }

  Widget _buildPanel() {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Obx(() {
        final exts = widget.controller.availableExtensions;
        final selected = widget.controller.selectedExtensions;
        final allSelected = selected.isEmpty;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FilterTile(
              title: i18n('site_all'),
              selected: allSelected,
              onTap: () => widget.controller.selectedExtensions.clear(),
            ),
            if (exts.isNotEmpty) const Divider(height: 1, thickness: 1),
            if (exts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(i18n('wallpaper_history_no_extensions'), style: AppTextStyles.t13Muted),
              )
            else
              ...exts.map(
                (ext) => _FilterTile(
                  title: ext.toUpperCase(),
                  selected: selected.contains(ext),
                  onTap: () {
                    if (selected.contains(ext)) {
                      widget.controller.selectedExtensions.remove(ext);
                    } else {
                      widget.controller.selectedExtensions.add(ext);
                    }
                  },
                ),
              ),
          ],
        );
      }),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Obx(() {
        final selected = widget.controller.selectedExtensions;
        final isFiltering = selected.isNotEmpty;
        final label = selected.isEmpty
            ? i18n('site_all')
            : selected.length == 1
            ? selected.first.toUpperCase()
            : i18n('wallpaper_history_selected_count', args: {'count': selected.length.toString()});
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Remix.filter_line, size: 18, color: isFiltering ? Theme.of(context).colorScheme.primary : null),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppTextStyles.t13.copyWith(
                    color: isFiltering ? Theme.of(context).colorScheme.primary : null,
                    fontWeight: isFiltering ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _FilterTile extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _FilterTile({required this.title, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected ? Remix.checkbox_circle_fill : Remix.checkbox_blank_circle_line,
              size: 18,
              color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: AppTextStyles.t14.copyWith(
                  color: selected ? colorScheme.primary : colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
