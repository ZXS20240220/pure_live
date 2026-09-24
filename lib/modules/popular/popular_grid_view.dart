import 'package:remixicon/remixicon.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pure_live/common/index.dart';

class PopularGridView extends StatelessWidget {
  final String tag;
  const PopularGridView(this.tag, {super.key});

  BasePageScrollAndStateBone<LiveRoom> get controller => Get.find<BasePageScrollAndStateBone<LiveRoom>>(tag: tag);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraint) {
        return BasePageView<BasePageScrollAndStateBone<LiveRoom>, LiveRoom>(
          controller: controller,
          wrapMobileRefresh: false,
          showScrollToTopBtn: SettingsService.to.page.showScrollToTopBtn.v,
          pageSizeOptions: SettingsService.to.page.pageSizeOptions,
          showPageSizeSelector: SettingsService.to.page.showPageSizeSelector.v,
          emptyBuilder: (c) => AppStatusView(
            type: AppStatusType.empty,
            icon: RemixIcons.fire_fill,
            title: i18n("empty_live_title"),
            subtitle: i18n("empty_live_subtitle"),
            buttonText: i18n('refresh'),
            onButtonPressed: () => controller.refreshData(),
          ),
          contentBuilder: (context, list, scrollController) {
            // 对齐关注页：桌面/移动、任意宽度一律包裹 EasyRefresh 下拉刷新，
            // 并将刷新容器给出的 physics 安装到实际滚动控件上。
            return buildCommonPullToRefresh(
              refreshKey: 'popular_$tag',
              onRefresh: controller.refreshData,
              childBuilder: (_, physics) => _buildRoomGrid(context, list, scrollController, physics),
            );
          },
        );
      },
    );
  }

  Widget _buildRoomGrid(
    BuildContext context,
    List<LiveRoom> list,
    ScrollController scrollController,
    ScrollPhysics physics,
  ) {
    return LayoutBuilder(
      builder: (context, constraint) {
        final width = constraint.maxWidth;
        final crossAxisCount = width > 1280 ? 5 : (width > 960 ? 4 : (width > 640 ? 3 : 2));
        final spacing = SettingsService.to.theme.crossAxisSpacing.v;
        final rows = (list.length + crossAxisCount - 1) ~/ crossAxisCount;
        // RoomCard owns its text metrics. A fixed 72-pixel caption area
        // clips scaled text; lazy natural-height rows retain the columns
        // without guessing font heights or suppressing accessibility scale.
        return CustomScrollView(
          controller: scrollController,
          physics: physics,
          scrollCacheExtent: ScrollCacheExtent.pixels(width > 680 ? 480 : 320),
          semanticChildCount: list.length,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, row) => Padding(
                    padding: EdgeInsets.only(bottom: row + 1 < rows ? SettingsService.to.theme.mainAxisSpacing.v : 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var column = 0; column < crossAxisCount; column++) ...[
                          if (column > 0) SizedBox(width: spacing),
                          Expanded(
                            child: row * crossAxisCount + column < list.length
                                ? RepaintBoundary(
                                    child: IndexedSemantics(
                                      index: row * crossAxisCount + column,
                                      child: RoomCard(
                                        key: ValueKey(
                                          '${list[row * crossAxisCount + column].platform}:${list[row * crossAxisCount + column].roomId}',
                                        ),
                                        room: list[row * crossAxisCount + column],
                                        dense: true,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  childCount: rows,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: false,
                  addSemanticIndexes: false,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
