import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

@visibleForTesting
bool shouldWrapFavoritePullToRefresh({required double viewportWidth, required bool isMobilePlatform}) {
  // 对齐开发版：桌面/移动、任意宽度一律包裹 EasyRefresh 下拉刷新。
  // 桌面端鼠标拖拽由全局 MyCustomScrollBehavior.dragDevices（含 mouse）提供。
  // 参数保留与开发版签名一致，便于后续按需恢复条件。
  return true;
}

class RoomGridView extends GetView<FavoriteController> {
  const RoomGridView({
    super.key,
    required this.siteId,
    required this.scrollController,
    required this.displayList,
    this.emptyBuilder,
  });

  final String siteId;
  final ScrollController scrollController;
  final List<LiveRoom> displayList;
  final WidgetBuilder? emptyBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraint) {
        final width = constraint.maxWidth;
        return Obx(() {
          final dense = SettingsService.to.app.enableDenseFavorites.v;
          final spacing = SettingsService.to.theme.crossAxisSpacing.v;
          final mainAxisSpacing = SettingsService.to.theme.mainAxisSpacing.v;
          final isVerifyingFavorites = controller.isVerifyingFavorites.value;
          // 置顶判定（5.2）：enablePinned 开关 + 首位标签即置顶标签。
          // pinTagId 在 Obx 作用域内读取，置顶切换（标签重排）时可触发重排。
          final enablePinned = controller.enablePinned.v;
          final tagController = Get.isRegistered<TagManagementController>()
              ? Get.find<TagManagementController>()
              : null;
          final pinTagId = tagController?.pinTagId;
          var crossAxisCount = width > 1280 ? 4 : (width > 960 ? 3 : (width > 640 ? 2 : 1));
          if (dense) {
            crossAxisCount = width > 1280 ? 5 : (width > 960 ? 4 : (width > 640 ? 3 : 2));
          }

          Widget buildScrollable(ScrollPhysics physics) {
            if (displayList.isEmpty) {
              return CustomScrollView(
                controller: scrollController,
                physics: physics,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child:
                        emptyBuilder?.call(context) ??
                        AppStatusView(
                          type: AppStatusType.empty,
                          icon: Icons.favorite_rounded,
                          title: i18n('empty_favorite_online_title'),
                          subtitle: i18n('empty_favorite_online_subtitle'),
                        ),
                  ),
                ],
              );
            }

            final itemWidth = (width - 24 - spacing * (crossAxisCount - 1)) / crossAxisCount;
            return GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              controller: scrollController,
              physics: physics,
              scrollCacheExtent: ScrollCacheExtent.pixels(width > 680 ? 480 : 320),
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: true,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: spacing,
                mainAxisSpacing: mainAxisSpacing,
                mainAxisExtent: itemWidth * 9 / 16 + (dense ? 50 : 62),
              ),
              itemCount: displayList.length,
              itemBuilder: (context, index) {
                final room = displayList[index];
                final isPinned =
                    enablePinned && pinTagId != null && tagController!.getTagsForRoom(room).contains(pinTagId);
                return RoomCard(
                  key: ValueKey('${room.platform}:${room.roomId}'),
                  room: room,
                  dense: dense,
                  statusPending: isVerifyingFavorites || room.isLiveStatusPending,
                  statusPendingLabel: isVerifyingFavorites
                      ? i18n('favorite_status_verifying')
                      : i18n('favorite_status_unknown'),
                  isPinned: isPinned,
                );
              },
            );
          }

          if (!shouldWrapFavoritePullToRefresh(viewportWidth: width, isMobilePlatform: PlatformUtils.isMobile)) {
            return buildScrollable(const PureLiveScrollPhysics(parent: AlwaysScrollableScrollPhysics()));
          }

          // EasyRefresh must own the exact physics installed on the vertical
          // child. Supplying PureLiveScrollPhysics directly made Android's
          // outer ClampingScrollPhysics consume boundary movement before the
          // refresh header could observe it, so the callback existed while the
          // pull animation never armed.
          return buildFavoritePullToRefresh(
            siteId: siteId,
            onRefresh: controller.refreshData,
            childBuilder: (_, physics) => buildScrollable(physics),
          );
        });
      },
    );
  }
}

@visibleForTesting
Widget buildFavoritePullToRefresh({
  required String siteId,
  required Future<void> Function() onRefresh,
  required ERChildBuilder childBuilder,
}) {
  return EasyRefresh.builder(
    key: ValueKey('favorite_pull_to_refresh_$siteId'),
    header: MaterialHeader(
      key: ValueKey('favorite_pull_to_refresh_indicator_$siteId'),
      triggerOffset: 72,
      triggerWhenRelease: true,
      clamping: true,
    ),
    triggerAxis: Axis.vertical,
    onRefresh: onRefresh,
    childBuilder: childBuilder,
  );
}
