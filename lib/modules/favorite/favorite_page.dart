import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:remixicon/remixicon.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/tags/live_tag.dart';
import 'package:pure_live/modules/favorite/room_grid_view.dart';
import 'package:pure_live/common/widgets/common_appbar_actions.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

class FavoritePage extends GetView<FavoriteController> {
  const FavoritePage({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraint) {
        return Obx(() {
          bool showAction = Get.width <= 680;
          final availableSitesList = Sites().availableSites(containsAll: true);
          final siteKey = ValueKey(availableSitesList.map((e) => e.id).join('|'));

          return Scaffold(
            appBar: AppBar(
              centerTitle: true,
              leading: showAction ? const MenuButton() : null,
              actions: showAction ? [CommonAppBarActions()] : null,
              title: Obx(() {
                return Listener(
                  onPointerSignal: (event) {
                    if (event is! PointerScrollEvent) return;
                    final ctrl = controller.tabController;
                    if (ctrl.length == 0) return;
                    final dir = event.scrollDelta.dy > 0 ? 1 : -1;
                    final next = (ctrl.index + dir) % ctrl.length;
                    ctrl.animateTo(next);
                  },
                  child: TabBar(
                    key: const ValueKey('favorite-status-tabs'),
                    controller: controller.tabController,
                    isScrollable: false,
                    tabAlignment: TabAlignment.center,
                    physics: const PureLiveBoundedScrollPhysics(),
                    tabs: [
                      Tab(
                        text:
                            '${i18n('recorder_tab_all')} (${controller.onlineRooms.length + controller.replayRooms.length + controller.offlineRooms.length})',
                      ),
                      Tab(text: '${i18n('online_room_title')} (${controller.onlineRooms.length})'),
                      Tab(text: '${i18n('recording_room_title')} (${controller.replayRooms.length})'),
                      Tab(text: '${i18n('offline_room_title')} (${controller.offlineRooms.length})'),
                      Tab(text: '暂时弃用 (${controller.dormantRooms.length})'),
                    ],
                  ),
                );
              }),
            ),
            body: Stack(
              children: [
                _FavoriteSiteTabs(key: siteKey, controller: controller, availableSitesList: availableSitesList),
                Positioned(
                  right: 14,
                  bottom: 4,
                  child: Obx(() {
                    final count = controller.getFilteredRooms().length;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.view_list_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            i18n('rooms_count'),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

@visibleForTesting
int resolveFavoriteSiteIndex({required List<String> siteIds, required String selectedSiteId, required int fallback}) {
  if (siteIds.isEmpty) return 0;
  final selectedIndex = siteIds.indexOf(selectedSiteId);
  return selectedIndex >= 0 ? selectedIndex : fallback.clamp(0, siteIds.length - 1).toInt();
}

/// Owns one stable site [TabController] across reactive data publications.
///
/// It also preserves the selected site by id when the configured platform
/// order changes, instead of resetting the visual controller to index zero
/// while the data controller still points at an older numeric index.
class _FavoriteSiteTabs extends StatefulWidget {
  const _FavoriteSiteTabs({super.key, required this.controller, required this.availableSitesList});

  final FavoriteController controller;
  final List<Site> availableSitesList;

  @override
  State<_FavoriteSiteTabs> createState() => _FavoriteSiteTabsState();
}

class _FavoriteSiteTabsState extends State<_FavoriteSiteTabs> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Map<String, ScrollController> _siteScrollControllers = {};
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Worker? _searchSyncWorker;

  ScrollController _scrollControllerFor(String siteId) =>
      _siteScrollControllers.putIfAbsent(siteId, () => createPureLiveScrollController());

  @override
  void initState() {
    super.initState();
    _searchController.text = widget.controller.searchKeyword.value;
    _searchSyncWorker = ever(widget.controller.searchKeyword, (String value) {
      if (_searchController.text != value) {
        _searchController.text = value;
      }
    });
    final initialIndex = resolveFavoriteSiteIndex(
      siteIds: widget.availableSitesList.map((site) => site.id).toList(growable: false),
      selectedSiteId: widget.controller.selectedPlatformId,
      fallback: widget.controller.tabSiteIndex.value,
    );
    _tabController = TabController(
      length: widget.availableSitesList.length,
      initialIndex: initialIndex,
      vsync: this,
      animationDuration: pureLiveTabTransitionDuration,
    )..addListener(_handleTabChanged);
    widget.controller.bindActiveScrollController(_scrollControllerFor(widget.availableSitesList[initialIndex].id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.selectSiteIndex(initialIndex);
    });
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  void _handleTabChanged() {
    final tabController = _tabController;
    if (tabController.indexIsChanging) return;
    final animationValue = tabController.animation?.value ?? tabController.index.toDouble();
    if ((animationValue - tabController.index).abs() > 0.001) return;
    final controller = widget.controller;
    if (tabController.index < 0 || tabController.index >= widget.availableSitesList.length) return;
    controller.bindActiveScrollController(_scrollControllerFor(widget.availableSitesList[tabController.index].id));
    controller.selectSiteIndex(tabController.index);
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;

    final ctrlOrCmd = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_searchController.text.isNotEmpty) {
          _searchController.selection = TextSelection(baseOffset: 0, extentOffset: _searchController.text.length);
        }
      });
      return true;
    }

    if (isEditingFocused()) return false;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.digit1:
        final tabs = widget.availableSitesList.length;
        if (tabs == 0) return false;
        final current = _tabController.index;
        final prev = (current - 1 + tabs) % tabs;
        _tabController.animateTo(prev);
        return true;

      case LogicalKeyboardKey.digit2:
        final tabs = widget.availableSitesList.length;
        if (tabs == 0) return false;
        final current = _tabController.index;
        final next = (current + 1) % tabs;
        _tabController.animateTo(next);
        return true;

      case LogicalKeyboardKey.f5:
        widget.controller.refreshData();
        return true;

      case LogicalKeyboardKey.arrowLeft:
        final controller = widget.controller;
        if (controller.currentPage > 1 && !controller.loadding.value) {
          controller.goToPage(controller.currentPage - 1);
        }
        return true;

      case LogicalKeyboardKey.arrowRight:
        final controller = widget.controller;
        if (controller.canLoadMore.value && !controller.loadding.value) {
          controller.goToPage(controller.currentPage + 1);
        }
        return true;

      case LogicalKeyboardKey.arrowUp:
        _scrollPage(-1);
        return true;

      case LogicalKeyboardKey.arrowDown:
        _scrollPage(1);
        return true;
    }

    return false;
  }

  void _scrollPage(int direction) {
    final controller = widget.controller.scrollController;
    if (!controller.hasClients) return;
    final viewportHeight = controller.position.viewportDimension;
    final targetOffset = (controller.offset + direction * viewportHeight).clamp(
      0.0,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(targetOffset, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _searchSyncWorker?.dispose();
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    widget.controller.bindActiveScrollController(null);
    for (final controller in _siteScrollControllers.values) {
      controller.dispose();
    }
    _siteScrollControllers.clear();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Widget _buildLastRefreshTime(BuildContext context) {
    return Obx(() {
      final dt = widget.controller.lastFullRefreshAt.value;
      if (dt == null) return const SizedBox.shrink();
      final timeStr = DateFormat('HH:mm:ss').format(dt);
      final text = i18n('refresh_last_updated_at').replaceAll('%T', timeStr);
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0),
          child: Text(text, style: AppTextStyles.t13Muted, overflow: TextOverflow.ellipsis),
        ),
      );
    });
  }

  /// 暂弃编辑弹窗内统一的紧凑下拉框样式（与搜索框底色一致）。
  Widget _buildPickerDropdown<T>({
    required BuildContext context,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(8),
        icon: Icon(Remix.arrow_down_s_line, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        style: AppTextStyles.t12.copyWith(color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }

  /// 暂弃编辑弹窗中每个房间的状态行：
  /// - 正在直播：绿点 + "直播中"
  /// - 未开播且有 startTime：显示上次直播时间（与未开播卡片遮罩格式一致）
  /// - 无可用信息：返回 null 不显示
  Widget? _buildPickerRoomStatusLine(LiveRoom room) {
    if (room.isLiveNow) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(i18n('live'), maxLines: 1, style: AppTextStyles.t11Muted.copyWith(color: Colors.greenAccent)),
        ],
      );
    }
    final ts = room.startTime;
    if (ts == null || ts <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final y = dt.year.toString();
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return Text(
      '${i18n('last_live_time_prefix')} $y-$mo-$d $h:$mi',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.t11Muted,
    );
  }

  /// 暂弃房间编辑弹窗：列出所有关注直播间，用户勾选/取消来移入/移出暂弃。
  void _showDormantRoomPicker(BuildContext context) {
    final favCtrl = SettingsService.to.fav;
    final allRooms = List<LiveRoom>.from(favCtrl.favoriteRooms.v);
    final dormantKeys = favCtrl.dormantRoomKeys.toSet();

    // 初始勾选状态 = 当前 dormantKeys
    final selectedKeys = <String>{...dormantKeys};

    // 弹窗内筛选状态：0=全部 1=直播中 2=未直播 3=已弃用；platformFilter 为空表示全部平台
    var statusFilter = 0;
    var platformFilter = '';
    var searchText = '';
    final searchController = TextEditingController();

    // 平台选项：从关注列表提取，去重排序
    final platformOptions = allRooms.map((r) => r.normalizedPlatformId).toSet().toList()..sort();

    // 按平台、状态与关键词过滤；三个状态互斥：已弃用优先于直播状态
    List<LiveRoom> filteredRooms() {
      final kw = searchText.trim().toLowerCase();
      return allRooms.where((room) {
        if (platformFilter.isNotEmpty && room.normalizedPlatformId != platformFilter) return false;
        final isDormant = selectedKeys.contains(room.identityKey);
        switch (statusFilter) {
          case 1:
            if (isDormant || !room.isLiveNow) return false;
          case 2:
            if (isDormant || room.isLiveNow) return false;
          case 3:
            if (!isDormant) return false;
        }
        if (kw.isNotEmpty) {
          final nick = (room.nick ?? '').toLowerCase();
          final title = (room.title ?? '').toLowerCase();
          final roomId = (room.roomId ?? '').toLowerCase();
          if (!nick.contains(kw) && !title.contains(kw) && !roomId.contains(kw)) return false;
        }
        return true;
      }).toList();
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final visibleRooms = filteredRooms();
            return Dialog(
              child: Container(
                width: 560,
                height: 600,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Remix.archive_line, size: 20, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('编辑暂时弃用列表', style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        Text('已选 ${selectedKeys.length} / ${allRooms.length}', style: AppTextStyles.t13Muted),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('勾选的直播间将被移入暂时弃用分类，不再参与刷新；取消勾选则移出暂时弃用并立即刷新一次最新状态。', style: AppTextStyles.t12Muted),
                    const SizedBox(height: 12),
                    // 搜索栏 + 平台筛选下拉框 + 直播状态筛选下拉框
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            onChanged: (value) => setState(() => searchText = value),
                            style: AppTextStyles.t12,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '搜索主播名 / 标题 / 房间号',
                              hintStyle: AppTextStyles.t12.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                              ),
                              prefixIcon: Icon(
                                Remix.search_line,
                                size: 18,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              suffixIcon: searchText.isNotEmpty
                                  ? IconButton(
                                      iconSize: 18,
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: Icon(
                                        Remix.close_circle_fill,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                      onPressed: () {
                                        searchController.clear();
                                        setState(() => searchText = '');
                                      },
                                    )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildPickerDropdown<String>(
                          context: context,
                          value: platformFilter,
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text('全部平台', style: AppTextStyles.t12),
                            ),
                            ...platformOptions.map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(p.toUpperCase(), style: AppTextStyles.t12),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => platformFilter = v ?? ''),
                        ),
                        const SizedBox(width: 8),
                        _buildPickerDropdown<int>(
                          context: context,
                          value: statusFilter,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('全部')),
                            DropdownMenuItem(value: 1, child: Text('直播中')),
                            DropdownMenuItem(value: 2, child: Text('未直播')),
                            DropdownMenuItem(value: 3, child: Text('已弃用')),
                          ],
                          onChanged: (v) => setState(() => statusFilter = v ?? 0),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: visibleRooms.isEmpty
                          ? Center(
                              child: Text(
                                statusFilter == 0 && platformFilter.isEmpty && searchText.isEmpty
                                    ? '暂无关注直播间'
                                    : '无匹配的直播间',
                                style: AppTextStyles.t12Muted,
                              ),
                            )
                          : ListView.separated(
                              itemCount: visibleRooms.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: 40),
                              itemBuilder: (context, index) {
                                final room = visibleRooms[index];
                                final isSelected = selectedKeys.contains(room.identityKey);
                                // 上次直播时间行：直播中显示绿点状态；未开播且有 startTime 时显示上次直播时间
                                final Widget? liveStatusLine = _buildPickerRoomStatusLine(room);
                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      setState(() {
                                        if (isSelected) {
                                          selectedKeys.remove(room.identityKey);
                                        } else {
                                          selectedKeys.add(room.identityKey);
                                        }
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Row(
                                        children: [
                                          Checkbox(
                                            value: isSelected,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                            onChanged: (_) {
                                              setState(() {
                                                if (isSelected) {
                                                  selectedKeys.remove(room.identityKey);
                                                } else {
                                                  selectedKeys.add(room.identityKey);
                                                }
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 4),
                                          CircleAvatar(
                                            radius: 16,
                                            backgroundImage: (room.avatar?.isNotEmpty ?? false)
                                                ? CachedNetworkImageProvider(room.avatar!)
                                                : null,
                                            child: (room.avatar?.isEmpty ?? true)
                                                ? const Icon(Icons.live_tv_rounded, size: 16)
                                                : null,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  room.nick?.trim().isNotEmpty == true
                                                      ? room.nick!
                                                      : (room.title?.trim().isNotEmpty == true ? room.title! : '未知主播'),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: AppTextStyles.t13.copyWith(fontWeight: FontWeight.w500),
                                                ),
                                                if (room.title?.trim().isNotEmpty == true &&
                                                    room.nick?.trim().isNotEmpty == true)
                                                  Text(
                                                    room.title!,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: AppTextStyles.t11Muted,
                                                  ),
                                                if (liveStatusLine != null) ...[
                                                  const SizedBox(height: 1),
                                                  liveStatusLine,
                                                ],
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.surfaceContainerHighest
                                                  .withValues(alpha: 0.5),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              room.normalizedPlatformId.toUpperCase(),
                                              style: AppTextStyles.t11Muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(i18n('cancel'))),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _applyDormantChanges(allRooms, selectedKeys, dormantKeys);
                          },
                          child: const Text('应用'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(searchController.dispose);
  }

  /// 计算差异并执行移入/移出暂弃操作。
  Future<void> _applyDormantChanges(
    List<LiveRoom> allRooms,
    Set<String> newDormantKeys,
    Set<String> oldDormantKeys,
  ) async {
    final controller = widget.controller;

    // 需要移入暂弃的（之前不在、现在在）
    final toAdd = allRooms
        .where((r) => !oldDormantKeys.contains(r.identityKey) && newDormantKeys.contains(r.identityKey))
        .toList();
    // 需要移出暂弃的（之前在、现在不在）
    final toRemove = allRooms
        .where((r) => oldDormantKeys.contains(r.identityKey) && !newDormantKeys.contains(r.identityKey))
        .toList();

    // 先执行移出（让这些房间立即参与刷新）
    if (toRemove.isNotEmpty) {
      await controller.restoreRoomsFromDormant(toRemove);
    }
    // 再执行移入
    if (toAdd.isNotEmpty) {
      await controller.moveRoomsToDormant(toAdd);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final availableSitesList = widget.availableSitesList;
    return Column(
      children: [
        Obx(() {
          final statusIndex = controller.tabOnlineIndex.value;
          return Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              if (_tabController.length == 0) return;
              final dir = event.scrollDelta.dy > 0 ? 1 : -1;
              final next = (_tabController.index + dir) % _tabController.length;
              _tabController.animateTo(next);
            },
            child: TabBar(
              key: const ValueKey('favorite-platform-tabs'),
              controller: _tabController,
              isScrollable: true,
              physics: const NeverScrollableScrollPhysics(),
              tabs: availableSitesList.map((e) {
                final count = controller.favoriteCountForSite(e.id, statusIndex: statusIndex);
                return Tab(text: '${e.name} ($count)');
              }).toList(),
            ),
          );
        }),
        FavoriteTagStrip(
          tags: controller.visibleTags,
          selectedTagIds: controller.selectedTagIds,
          visibleUntaggedCount: controller.visibleUntaggedCount,
          multiSelectMode: controller.multiSelectMode,
          onMultiSelectChanged: (v) => controller.multiSelectMode.value = v,
          allLabel: i18n('recorder_tab_all'),
          onSelected: controller.changeSelectedTag,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 12, 6),
          child: Row(
            children: [
              // 暂弃Tab下：显示"+"编辑按钮替代置顶/排序按钮组
              Obx(() {
                final isDormantTab = controller.tabOnlineIndex.value == 4;
                if (isDormantTab) {
                  return IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () => _showDormantRoomPicker(context),
                    tooltip: '编辑暂时弃用列表',
                    icon: Icon(Remix.add_line, color: Theme.of(context).colorScheme.primary),
                  );
                }
                // 观看时长排序对所有状态生效，排序按钮在所有页签下都可用。
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => controller.enablePinned.value = !controller.enablePinned.value,
                      tooltip: i18n('favorite_enable_pinned'),
                      icon: Obx(
                        () => Icon(
                          controller.enablePinned.value ? Remix.pushpin_fill : Remix.pushpin_line,
                          color: controller.enablePinned.value
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    PopupMenuButton<OnlineSortMode>(
                      initialValue: controller.onlineSortMode.value,
                      onSelected: (mode) => controller.onlineSortMode.value = mode,
                      tooltip: i18n('favorite_sort_menu'),
                      icon: Obx(() {
                        final mode = controller.onlineSortMode.value;
                        return Icon(switch (mode) {
                          OnlineSortMode.startTime => Remix.time_line,
                          OnlineSortMode.watchTime => Remix.timer_2_line,
                          _ => Remix.fire_line,
                        }, color: Theme.of(context).colorScheme.onSurfaceVariant);
                      }),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: OnlineSortMode.audience, child: Text(i18n('favorite_sort_audience'))),
                        PopupMenuItem(value: OnlineSortMode.startTime, child: Text(i18n('favorite_sort_start_time'))),
                        PopupMenuItem(value: OnlineSortMode.watchTime, child: Text(i18n('favorite_sort_watch_time'))),
                      ],
                    ),
                    // 升序/降序切换：对热度/开播时间/观看时长三种模式统一生效。
                    Obx(() {
                      final ascending = controller.onlineSortAscending.value;
                      return IconButton(
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        onPressed: () => controller.onlineSortAscending.value = !ascending,
                        tooltip: i18n(ascending ? 'favorite_sort_asc' : 'favorite_sort_desc'),
                        icon: Icon(
                          ascending ? Remix.sort_asc : Remix.sort_desc,
                          color: ascending
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      );
                    }),
                  ],
                );
              }),
              Expanded(
                child: Obx(() {
                  final hasKeyword = controller.searchKeyword.value.isNotEmpty;
                  return TextField(
                    focusNode: _searchFocusNode,
                    controller: _searchController,
                    onChanged: (value) => controller.searchKeyword.value = value,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: i18n('favorite_search_hint'),
                      hintStyle: AppTextStyles.t12.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                      prefixIcon: Icon(
                        Remix.search_line,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: hasKeyword
                          ? IconButton(
                              iconSize: 18,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              icon: Icon(
                                Remix.close_circle_fill,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                controller.searchKeyword.value = '';
                              },
                            )
                          : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  );
                }),
              ),
              // 布局切换按钮：标准网格 ↔ 紧凑列表。
              Obx(() {
                final isCompact = controller.cardLayoutMode.v == 'compact';
                return IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: isCompact ? '切换为卡片布局' : '切换为列表布局',
                  onPressed: () {
                    controller.cardLayoutMode.value = isCompact ? 'standard' : 'compact';
                  },
                  icon: Icon(
                    isCompact ? Icons.grid_view_rounded : Icons.view_list_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                );
              }),
              Obx(() {
                final hasActiveFilter =
                    controller.searchKeyword.value.isNotEmpty ||
                    controller.tabOnlineIndex.value != 1 ||
                    controller.selectedTagIds.length != 1 ||
                    !controller.selectedTagIds.contains(TagManagementController.allTagKey) ||
                    controller.tabSiteIndex.value != 0 ||
                    controller.currentPage != 1;
                return IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: i18n('reset'),
                  onPressed: () {
                    _searchController.clear();
                    controller.resetFilters();
                    if (_tabController.index != 0) {
                      _tabController.animateTo(0);
                    }
                  },
                  icon: Icon(
                    Remix.refresh_line,
                    color: hasActiveFilter
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                );
              }),
            ],
          ),
        ),
        Expanded(
          // Obx：紧凑布局下隐藏"每页"选择器（每页数量已由视口自适应接管）。
          child: Obx(
            () => BasePageView<FavoriteController, LiveRoom>(
              controller: controller,
              enableRefresh: true,
              enableLoadMore: true,
              wrapMobileRefresh: false,
              preserveContentWhenEmpty: true,
              keyboardPagingEnabled: false,
              // 列表（紧凑）布局下不显示悬浮按钮（回到顶部/底部）。
              showScrollToTopBtn:
                  controller.cardLayoutMode.value != 'compact' && SettingsService.to.page.showScrollToTopBtn.v,
              showPageSizeSelector:
                  controller.cardLayoutMode.value != 'compact' && SettingsService.to.page.showPageSizeSelector.v,
              pageSizeOptions: SettingsService.to.page.pageSizeOptions,
              leftPaginationWidget: _buildLastRefreshTime(context),
              contentBuilder: (context, list, _) {
                final activeSiteIndex = controller.tabSiteIndex.value;
                return TabBarView(
                  controller: _tabController,
                  physics: const PureLiveBoundedScrollPhysics(),
                  children: availableSitesList.asMap().entries.map((entry) {
                    final site = entry.value;
                    return Builder(
                      key: ValueKey('favorite_site_${site.id}'),
                      builder: (context) {
                        // PageView mounts only the active/nearby pages. Defer
                        // platform filtering and ScrollController allocation to
                        // that point rather than doing both for every platform
                        // on each reactive rebuild.
                        final isCurrentSite = entry.key == activeSiteIndex;
                        final pageList = isCurrentSite ? list : controller.filteredSyncedRoomsForSite(site.id);
                        return RoomGridView(
                          siteId: site.id,
                          scrollController: _scrollControllerFor(site.id),
                          displayList: pageList,
                          emptyBuilder: (context) => _FavoriteEmptyState(controller: controller, siteId: site.id),
                        );
                      },
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class FavoriteTagStrip extends StatefulWidget {
  const FavoriteTagStrip({
    super.key,
    required this.tags,
    required this.selectedTagIds,
    required this.visibleUntaggedCount,
    required this.multiSelectMode,
    required this.onMultiSelectChanged,
    required this.allLabel,
    required this.onSelected,
    this.labelStyle,
  });

  final RxList<LiveTag> tags;
  final RxSet<String> selectedTagIds;
  final RxInt visibleUntaggedCount;
  final RxBool multiSelectMode;
  final ValueChanged<bool> onMultiSelectChanged;
  final String allLabel;
  final ValueChanged<String> onSelected;
  final TextStyle? labelStyle;

  @override
  State<FavoriteTagStrip> createState() => _FavoriteTagStripState();
}

class _FavoriteTagStripState extends State<FavoriteTagStrip> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final visibleTags = widget.tags.toList(growable: false);
      final activeIds = widget.selectedTagIds.toSet();
      final isMulti = widget.multiSelectMode.value;
      final untaggedCount = widget.visibleUntaggedCount.value;
      final showUntagged = untaggedCount > 0;
      if (visibleTags.isEmpty && !showUntagged) return const SizedBox.shrink();
      final itemCount = visibleTags.length + 1 + (showUntagged ? 1 : 0);
      return SizedBox(
        key: const ValueKey('favorite_tag_strip'),
        height: 44,
        width: double.infinity,
        child: Row(
          children: [
            IconButton(
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => widget.onMultiSelectChanged(!isMulti),
              tooltip: isMulti ? i18n('tag_multi_select_enabled') : i18n('tag_multi_select_disabled'),
              icon: Icon(
                isMulti ? RemixIcons.checkbox_multiple_fill : RemixIcons.checkbox_multiple_line,
                color: isMulti ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: MouseScrollDirectionConverter(
                targetAxis: Axis.horizontal,
                controller: _scrollController,
                child: ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const PureLiveBoundedScrollPhysics(),
                  clipBehavior: Clip.hardEdge,
                  padding: const EdgeInsets.only(right: 16, top: 6, bottom: 6),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    final isAll = index == 0;
                    final isUntagged = showUntagged && index == itemCount - 1 && !isAll;
                    final tag = (!isAll && !isUntagged) ? visibleTags[index - 1] : null;
                    final tagId = isAll
                        ? TagManagementController.allTagKey
                        : isUntagged
                        ? TagManagementController.untaggedTagKey
                        : tag!.id;
                    final label = isAll
                        ? widget.allLabel
                        : isUntagged
                        ? '${TagManagementController.untaggedTagLabel} ($untaggedCount)'
                        : tag!.name;
                    final isSelected = activeIds.contains(tagId);
                    final colorScheme = theme.colorScheme;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: isUntagged
                          ? ChoiceChip(
                              key: const ValueKey('favorite_tag_untagged'),
                              showCheckmark: false,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Remix.price_tag_line,
                                    size: 13,
                                    color: isSelected
                                        ? colorScheme.onPrimary
                                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    label,
                                    style: (widget.labelStyle ?? AppTextStyles.t12).copyWith(
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      fontStyle: FontStyle.italic,
                                      color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              selected: isSelected,
                              selectedColor: colorScheme.tertiary,
                              backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.08),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(
                                  color: isSelected ? Colors.transparent : colorScheme.outline.withValues(alpha: 0.35),
                                  width: 0.8,
                                ),
                              ),
                              onSelected: (_) => widget.onSelected(tagId),
                            )
                          : ChoiceChip(
                              key: ValueKey('favorite_tag_$tagId'),
                              showCheckmark: false,
                              label: Text(
                                label,
                                style: (widget.labelStyle ?? AppTextStyles.t12).copyWith(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: colorScheme.primary,
                              backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(
                                  color: isSelected ? Colors.transparent : theme.dividerColor.withValues(alpha: 0.04),
                                  width: 0.5,
                                ),
                              ),
                              onSelected: (_) => widget.onSelected(tagId),
                            ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _FavoriteEmptyState extends StatelessWidget {
  const _FavoriteEmptyState({required this.controller, required this.siteId});

  final FavoriteController controller;
  final String siteId;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final statusIndex = controller.tabOnlineIndex.value;
      final totalForSite = controller.favoriteCountForSite(siteId);
      final globalTotal = SettingsService.to.fav.favoriteRooms.v.length;
      final offlineForSite = controller.favoriteCountForSite(siteId, statusIndex: 3);

      if (globalTotal == 0) {
        return AppStatusView(
          type: AppStatusType.empty,
          icon: Remix.heart_3_fill,
          title: i18n('empty_favorite_online_title'),
          subtitle: i18n('empty_favorite_online_subtitle'),
          buttonText: i18n('retry'),
          onButtonPressed: controller.refreshData,
        );
      }

      // 暂弃Tab空状态：提示用工具栏"+"按钮添加
      if (statusIndex == 4) {
        return AppStatusView(
          type: AppStatusType.empty,
          icon: Remix.archive_line,
          title: '暂时弃用列表为空',
          subtitle: '点击工具栏的"+"按钮，选择要移入暂时弃用的直播间',
        );
      }

      final title = switch (statusIndex) {
        1 => i18n('favorite_empty_online_title'),
        2 => i18n('favorite_empty_recording_title'),
        3 => i18n('favorite_empty_offline_title'),
        _ => i18n('favorite_empty_online_title'),
      };
      final subtitleKey = totalForSite == 0 ? 'favorite_empty_platform_subtitle' : 'favorite_empty_filter_subtitle';
      final subtitle = i18n(subtitleKey).replaceAll('{count}', totalForSite.toString());
      final canShowOffline = statusIndex != 3 && offlineForSite > 0;

      return AppStatusView(
        type: AppStatusType.empty,
        icon: Remix.heart_3_fill,
        title: title,
        subtitle: subtitle,
        buttonText: canShowOffline ? i18n('favorite_show_offline') : i18n('retry'),
        onButtonPressed: canShowOffline ? () => controller.animateToStatusIndex(3) : controller.refreshData,
      );
    });
  }
}
