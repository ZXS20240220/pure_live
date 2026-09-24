import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/common/widgets/room_card_compact.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';
import 'package:pure_live/routes/app_navigation.dart';

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
          // 紧凑布局：列表式（无封面），高度固定，可排更多列。
          final isCompact = controller.cardLayoutMode.v == 'compact';
          final crossAxisCount = switch ((isCompact, dense)) {
            (true, true) => width > 1280 ? 5 : (width > 960 ? 4 : (width > 640 ? 3 : 2)),
            (true, false) => width > 1280 ? 4 : (width > 960 ? 3 : (width > 640 ? 2 : 1)),
            (false, true) => width > 1280 ? 5 : (width > 960 ? 4 : (width > 640 ? 3 : 2)),
            (false, false) => width > 1280 ? 4 : (width > 960 ? 3 : (width > 640 ? 2 : 1)),
          };

          // 暂弃卡片刷新动画状态快照：必须在 Obx builder 的同步作用域内读取
          // （toSet() 经 value getter → reportRead() 注册依赖），add/remove 才能触发
          // 重建。buildScrollable 经 EasyRefresh 的 childBuilder、itemBuilder 经
          // GridView.builder 都是懒回调，在其中读取 Rx 不注册依赖——通知无人
          // 接收，刷新动画将永久卡死。
          final refreshingDormantKeysSnapshot = controller.refreshingDormantKeys.toSet();

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
            // 紧凑布局固定高度（52px 大头像 + 上下留白，与换台面板列表卡片一致），
            // 标准布局按 16:9 封面 + 信息栏高度计算。
            const compactCardHeight = 66.0;
            final mainAxisExtent = isCompact ? compactCardHeight : itemWidth * 9 / 16 + (dense ? 50 : 62);

            // 紧凑布局动态分页：每页数量 = 视口可完整容纳的卡片数（行数×列数），
            // 下限 10 由 applyCompactPageSize 内部保证；标准布局恢复设置值。
            if (isCompact) {
              final rowExtent = compactCardHeight + mainAxisSpacing;
              final rows = ((constraint.maxHeight - 8 + mainAxisSpacing) / rowExtent).floor();
              controller.applyCompactPageSize(rows.clamp(1, 999) * crossAxisCount);
            } else {
              controller.applyCompactPageSize(null);
            }

            // 暂弃 Tab 下卡片特殊处理：显示删除按钮；左键点击刷新该房间状态。
            final isDormantTab = controller.tabOnlineIndex.value == 4;

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
                mainAxisExtent: mainAxisExtent,
              ),
              itemCount: displayList.length,
              itemBuilder: (context, index) {
                final room = displayList[index];
                final isPinned =
                    enablePinned && pinTagId != null && tagController!.getTagsForRoom(room).contains(pinTagId);
                final statusPending = isVerifyingFavorites || room.isLiveStatusPending;
                final statusPendingLabel = isVerifyingFavorites
                    ? i18n('favorite_status_verifying')
                    : i18n('favorite_status_unknown');
                if (isCompact) {
                  return RoomCardCompact(
                    key: ValueKey('${room.platform}:${room.roomId}'),
                    room: room,
                    statusPending: statusPending,
                    statusPendingLabel: statusPendingLabel,
                    isPinned: isPinned,
                    isDormant: isDormantTab,
                    onDelete: isDormantTab ? () => controller.restoreSingleFromDormant(room) : null,
                    onTapOverride: isDormantTab ? (ctx) => _handleDormantCardTap(ctx, room) : null,
                    dormantRefreshing: refreshingDormantKeysSnapshot.contains(room.identityKey),
                  );
                }
                return RoomCard(
                  key: ValueKey('${room.platform}:${room.roomId}'),
                  room: room,
                  dense: dense,
                  statusPending: statusPending,
                  statusPendingLabel: statusPendingLabel,
                  isPinned: isPinned,
                  isDormant: isDormantTab,
                  showDelete: isDormantTab,
                  onDelete: isDormantTab ? () => controller.restoreSingleFromDormant(room) : null,
                  onTapOverride: isDormantTab ? (ctx) => _handleDormantCardTap(ctx, room) : null,
                  dormantRefreshing: refreshingDormantKeysSnapshot.contains(room.identityKey),
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

  /// 暂弃卡片左键点击：先对该房间发起一次详情请求获取最新状态（留存数据
  /// 随之更新）；若刷新后正在直播，弹窗询问是否移出暂时弃用——确认后移出
  /// 并打开直播间（跳过移出时的重复刷新），取消则保持在暂弃分类。
  Future<void> _handleDormantCardTap(BuildContext context, LiveRoom room) async {
    final refreshed = await controller.refreshDormantRoomOnce(room);
    if (!context.mounted || refreshed == null || !refreshed.isLiveNow) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: Theme.of(dialogCtx).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            i18n('live'),
            style: AppTextStyles.t16.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(dialogCtx).colorScheme.onSurface,
            ),
          ),
          content: Text(
            '${(refreshed.nick?.trim().isNotEmpty ?? false) ? refreshed.nick! : '该主播'} '
            '正在直播中，是否将其移出暂时弃用并打开直播间？',
            style: AppTextStyles.t13.copyWith(color: Theme.of(dialogCtx).colorScheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: Text(i18n('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(dialogCtx, true), child: Text(i18n('confirm'))),
          ],
        );
      },
    );
    if (confirmed != true) return;

    await controller.restoreRoomsFromDormant([refreshed], refreshAfter: false);
    AppNavigator.toLiveRoomDetail(liveRoom: refreshed);
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
