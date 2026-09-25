import 'package:flutter/gestures.dart';
import 'package:remixicon/remixicon.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/areas/widgets/area_card.dart';
import 'package:pure_live/modules/areas/areas_list_controller.dart';

class AreaGridView extends StatefulWidget {
  final String tag;
  const AreaGridView(this.tag, {super.key});
  AreasListController get controller => Get.find<AreasListController>(tag: tag);

  bool get isFlatten => tag == Sites.douyinSite;

  @override
  State<AreaGridView> createState() => _AreaGridViewState();
}

class _AreaGridViewState extends State<AreaGridView> with TickerProviderStateMixin {
  TabController? _tabController;
  Worker? _listWorker;
  final Map<String, ScrollController> _categoryScrollControllers = {};
  final Set<ScrollController> _retiredScrollControllers = {};

  ScrollController _scrollControllerFor(String categoryId) =>
      _categoryScrollControllers.putIfAbsent(categoryId, () => createPureLiveScrollController());

  @override
  void initState() {
    super.initState();
    if (!widget.isFlatten) {
      _listWorker = ever(widget.controller.categories, (_) => _createTabController());
      _createTabController();
      widget.controller.tabIndex.addListener(_handleExternalIndexChange);
    }
  }

  void _createTabController() {
    if (widget.isFlatten) return;
    final list = widget.controller.categories;
    final recreateTabs = _tabController?.length != list.length;
    if (recreateTabs || list.isEmpty) {
      _tabController?.removeListener(_handleInternalTabChange);
      _tabController?.dispose();
      _tabController = null;
    }

    if (list.isEmpty) {
      widget.controller.bindActiveScrollController(null);
    } else {
      int initialIndex = widget.controller.tabIndex.value;
      if (initialIndex < 0 || initialIndex >= list.length) initialIndex = 0;
      if (_tabController == null) {
        _tabController = TabController(
          length: list.length,
          vsync: this,
          initialIndex: initialIndex,
          animationDuration: pureLiveTabTransitionDuration,
        );
        _tabController!.addListener(_handleInternalTabChange);
      }
      // Equal lengths do not imply equal category identities. Rebind even
      // when the tab animation controller can be reused.
      widget.controller.bindActiveScrollController(_scrollControllerFor(list[initialIndex].id));
    }
    _retireRemovedCategories(list.map((category) => category.id).toSet());

    if (mounted && (recreateTabs || list.isEmpty)) setState(() {});
  }

  void _retireRemovedCategories(Set<String> retainedIds) {
    final removedIds = _categoryScrollControllers.keys.where((id) => !retainedIds.contains(id)).toList();
    if (removedIds.isEmpty) return;
    final removed = removedIds.map((id) => _categoryScrollControllers.remove(id)!).toList();
    _retiredScrollControllers.addAll(removed);
    // The old PageView children detach during the next layout. Release their
    // controllers afterwards, rather than disposing a still-mounted position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in removed) {
        if (_retiredScrollControllers.remove(controller)) controller.dispose();
      }
    });
  }

  void _handleInternalTabChange() {
    if (_tabController == null || _tabController!.indexIsChanging) return;
    final animationValue = _tabController!.animation?.value ?? _tabController!.index.toDouble();
    if ((animationValue - _tabController!.index).abs() > 0.001) return;
    final target = _tabController!.index;
    final categories = widget.controller.categories;
    if (target < 0 || target >= categories.length) return;
    widget.controller.bindActiveScrollController(_scrollControllerFor(categories[target].id));
    if (widget.controller.tabIndex.value != target) {
      // Category data is already local. Commit only after the horizontal
      // gesture settles, and bind the destination's dedicated controller so
      // offsets never leak between PageView children.
      widget.controller.selectCategory(target);
    }
  }

  void _handleExternalIndexChange() {
    if (_tabController == null) return;
    final targetIndex = widget.controller.tabIndex.value;
    final categories = widget.controller.categories;
    if (targetIndex < 0 || targetIndex >= categories.length) return;
    widget.controller.bindActiveScrollController(_scrollControllerFor(categories[targetIndex].id));
    if (_tabController!.index != targetIndex && targetIndex < _tabController!.length) {
      _tabController!.animateTo(targetIndex);
    }
  }

  @override
  void dispose() {
    if (!widget.isFlatten) {
      widget.controller.bindActiveScrollController(null);
      widget.controller.tabIndex.removeListener(_handleExternalIndexChange);
      _listWorker?.dispose();
      if (_tabController != null) {
        _tabController!.removeListener(_handleInternalTabChange);
        _tabController!.dispose();
      }
    }
    for (final controller in _categoryScrollControllers.values) {
      controller.dispose();
    }
    _categoryScrollControllers.clear();
    for (final controller in _retiredScrollControllers) {
      controller.dispose();
    }
    _retiredScrollControllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isFlatten) {
      return BasePageView<AreasListController, LiveArea>(
        controller: widget.controller,
        wrapMobileRefresh: false,
        enableRefresh: true,
        enableLoadMore: true,
        customMobileBottomPadding: 85,
        customDesktopBottomPadding: 135,
        showScrollToTopBtn: false,
        showPageSizeSelector: false,
        pageSizeOptions: SettingsService.to.page.pageSizeOptions,
        emptyBuilder: (context) => EmptyView(
          icon: Remix.apps_2_line,
          title: i18n("empty_areas_title"),
          subtitle: i18n("empty_areas_subtitle"),
        ),
        contentBuilder: (context, displayList, scrollController) {
          // 对齐关注页：桌面/移动、任意宽度一律包裹 EasyRefresh 下拉刷新。
          return buildCommonPullToRefresh(
            refreshKey: 'area_flatten_${widget.tag}',
            onRefresh: widget.controller.refreshData,
            childBuilder: (_, physics) => buildFlattenAreasView(displayList, scrollController, physics: physics),
          );
        },
      );
    }

    return Obx(() {
      final categoriesList = widget.controller.categories;

      if (categoriesList.isEmpty || _tabController == null || _tabController!.length != categoriesList.length) {
        return BasePageView<AreasListController, LiveArea>(
          controller: widget.controller,
          enableRefresh: true,
          enableLoadMore: false,
          showPageSizeSelector: false,
          pageSizeOptions: SettingsService.to.page.pageSizeOptions,
          emptyBuilder: (context) => EmptyView(
            icon: Remix.apps_2_line,
            title: i18n("empty_areas_title"),
            subtitle: i18n("empty_areas_subtitle"),
            buttonText: i18n('refresh'),
            onButtonPressed: () => widget.controller.refreshData(),
          ),
          contentBuilder: (context, displayList, scrollController) {
            return const SizedBox.shrink();
          },
        );
      }

      return Column(
        children: [
          Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              final ctrl = _tabController;
              if (ctrl == null || ctrl.length == 0) return;
              final dir = event.scrollDelta.dy > 0 ? 1 : -1;
              final next = (ctrl.index + dir) % ctrl.length;
              ctrl.animateTo(next);
            },
            child: TabBar(
              key: const ValueKey('area-category-tabs'),
              controller: _tabController,
              // A tap is committed intent, unlike an unfinished horizontal drag.
              // Publish it before a refresh response can remap category indices.
              onTap: widget.controller.selectCategory,
              isScrollable: true,
              physics: const PureLiveBoundedScrollPhysics(),
              tabs: categoriesList.map((e) => Tab(text: e.name)).toList(),
            ),
          ),
          Expanded(
            child: BasePageView<AreasListController, LiveArea>(
              controller: widget.controller,
              // An empty category must not dispose the surrounding horizontal pages.
              preserveContentWhenEmpty: true,
              wrapMobileRefresh: false,
              enableRefresh: true,
              enableLoadMore: true,
              customMobileBottomPadding: 85,
              customDesktopBottomPadding: 135,
              showScrollToTopBtn: false,
              showPageSizeSelector: false,
              pageSizeOptions: SettingsService.to.page.pageSizeOptions,
              emptyBuilder: (context) => EmptyView(
                icon: Remix.apps_2_line,
                title: i18n("empty_areas_title"),
                subtitle: i18n("empty_areas_subtitle"),
              ),
              contentBuilder: (context, displayList, _) {
                final activeIndex = widget.controller.tabIndex.value;
                return TabBarView(
                  controller: _tabController,
                  physics: const PureLiveBoundedScrollPhysics(),
                  children: categoriesList.asMap().entries.map((entry) {
                    final category = entry.value;
                    return Builder(
                      key: ValueKey('area_page_${category.id}'),
                      builder: (context) {
                        final isCurrentTab = activeIndex == entry.key;
                        final finalData = widget.controller.usesDesktopPagination && isCurrentTab
                            ? displayList
                            : category.children;
                        if (finalData.isEmpty) {
                          return LayoutBuilder(
                            builder: (context, constraints) => buildCommonPullToRefresh(
                              refreshKey: 'area_empty_${widget.tag}_${category.id}',
                              onRefresh: widget.controller.refreshData,
                              childBuilder: (_, physics) => SingleChildScrollView(
                                key: PageStorageKey('area_empty_${widget.tag}_${category.id}'),
                                controller: _scrollControllerFor(category.id),
                                // Inherit EasyRefresh physics, like the populated grid.
                                physics: physics,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                  child: Center(
                                    child: EmptyView(
                                      icon: Remix.apps_2_line,
                                      title: i18n("empty_areas_title"),
                                      subtitle: i18n("empty_areas_subtitle"),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        return buildCommonPullToRefresh(
                          refreshKey: 'area_grid_${widget.tag}_${category.id}',
                          onRefresh: widget.controller.refreshData,
                          childBuilder: (_, physics) => buildFlattenAreasView(
                            finalData,
                            _scrollControllerFor(category.id),
                            scrollKey: PageStorageKey('area_grid_${widget.tag}_${category.id}'),
                            physics: physics,
                          ),
                        );
                      },
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      );
    });
  }

  Widget buildFlattenAreasView(
    List<LiveArea> childrenList,
    ScrollController scrollController, {
    Key? scrollKey,
    ScrollPhysics? physics,
  }) {
    return LayoutBuilder(
      builder: (context, constraint) {
        final width = constraint.maxWidth;
        final crossAxisCount =width > 1365
            ? 15
            :  (width > 1170
            ? 13
            : (width > 975 ? 11 : (width > 780 ? 9 : (width > 585 ? 7 : (width > 390 ? 5 : 3)))));
        final spacing = SettingsService.to.theme.crossAxisSpacing.v;
        final mainAxisSpacing = SettingsService.to.theme.mainAxisSpacing.v;
        final itemWidth = (width - 12 - spacing * (crossAxisCount - 1)) / crossAxisCount;
        // 卡片高度 = 图片宽度（1:1）+ 信息区 40（与 area_card.dart 手动文字
        // 布局的实际高度一致：Padding 上下 10 + 两行文字 + 行间距 2），可微调。
        final mainAxisExtent = itemWidth + 40;

        // 动态分页（对齐关注页列表布局）：每页数量 = 视口可完整容纳的行数 ×
        // 每行列数，不再使用设置中的每页数量；下限 10 由 applyViewportPageSize
        // 保证。10 = 网格纵向内边距（上 4 + 下 6）。
        final rowExtent = mainAxisExtent + mainAxisSpacing;
        final rows = ((constraint.maxHeight - 10 + mainAxisSpacing) / rowExtent).floor();
        widget.controller.applyViewportPageSize(rows.clamp(1, 999) * crossAxisCount);

        return GridView.builder(
          key: scrollKey,
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 40),
          controller: scrollController,
          physics: physics,
          scrollCacheExtent: ScrollCacheExtent.pixels(width > 680 ? 480 : 320),
          addAutomaticKeepAlives: false,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: mainAxisSpacing,
            mainAxisExtent: mainAxisExtent,
          ),
          itemCount: childrenList.length,
          itemBuilder: (context, index) {
            final area = childrenList[index];
            return AreaCard(key: ValueKey('${area.platform}:${area.areaId}'), category: area);
          },
        );
      },
    );
  }
}
