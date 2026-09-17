import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
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
              actions: showAction ? [const CommonAppBarActions()] : null,
              title: TabBar(
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
                ],
              ),
            ),
            body: Stack(
              children: [
                _FavoriteSiteTabs(
                  key: siteKey,
                  controller: controller,
                  availableSitesList: availableSitesList,
                ),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Obx(() {
                    final count = controller.getFilteredRooms().length;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
                        ),
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
                            color: Theme.of(context).colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.75),
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
int resolveFavoriteSiteIndex({
  required List<String> siteIds,
  required String selectedSiteId,
  required int fallback,
}) {
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
      _siteScrollControllers.putIfAbsent(siteId, createPureLiveScrollController);

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
    widget.controller.bindActiveScrollController(
      _scrollControllerFor(widget.availableSitesList[initialIndex].id),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.selectSiteIndex(initialIndex);
    });
  }

  void _handleTabChanged() {
    final tabController = _tabController;
    if (tabController.indexIsChanging) return;
    final animationValue = tabController.animation?.value ?? tabController.index.toDouble();
    if ((animationValue - tabController.index).abs() > 0.001) return;
    final controller = widget.controller;
    if (tabController.index < 0 || tabController.index >= widget.availableSitesList.length) return;
    controller.bindActiveScrollController(
      _scrollControllerFor(widget.availableSitesList[tabController.index].id),
    );
    controller.selectSiteIndex(tabController.index);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final ctrlOrCmd =
        HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

    if (ctrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_searchController.text.isNotEmpty) {
          _searchController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _searchController.text.length,
          );
        }
      });
      return KeyEventResult.handled;
    }

    if (isEditingFocused()) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.tab:
        final tabs = widget.availableSitesList.length;
        if (tabs == 0) return KeyEventResult.ignored;
        final current = _tabController.index;
        final next = HardwareKeyboard.instance.isShiftPressed
            ? (current - 1 + tabs) % tabs
            : (current + 1) % tabs;
        _tabController.animateTo(next);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        final controller = widget.controller;
        if (controller.currentPage > 1 && !controller.loadding.value) {
          controller.goToPage(controller.currentPage - 1);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        final controller = widget.controller;
        if (controller.canLoadMore.value && !controller.loadding.value) {
          controller.goToPage(controller.currentPage + 1);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        _scrollPage(-1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        _scrollPage(1);
        return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _scrollPage(int direction) {
    final controller = widget.controller.scrollController;
    if (!controller.hasClients) return;
    final viewportHeight = controller.position.viewportDimension;
    final targetOffset = (controller.offset + direction * viewportHeight).clamp(
      0.0,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final availableSitesList = widget.availableSitesList;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Column(
        children: [
          Obx(() {
            final statusIndex = controller.tabOnlineIndex.value;
            return TabBar(
              key: const ValueKey('favorite-platform-tabs'),
              controller: _tabController,
              isScrollable: true,
              physics: const PureLiveBoundedScrollPhysics(),
              tabs: availableSitesList.map((e) {
                final count = controller.favoriteCountForSite(e.id, statusIndex: statusIndex);
                return Tab(text: '${e.name} ($count)');
              }).toList(),
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
                Obx(() {
                  // 观看时长排序对所有状态生效，排序按钮在所有页签下都可用。
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        onPressed: () =>
                            controller.enablePinned.value = !controller.enablePinned.value,
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
                          PopupMenuItem(
                            value: OnlineSortMode.audience,
                            child: Text(i18n('favorite_sort_audience')),
                          ),
                          PopupMenuItem(
                            value: OnlineSortMode.startTime,
                            child: Text(i18n('favorite_sort_start_time')),
                          ),
                          PopupMenuItem(
                            value: OnlineSortMode.watchTime,
                            child: Text(i18n('favorite_sort_watch_time')),
                          ),
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
                          color: Theme.of(context).colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.7),
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
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.35),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: BasePageView<FavoriteController, LiveRoom>(
              controller: controller,
              enableRefresh: true,
              enableLoadMore: true,
              wrapMobileRefresh: false,
              preserveContentWhenEmpty: true,
              keyboardPagingEnabled: false,
              showScrollToTopBtn: SettingsService.to.page.showScrollToTopBtn.v,
              showPageSizeSelector: SettingsService.to.page.showPageSizeSelector.v,
              pageSizeOptions: SettingsService.to.page.pageSizeOptions,
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
                        final pageList = isCurrentSite
                            ? list
                            : controller.filteredSyncedRoomsForSite(site.id);
                        return RoomGridView(
                          siteId: site.id,
                          scrollController: _scrollControllerFor(site.id),
                          displayList: pageList,
                          emptyBuilder: (context) =>
                              _FavoriteEmptyState(controller: controller, siteId: site.id),
                        );
                      },
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
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
              tooltip: isMulti
                  ? i18n('tag_multi_select_enabled')
                  : i18n('tag_multi_select_disabled'),
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
                                      color: isSelected
                                          ? colorScheme.onPrimary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              selected: isSelected,
                              selectedColor: colorScheme.tertiary,
                              backgroundColor: colorScheme.surfaceContainerHighest.withValues(
                                alpha: 0.08,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(
                                  color: isSelected
                                      ? Colors.transparent
                                      : colorScheme.outline.withValues(alpha: 0.35),
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
                                  color: isSelected
                                      ? colorScheme.onPrimary
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: colorScheme.primary,
                              backgroundColor: colorScheme.surfaceContainerHighest.withValues(
                                alpha: 0.15,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(
                                  color: isSelected
                                      ? Colors.transparent
                                      : theme.dividerColor.withValues(alpha: 0.04),
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

      final title = switch (statusIndex) {
        1 => i18n('favorite_empty_online_title'),
        2 => i18n('favorite_empty_recording_title'),
        3 => i18n('favorite_empty_offline_title'),
        _ => i18n('favorite_empty_online_title'),
      };
      final subtitleKey = totalForSite == 0
          ? 'favorite_empty_platform_subtitle'
          : 'favorite_empty_filter_subtitle';
      final subtitle = i18n(subtitleKey).replaceAll('{count}', totalForSite.toString());
      final canShowOffline = statusIndex != 3 && offlineForSite > 0;

      return AppStatusView(
        type: AppStatusType.empty,
        icon: Remix.heart_3_fill,
        title: title,
        subtitle: subtitle,
        buttonText: canShowOffline ? i18n('favorite_show_offline') : i18n('retry'),
        onButtonPressed: canShowOffline
            ? () => controller.animateToStatusIndex(3)
            : controller.refreshData,
      );
    });
  }
}
