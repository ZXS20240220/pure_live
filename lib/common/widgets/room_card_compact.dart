import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/room_card_settings_controller.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:pure_live/routes/app_navigation.dart';
import 'package:remixicon/remixicon.dart';

/// 关注页紧凑列表式卡片：无封面图，左侧头像跨行，中间主播名+标题，右侧状态行。
///
/// 复用 RoomCardSettingsController 的配置（showAvatar/showPlatformBadge/showAudience/
/// showPinBadge/cornerRadius），与 RoomCard 标准卡片共享同一套显示偏好。
/// 右侧状态内容：直播中显示热度值 → 非直播但有 startTime 显示上次直播时间 →
/// 再没有则 fallback 到"未直播/录播/已弃用"状态文字。
class RoomCardCompact extends StatelessWidget {
  const RoomCardCompact({
    super.key,
    required this.room,
    this.statusPending = false,
    this.statusPendingLabel,
    this.isPinned = false,
    this.isDormant = false,
    this.onDelete,
    this.onTapOverride,
    this.dormantRefreshing = false,
  });

  final LiveRoom room;
  final bool statusPending;
  final String? statusPendingLabel;

  /// 是否判定为置顶房间（由调用方按关注页置顶开关 + 置顶标签计算）。
  final bool isPinned;

  /// 是否为暂弃（下沉）房间：显示"已弃用"状态文字，隐藏置顶徽章，强制显示删除按钮；
  /// 左键点击默认刷新该房间状态（行为由 [onTapOverride] 决定）。
  final bool isDormant;

  /// 删除按钮回调（暂弃房间用于移出暂弃）。
  final VoidCallback? onDelete;

  /// 覆盖默认的左键打开行为（暂弃卡片点击时刷新状态而非直接进入直播间）。
  final void Function(BuildContext context)? onTapOverride;

  /// 暂弃卡片正在单次刷新：状态行以小转圈暂时替代"已弃用"文字。
  final bool dormantRefreshing;

  void onTap(BuildContext context) => AppNavigator.toLiveRoomDetail(liveRoom: room);

  void onLongPress(BuildContext context) => RoomCard.showRoomInfoDialog(context, room);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final config = SettingsService.to.roomCard.current;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final nick = room.nick ?? '';
      final title = room.title ?? '';
      final radius = config.cornerRadius;

      // pin 徽章：开关 + 判定 + 暂弃隐藏
      final showPin = config.showPinBadge && isPinned && !isDormant;
      // 右下角平台徽章：开关 + 暂弃房间也显示（方便识别）
      final showPlatform = config.showPlatformBadge;

      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => (onTapOverride ?? onTap)(context),
          onLongPress: () => onLongPress(context),
          onSecondaryTap: () => onLongPress(context),
          borderRadius: BorderRadius.circular(radius),
          child: Ink(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: SizedBox(
                height: 100,
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        children: [
                          // 左侧头像（可隐藏）。
                          if (config.showAvatar) ...[
                            CommonAvatar(avatarUrl: room.avatar, fallbackName: nick, radius: 26),
                            const SizedBox(width: 6),
                          ],
                          // 中间两行：主播名 + 直播间标题。
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Tooltip(
                                  message: nick.isEmpty ? i18n('unknown') : nick,
                                  waitDuration: const Duration(milliseconds: 400),
                                  child: Text(
                                    nick.isEmpty ? i18n('unknown') : nick,
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: isDormant ? Colors.grey[500] : colors.onSurface,
                                      height: 1.15,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Tooltip(
                                  message: title,
                                  waitDuration: const Duration(milliseconds: 400),
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: isDormant
                                          ? (isDark ? Colors.grey[600] : Colors.grey[500])
                                          : colors.onSurfaceVariant,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 右侧状态/热度/上次直播时间。
                          _buildTrailing(theme, isDark, config),
                          if (isDormant && onDelete != null) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              iconSize: 18,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              tooltip: '移出暂时弃用',
                              onPressed: onDelete,
                              icon: Icon(RemixIcons.archive_line, color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 右上角 pin 徽章。
                    if (showPin)
                      Positioned(
                        key: const ValueKey('room-card-compact-pin-badge'),
                        right: 6,
                        top: 4,
                        child: Tooltip(
                          message: i18n('favorite_pinned_badge'),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(
                              RemixIcons.pushpin_fill,
                              color: Theme.of(context).colorScheme.onPrimary,
                              size: 12,
                            ),
                          ),
                        ),
                      ),
                    // 右下角平台徽章（紧凑列表专用）。
                    if (showPlatform && room.platform != null)
                      Positioned(
                        key: const ValueKey('room-card-compact-platform-badge'),
                        right: 6,
                        bottom: 4,
                        child: _PlatformChip(platform: room.platform!),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  /// 右侧状态行：直播中 → 热度（开关控制）；非直播但有 startTime → 上次直播时间；
  /// 再没有 → 状态文字（未直播/录播/已弃用）。
  Widget _buildTrailing(ThemeData theme, bool isDark, RoomCardAppearance config) {
    if (isDormant) {
      // 单次刷新期间以小转圈暂时替代"已弃用"文字。
      if (dormantRefreshing) {
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
        );
      }
      return _StatusText(text: '已弃用', color: Colors.grey.shade500, theme: theme);
    }
    if (statusPending) {
      return _StatusText(
        text: statusPendingLabel ?? '检测中',
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .7),
        theme: theme,
      );
    }

    if (room.isLiveNow) {
      if (!config.showAudience) {
        // 开启热度但不在直播中，或者直播中但开关关了，都不占位显示空；
        // 但如果 showAudience 关了，直播中也没东西可显示，就留空。
        return const SizedBox.shrink();
      }
      final app = SettingsService.to.app;
      final value = room.audienceValue(
        preferRealOnline: app.preferRealOnlineCounts.v,
        platformEnabled: app.isRealOnlineEnabledFor(room.platform),
      );
      final text = value.isEmpty ? i18n('audience_unknown') : readableCount(value);
      return Tooltip(
        message: text,
        waitDuration: const Duration(milliseconds: 400),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.orangeAccent, height: 1.1),
        ),
      );
    }

    // 非直播状态：优先上次直播时间（如果配置允许且有数据）
    final ts = room.startTime;
    if (config.showLastLiveTime && ts != null && ts > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final y = dt.year;
      final mo = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      final h = dt.hour.toString().padLeft(2, '0');
      final mi = dt.minute.toString().padLeft(2, '0');
      final lastLive = '$y-$mo-$d $h:$mi';
      return Tooltip(
        message: '上次直播 $lastLive',
        waitDuration: const Duration(milliseconds: 400),
        // 限宽使截断点落在日期与时间的交界（日期完整、时间被截），
        // 避免挤压中间主播名/标题；调 maxWidth 可增减可见的时间字符。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 80),
          child: Text(
            lastLive,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .85),
              height: 1.1,
            ),
          ),
        ),
      );
    }

    // 都没有 —— fallback 状态文字
    final status = room.effectiveLiveStatus;
    final (text, color) = switch (status) {
      LiveStatus.replay => ('录播', isDark ? Colors.grey.shade500 : Colors.grey.shade400),
      LiveStatus.offline => ('未直播', isDark ? Colors.grey.shade500 : Colors.grey.shade400),
      _ => ('未知', isDark ? Colors.grey.shade500 : Colors.grey.shade400),
    };
    return _StatusText(text: text, color: color, theme: theme);
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.text, required this.color, required this.theme});
  final String text;
  final Color color;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
        style: AppTextStyles.t12.copyWith(fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// 紧凑列表平台胶囊：灰色底随深浅色适配（样式取自标准卡片原信息栏平台徽章）。
class _PlatformChip extends StatelessWidget {
  const _PlatformChip({required this.platform});
  final String platform;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        platform.toUpperCase(),
        style: AppTextStyles.t11.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.grey[300] : Colors.grey[800],
        ),
      ),
    );
  }
}
