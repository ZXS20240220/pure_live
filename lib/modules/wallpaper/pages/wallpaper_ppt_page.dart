import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/saved_wallpapers_controller.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_fullscreen_preview.dart';

/// PPT 壁纸设置页面
///
/// 展示已保存壁纸中的静态图片，用户勾选参与 PPT 播放的图片，
/// 设置切换间隔与规则后点击应用。
class WallpaperPptPage extends StatefulWidget {
  const WallpaperPptPage({super.key});

  @override
  State<WallpaperPptPage> createState() => _WallpaperPptPageState();
}

class _WallpaperPptPageState extends State<WallpaperPptPage> {
  late final PptWallpapersController controller;
  late final WallpaperSettingsController settingsController;
  final TextEditingController _intervalController = TextEditingController();
  final FocusNode _intervalFocusNode = FocusNode();
  SavedWallpaperItem? _previewItem;
  int? _lastClickedIndex;
  Worker? _pathsWorker;

  static const int _defaultInterval = 5;

  static bool get _isShiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

  @override
  void initState() {
    super.initState();
    controller = Get.put(PptWallpapersController());
    settingsController = WallpaperSettingsController.to;
    controller.refreshData();
    _intervalController.text = settingsController.pptInterval.v.toString();
    _intervalFocusNode.addListener(_onIntervalFocusChange);
    // 启用状态下选中图片变为 0 张时，自动取消启用
    _pathsWorker = ever(settingsController.pptImagePaths, (_) {
      if (settingsController.isSlideshow && settingsController.pptImagePaths.isEmpty) {
        settingsController.clearWallpaper();
      }
    });
  }

  @override
  void dispose() {
    _pathsWorker?.dispose();
    _intervalFocusNode.removeListener(_onIntervalFocusChange);
    _intervalFocusNode.dispose();
    _intervalController.dispose();
    Get.delete<PptWallpapersController>();
    super.dispose();
  }

  void _onIntervalFocusChange() {
    if (!_intervalFocusNode.hasFocus) _validateInterval();
  }

  void _validateInterval() {
    final parsed = int.tryParse(_intervalController.text.trim());
    if (parsed == null || parsed < 1 || parsed > 3600) {
      settingsController.pptInterval.v = _defaultInterval;
      _intervalController.text = _defaultInterval.toString();
    } else {
      settingsController.pptInterval.v = parsed;
      _intervalController.text = parsed.toString();
    }
  }

  void _togglePpt(bool enabled) {
    if (enabled) {
      settingsController.applyPpt();
    } else {
      settingsController.clearWallpaper();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SettingsBreadcrumbAppBar(node: SettingsCrumbs.wallpaperPpt),
      body: Stack(
        children: [
          Column(
            children: [
              _buildSettingsCard(context),
              Expanded(
                child: BasePageView<PptWallpapersController, SavedWallpaperItem>(
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
                    return Center(child: Text('共 $total 张图片', style: AppTextStyles.t13Muted));
                  }),
                  emptyBuilder: (context) =>
                      const EmptyView(icon: Remix.image_2_line, title: '暂无静态图片', subtitle: '先应用一些图片壁纸，它们会保存在这里'),
                  contentBuilder: (context, displayList, scrollController) {
                    return buildCommonPullToRefresh(
                      context: context,
                      refreshKey: 'wallpaper_ppt_grid',
                      onRefresh: controller.refreshData,
                      controller: controller.easyRefreshController,
                      childBuilder: (_, physics) => _buildGrid(displayList, scrollController, physics),
                    );
                  },
                ),
              ),
            ],
          ),
          if (_previewItem != null)
            WallpaperFullscreenPreview(item: _previewItem!, onClose: () => setState(() => _previewItem = null)),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: context.buildModernCard([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Obx(() {
            final selectedCount = settingsController.pptImagePaths.length;
            return Row(
              children: [
                // 切换时间
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _intervalController,
                    focusNode: _intervalFocusNode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '切换时间',
                      border: const OutlineInputBorder(),
                      suffixText: '秒',
                      helperText: '1~3600',
                    ),
                    onEditingComplete: _validateInterval,
                    onSubmitted: (_) => _validateInterval(),
                  ),
                ),
                const SizedBox(width: 20),
                // 切换规则
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('切换规则', style: AppTextStyles.t12.copyWith(color: theme.hintColor)),
                    const SizedBox(height: 6),
                    Row(
                      children: PptMode.values.map((mode) {
                        final selected = settingsController.pptMode.v == mode.name;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(mode.label),
                            selected: selected,
                            onSelected: (_) => settingsController.pptMode.v = mode.name,
                            showCheckmark: selected,
                            checkmarkColor: theme.colorScheme.onPrimary,
                            selectedColor: theme.colorScheme.primary,
                            labelStyle: TextStyle(
                              color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: selectedCount == 0
                      ? '请先选择至少 1 张图片'
                      : (settingsController.isSlideshow ? '关闭 PPT 壁纸' : '启用 PPT 壁纸'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(value: settingsController.isSlideshow, onChanged: selectedCount == 0 ? null : _togglePpt),
                      Text('启用', style: AppTextStyles.t13.copyWith(color: theme.hintColor)),
                    ],
                  ),
                ),
                const Spacer(),
                Obx(() {
                  final visible = controller.list;
                  final allVisibleSelected =
                      visible.isNotEmpty &&
                      visible.every((item) => settingsController.pptImagePaths.contains(item.path));
                  return Tooltip(
                    message: allVisibleSelected ? '取消全选' : '全选当前页',
                    child: IconButton(
                      icon: Icon(allVisibleSelected ? Remix.checkbox_circle_line : Remix.checkbox_blank_circle_line),
                      onPressed: visible.isEmpty
                          ? null
                          : () {
                              if (allVisibleSelected) {
                                settingsController.pptImagePaths.clear();
                              } else {
                                for (final item in visible) {
                                  if (!settingsController.pptImagePaths.contains(item.path)) {
                                    settingsController.pptImagePaths.add(item.path);
                                  }
                                }
                              }
                              _lastClickedIndex = null;
                            },
                    ),
                  );
                }),
                const SizedBox(width: 6),
                // 选中数量
                Text('已选 $selectedCount 张', style: AppTextStyles.t13.copyWith(color: theme.hintColor)),
              ],
            );
          }),
        ),
      ]),
    );
  }

  void _onTileTap(int index, SavedWallpaperItem item, List<SavedWallpaperItem> list) {
    if (_isShiftPressed && _lastClickedIndex != null) {
      final start = math.min(_lastClickedIndex!, index);
      final end = math.max(_lastClickedIndex!, index);
      for (var i = start; i <= end; i++) {
        settingsController.togglePptImage(list[i].path, true);
      }
    } else {
      final selected = settingsController.pptImagePaths.contains(item.path);
      settingsController.togglePptImage(item.path, !selected);
      _lastClickedIndex = index;
    }
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
            key: const PageStorageKey('wallpaper_ppt_grid'),
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
                final selected = settingsController.pptImagePaths.contains(item.path);
                return _PptImageTile(
                  item: item,
                  selected: selected,
                  onTap: () => _onTileTap(index, item, displayList),
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

class _PptImageTile extends StatelessWidget {
  const _PptImageTile({required this.item, required this.selected, required this.onTap, required this.onPreview});

  final SavedWallpaperItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(14);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onSecondaryTap: onPreview,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildImage(theme),
            Positioned(top: 8, left: 8, child: _CircleCheckbox(checked: selected)),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(color: theme.colorScheme.primary, width: 3),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  shadows: const <Shadow>[Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(ThemeData theme) {
    final file = File(item.path);
    if (!file.existsSync()) {
      return Center(child: Icon(Remix.image_line, color: theme.colorScheme.onSurfaceVariant, size: 36));
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          Center(child: Icon(Remix.image_line, color: theme.colorScheme.onSurfaceVariant, size: 36)),
    );
  }
}

class _CircleCheckbox extends StatelessWidget {
  const _CircleCheckbox({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: checked ? theme.colorScheme.primary : Colors.black38,
        border: Border.all(color: Colors.white70, width: 2),
      ),
      child: checked ? Icon(Remix.check_line, size: 16, color: theme.colorScheme.onPrimary) : null,
    );
  }
}
