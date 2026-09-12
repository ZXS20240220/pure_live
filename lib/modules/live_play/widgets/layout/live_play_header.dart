import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/utils/live_url_tool.dart';
import 'package:pure_live/common/utils/windows_multi_instance_launcher.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/dialogs/play_other.dart';
import 'package:pure_live/modules/live_play/widgets/button/record_action_button.dart';
import 'package:pure_live/modules/live_play/widgets/button/live_play_menu_button.dart';
import 'package:pure_live/modules/live_play/widgets/button/favorite_floating_button.dart';
import 'package:pure_live/modules/settings/pages/room_card_settings/room_card_controller.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

class LivePlayHeader extends StatelessWidget implements PreferredSizeWidget {
  const LivePlayHeader({super.key, required this.controller, this.compactHeader = false});
  final LivePlayController controller;
  final bool compactHeader;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 0,
      title: _buildTitle(context),
      actions: [
        _buildFavoriteButton(),
        _buildRecordButton(),
        _buildQuickActions(context),
        LivePlayMenuButton(controller: controller),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildTitle(BuildContext context) {
    return Row(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Obx(() {
              final avatar = controller.state.value.room.detail?.avatar;
              return CircleAvatar(
                radius: 16,
                foregroundImage: avatar != null && avatar.isNotEmpty
                    ? CachedNetworkImageProvider(avatar)
                    : null,
                backgroundColor: Theme.of(context).disabledColor,
              );
            }),
            const SizedBox(width: 8),
            Flexible(
              child: Obx(() {
                final detail = controller.state.value.room.detail;
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

                final textColumn = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      detail.nick ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      area == null || area.isEmpty
                          ? i18n('site_$platform')
                          : '${i18n("site_$platform")} / $area',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                );

                final infoColumn = Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (hasLevel || hasUnion)
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
                    if (hasLevel || hasUnion) const SizedBox(width: 4),
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
              final detail = controller.state.value.room.detail;
              if (detail == null) return const SizedBox.shrink();
              if (!detail.isLiveNow) return const SizedBox.shrink();
              final startTime = detail.startTime;
              if (startTime == null || startTime <= 0) return const SizedBox.shrink();
              return _LiveDurationIndicator(startTime: startTime);
            }),
          ],
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildFavoriteButton() {
    return Obx(() {
      final roomState = controller.state.value.room;
      final detail = roomState.detail;
      if (detail == null) {
        return const SizedBox.shrink();
      }
      final awaitingCanonicalIdentity =
          roomState.isLoading &&
          (detail.nick?.trim().isEmpty ?? true) &&
          (detail.title?.trim().isEmpty ?? true);
      if (awaitingCanonicalIdentity) {
        return const SizedBox(
          width: 47,
          child: Center(
            child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(left: 2, right: 5),
        child: FavoriteFloatingButton(
          key: ValueKey('${detail.platform}:${detail.roomId}'),
          room: detail,
          compact: compactHeader,
        ),
      );
    });
  }

  Widget _buildQuickActions(BuildContext context) {
    return Obx(() {
      final detail = controller.state.value.room.detail;
      if (detail == null) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: i18n('set_room_tags'),
            child: IconButton(
              icon: const Icon(Remix.price_tag_3_line),
              onPressed: () {
                final favoriteController = Get.isRegistered<FavoriteController>()
                    ? Get.find<FavoriteController>()
                    : Get.put(FavoriteController());
                final tagController = Get.find<TagManagementController>();
                RoomCardController(room: detail).showTagSelectionDialog(
                  context,
                  Theme.of(context),
                  favoriteController,
                  tagController,
                );
              },
            ),
          ),
          Tooltip(
            message: i18n('open_live_room'),
            child: IconButton(
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => controller.openNaviteAPP(),
            ),
          ),
          Tooltip(
            message: i18n('switch_live_room'),
            child: IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              onPressed: () => Get.dialog(PlayOther(controller: controller)),
            ),
          ),
          Tooltip(
            message: i18n('toolbox_get_direct_link'),
            child: IconButton(
              icon: const Icon(Remix.link_m),
              onPressed: () => LiveUrlTool.getPlayUrlByRoomId(
                roomId: detail.roomId ?? '',
                platform: detail.platform ?? '',
              ),
            ),
          ),
          if (Platform.isWindows)
            Tooltip(
              message: i18n('open_room_in_new_window'),
              child: IconButton(
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: () => WindowsMultiInstanceLauncher.launch(room: detail),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildRecordButton() {
    return Obx(() {
      final room = controller.state.value.room.detail;
      return RecordActionButton(
        room: room,
        recorderController: controller.recorderController,
        onOpenRecordCenter: controller.openRecordCenter,
        compactHeader: compactHeader,
      );
    });
  }
}

/// Shows a live duration badge that updates every second.
///
/// Displayed only for platforms that expose a live start timestamp
/// (douyu, huya, bilibili). Other platforms naturally fall through
/// because their [LiveRoom.startTime] stays null.
class _LiveDurationIndicator extends StatelessWidget {
  const _LiveDurationIndicator({required this.startTime});

  /// Unix epoch *seconds* when the current live session started.
  final int startTime;

  @override
  Widget build(BuildContext context) {
    const tick = Duration(seconds: 1);
    final tickStream = Stream<int>.periodic(
      tick,
      (_) => DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 4),
      child: StreamBuilder<int>(
        stream: tickStream,
        builder: (context, snapshot) {
          final now = snapshot.hasData
              ? snapshot.data!
              : DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final durationSeconds = now - startTime;
          if (durationSeconds < 0) {
            // Clock skew or server-time drift; clamp to zero.
            return const SizedBox.shrink();
          }
          final text = _formatDuration(durationSeconds);
          return Tooltip(
            message: '已播时间',
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
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.redAccent,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
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
