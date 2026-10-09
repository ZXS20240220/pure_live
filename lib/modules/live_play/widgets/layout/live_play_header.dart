import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:pure_live/common/utils/live_url_tool.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/dialogs/play_other.dart';
import 'package:pure_live/modules/live_play/widgets/button/record_action_button.dart';
import 'package:pure_live/modules/live_play/widgets/button/live_play_menu_button.dart';
import 'package:pure_live/modules/live_play/widgets/button/favorite_floating_button.dart';
import 'package:pure_live/modules/multiview/widgets/multiview_room_search_panel.dart';
import 'package:pure_live/modules/live_play/widgets/resolution_selector/audience_info.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

class LivePlayHeader extends StatefulWidget implements PreferredSizeWidget {
  const LivePlayHeader({super.key, required this.controller, this.compactHeader = false});
  final LivePlayController controller;
  final bool compactHeader;

  /// 5 个快捷按钮（设置标签、打开直播间、切换直播间、获取直链、搜索房间）
  /// 需要的最小窗口宽度。窗口宽度小于该值时折叠进菜单。
  static const double _kQuickActionsMinWidth = 880.0;

  /// 左侧信息栏逐级隐藏阈值（宽度减小时依次隐藏）。
  /// 仅头像 + 主播名始终保留。
  static const double _kAreaMinWidth = 560.0; // 分类信息
  static const double _kTimeIndicatorsMinWidth = 500.0; // 观看时长 + 已播时长
  static const double _kLevelUnionMinWidth = 440.0; // 等级 + 工会

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  State<LivePlayHeader> createState() => _LivePlayHeaderState();
}

class _LivePlayHeaderState extends State<LivePlayHeader> {
  DateTime? _lastTapDownTime;
  Offset? _lastTapDownPosition;

  static const Duration _kDoubleTapTimeout = Duration(milliseconds: 300);
  static const double _kDoubleTapSlop = 20.0;

  /// 使用 Listener 手动检测双击，避免 GestureDetector.onDoubleTap
  /// 通过竞技场 hold 机制导致内层按钮单击延迟 ~300ms。
  void _handlePointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    final lastTime = _lastTapDownTime;
    final lastPosition = _lastTapDownPosition;

    if (lastTime != null && lastPosition != null) {
      final isWithinTimeout = now.difference(lastTime) < _kDoubleTapTimeout;
      final isWithinSlop = (event.position - lastPosition).distance < _kDoubleTapSlop;
      if (isWithinTimeout && isWithinSlop) {
        _toggleMaximize();
        _lastTapDownTime = null;
        _lastTapDownPosition = null;
        return;
      }
    }

    _lastTapDownTime = now;
    _lastTapDownPosition = event.position;
  }

  void _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showQuickActions = width >= LivePlayHeader._kQuickActionsMinWidth;

        return Listener(
          onPointerDown: _handlePointerDown,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowManager.startDragging(),
            child: AppBar(
              toolbarHeight: 50,
              titleSpacing: 0,
              title: _buildTitle(context, width),
              actions: [
                _buildAudienceInfo(),
                _buildFavoriteButton(),
                _buildRecordButton(),
                if (showQuickActions) _buildQuickActions(context),
                if (showQuickActions) _buildSearchRoomsButton(context),
                LivePlayMenuButton(controller: widget.controller),
                const SizedBox(width: 4),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTitle(BuildContext context, double width) {
    final showArea = width >= LivePlayHeader._kAreaMinWidth;
    final showTimeIndicators = width >= LivePlayHeader._kTimeIndicatorsMinWidth;
    final showLevelUnion = width >= LivePlayHeader._kLevelUnionMinWidth;

    return Row(
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              final detail = widget.controller.state.value.room.detail;
              if (detail != null) RoomCard.showRoomInfoDialog(context, detail);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() {
                  final avatar = widget.controller.state.value.room.detail?.avatar;
                  return CircleAvatar(
                    radius: 16,
                    foregroundImage: avatar != null && avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                    backgroundColor: Theme.of(context).disabledColor,
                  );
                }),
                const SizedBox(width: 8),
                Flexible(
                  child: Obx(() {
                    final detail = widget.controller.state.value.room.detail;
                    if (detail == null) {
                      return const SizedBox.shrink();
                    }
                    final platform = detail.platform ?? '';
                    final area = detail.area;
                    final anchorLevel = detail.anchorLevel?.trim() ?? '';
                    final unionName = detail.unionName?.trim() ?? '';
                    final hasLevel = anchorLevel.isNotEmpty;
                    final hasUnion = unionName.isNotEmpty;

                    final introduction = detail.introduction?.trim() ?? '';
                    final hasIntroduction = introduction.isNotEmpty;

                    // IP属地 — only douyin fills LiveRoom.location today.
                    final anchorLocation = detail.location?.trim() ?? '';

                    final textColumn = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                detail.nick ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                            if (anchorLocation.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              Flexible(
                                child: Tooltip(
                                  message: 'IP属地',
                                  verticalOffset: 8,
                                  child: Text(
                                    anchorLocation,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (showArea)
                          Text(
                            area == null || area.isEmpty ? i18n('site_$platform') : '${i18n("site_$platform")} / $area',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                      ],
                    );

                    final infoColumn = Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (showLevelUnion && (hasLevel || hasUnion))
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasLevel)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.shade800.withValues(alpha: 0.85),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    'Lv.$anchorLevel',
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(color: Colors.white, fontSize: 10, height: 1.1),
                                  ),
                                ),
                              if (hasLevel && hasUnion) const SizedBox(height: 2),
                              if (hasUnion)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.blueGrey.shade700.withValues(alpha: 0.8),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    unionName,
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(color: Colors.white70, fontSize: 10, height: 1.1),
                                  ),
                                ),
                            ],
                          ),
                        if (showLevelUnion && (hasLevel || hasUnion)) const SizedBox(width: 4),
                        Flexible(
                          child: hasIntroduction
                              ? Tooltip(message: introduction, verticalOffset: 8, child: textColumn)
                              : textColumn,
                        ),
                      ],
                    );

                    return infoColumn;
                  }),
                ),
                Obx(() {
                  final detail = widget.controller.state.value.room.detail;
                  if (detail == null) return const SizedBox.shrink();
                  if (!showTimeIndicators) return const SizedBox.shrink();
                  if (!detail.isLiveNow) return const SizedBox.shrink();
                  var startTime = detail.startTime;
                  // 观看时长在已播时长上方堆叠；各自内部控制可见性。
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _WatchTimeIndicator(identityKey: detail.identityKey),
                      if (startTime != null && startTime > 0) _LiveDurationIndicator(startTime: startTime),
                    ],
                  );
                }),
              ],
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  /// 沉浸模式下侧栏顶部不再展示热度区域，改在顶栏关注按钮左侧显示。
  Widget _buildAudienceInfo() {
    return Obx(() {
      if (!SettingsService.to.player.enableImmersiveLayout.v) {
        return const SizedBox.shrink();
      }
      return const Padding(padding: EdgeInsets.only(right: 6), child: AudienceInfo());
    });
  }

  Widget _buildFavoriteButton() {
    return Obx(() {
      final roomState = widget.controller.state.value.room;
      final detail = roomState.detail;
      if (detail == null) {
        return const SizedBox.shrink();
      }
      final awaitingCanonicalIdentity =
          roomState.isLoading && (detail.nick?.trim().isEmpty ?? true) && (detail.title?.trim().isEmpty ?? true);
      if (awaitingCanonicalIdentity) {
        return const SizedBox(
          width: 47,
          child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(left: 2, right: 5),
        child: FavoriteFloatingButton(
          key: ValueKey('${detail.platform}:${detail.roomId}'),
          room: detail,
          compact: widget.compactHeader,
        ),
      );
    });
  }

  Widget _buildQuickActions(BuildContext context) {
    return Obx(() {
      final detail = widget.controller.state.value.room.detail;
      if (detail == null) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 开发版 3.2：header 快捷操作首位「设置房间标签」按钮。
          // 基础版无 RoomCardController，复用 RoomCard 静态化的标签选择弹窗。
          Tooltip(
            message: i18n('set_room_tags'),
            child: IconButton(
              icon: const Icon(Remix.price_tag_3_line),
              onPressed: () {
                final tagController = Get.find<TagManagementController>();
                unawaited(RoomCard.showTagSelectionGridModal(context, Theme.of(context), tagController, detail));
              },
            ),
          ),
          Tooltip(
            message: i18n('open_live_room'),
            child: IconButton(
              icon: const Icon(Icons.open_in_browser_rounded),
              onPressed: () => widget.controller.openNaviteAPP(),
            ),
          ),
          Tooltip(
            message: i18n('switch_live_room'),
            child: IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              onPressed: () => Get.dialog(PlayOther(controller: widget.controller)),
            ),
          ),
          Tooltip(
            message: i18n('toolbox_get_direct_link'),
            child: IconButton(
              icon: const Icon(Remix.link_m),
              onPressed: () => LiveUrlTool.getPlayUrlByRoomId(
                context: context,
                roomId: detail.roomId ?? '',
                platform: detail.platform ?? '',
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildSearchRoomsButton(BuildContext context) {
    return Tooltip(
      message: i18n('multiview_search_rooms'),
      child: IconButton(
        icon: const Icon(Remix.search_2_line),
        onPressed: () {
          final layout = MediaQuery.sizeOf(context);
          final maxWidth = layout.width.clamp(360.0, 480.0);
          final maxHeight = layout.height * 0.72;
          Get.dialog(
            Dialog(
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: SizedBox(
                width: maxWidth,
                height: maxHeight,
                child: MultiviewRoomSearchPanel(
                  cellIndex: 0,
                  title: i18n('multiview_search_rooms'),
                  embedded: true,
                  onClose: () => Navigator.of(context).pop(),
                  onPicked: (room) {
                    Navigator.of(context).pop();
                    widget.controller.switchRoom(room);
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecordButton() {
    return Obx(() {
      final room = widget.controller.state.value.room.detail;
      return RecordActionButton(
        room: room,
        recorderController: widget.controller.recorderController,
        onOpenRecordCenter: widget.controller.openRecordCenter,
        compactHeader: widget.compactHeader,
      );
    });
  }
}

/// Shows the accumulated watch time badge for a followed room.
///
/// Displayed above [_LiveDurationIndicator] with the same layout, in a gray
/// tone to distinguish from the red live-duration badge. Hidden entirely when
/// the room has no recorded watch time yet (unfollowed rooms never do).
class _WatchTimeIndicator extends StatelessWidget {
  const _WatchTimeIndicator({required this.identityKey});

  final String identityKey;

  @override
  Widget build(BuildContext context) {
    const tick = Duration(seconds: 1);
    final tickStream = Stream<int>.periodic(tick, (count) => count);

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 4),
      child: StreamBuilder<int>(
        stream: tickStream,
        builder: (context, snapshot) {
          final seconds = WatchTimeService.secondsFor(identityKey);
          if (seconds <= 0) return const SizedBox.shrink();
          final gray = Theme.of(context).colorScheme.onSurfaceVariant;
          return Tooltip(
            message: i18n('watch_time_total'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: gray.withValues(alpha: 0.6), shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
                Text(
                  WatchTimeService.formatFull(seconds),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: gray, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Shows a live duration badge that updates every second.
///
/// Displayed only for platforms that expose a live start timestamp
/// (douyin, douyu, huya, bilibili). Other platforms naturally fall through
/// because their [LiveRoom.startTime] stays null.
class _LiveDurationIndicator extends StatelessWidget {
  const _LiveDurationIndicator({required this.startTime});

  /// Unix epoch *seconds* when the current live session started.
  final int startTime;

  @override
  Widget build(BuildContext context) {
    const tick = Duration(seconds: 1);
    final tickStream = Stream<int>.periodic(tick, (_) => DateTime.now().millisecondsSinceEpoch ~/ 1000);

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 4),
      child: StreamBuilder<int>(
        stream: tickStream,
        builder: (context, snapshot) {
          final now = snapshot.hasData ? snapshot.data! : DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final durationSeconds = now - startTime;
          if (durationSeconds < 0) {
            // Clock skew or server-time drift; clamp to zero.
            return const SizedBox.shrink();
          }
          final text = _formatDuration(durationSeconds);
          return Tooltip(
            message: '已播时长',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
                Text(
                  text,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: Colors.redAccent, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Formats a duration in seconds as HH:MM:SS.
  static String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    return '$mm:$ss';
  }
}
