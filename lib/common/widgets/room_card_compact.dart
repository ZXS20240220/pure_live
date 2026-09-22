import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:pure_live/routes/app_navigation.dart';
import 'package:remixicon/remixicon.dart';

/// 关注页紧凑列表式卡片：无封面图，左侧头像跨行，中间主播名+标题，右侧状态标志。
///
/// 与 [RoomCard] 并列存在——两者结构差异大（封面 vs 无封面、ListTile leading
/// vs 独立 Row），分文件维护更清晰。右键/长按行为复用 RoomCard 的静态方法，
/// 保证两种布局交互一致。
class RoomCardCompact extends StatelessWidget {
  const RoomCardCompact({
    super.key,
    required this.room,
    this.statusPending = false,
    this.statusPendingLabel,
    this.isPinned = false,
  });

  final LiveRoom room;
  final bool statusPending;
  final String? statusPendingLabel;

  /// 是否判定为置顶房间（由调用方按关注页置顶开关 + 置顶标签计算）。
  final bool isPinned;

  void onTap(BuildContext context) => AppNavigator.toLiveRoomDetail(liveRoom: room);

  void onLongPress(BuildContext context) => RoomCard.showRoomInfoDialog(context, room);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onTap(context),
        onLongPress: () => onLongPress(context),
        onSecondaryTap: () => onLongPress(context),
        child: SizedBox(
          height: 76,
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // 左侧跨行头像。
                    CommonAvatar(avatarUrl: room.avatar, fallbackName: room.nick, radius: 24, dense: false),
                    const SizedBox(width: 12),
                    // 中间两行：主播名 + 直播间标题。
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Tooltip(
                            message: room.nick ?? '',
                            waitDuration: const Duration(milliseconds: 400),
                            child: Text(
                              room.nick ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: AppTextStyles.t14.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Tooltip(
                            message: room.title ?? '',
                            waitDuration: const Duration(milliseconds: 400),
                            child: Text(
                              room.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: AppTextStyles.t12.copyWith(
                                fontWeight: FontWeight.w500,
                                color: isDark ? Colors.grey[400] : Colors.grey[600],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 右侧状态标志。
                    _buildStatusBadge(context, theme, isDark),
                  ],
                ),
              ),
              // 右上角置顶徽章（受关注页置顶开关影响），小号适配 76 高卡片。
              if (isPinned)
                Positioned(
                  key: const ValueKey('room-card-compact-pin-badge'),
                  right: 6,
                  top: 6,
                  child: Tooltip(
                    message: i18n('favorite_pinned_badge'),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(RemixIcons.pushpin_fill, color: Theme.of(context).colorScheme.onPrimary, size: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(BuildContext context, ThemeData theme, bool isDark) {
    if (statusPending) {
      return _StatusDot(color: theme.colorScheme.surfaceContainerHighest, label: statusPendingLabel ?? '检测中');
    }

    final status = room.effectiveLiveStatus;
    final (color, label) = switch (status) {
      LiveStatus.live => (Colors.greenAccent.shade400, '直播中'),
      LiveStatus.replay => (Colors.orangeAccent.shade400, '录播'),
      LiveStatus.offline => (isDark ? Colors.grey.shade500 : Colors.grey.shade400, '未直播'),
      _ => (isDark ? Colors.grey.shade500 : Colors.grey.shade400, '未知'),
    };

    return _StatusDot(color: color, label: label);
  }
}

/// 紧凑卡片右侧的状态圆点 + 小标签。
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4, offset: const Offset(0, 1))],
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTextStyles.t11.copyWith(fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
