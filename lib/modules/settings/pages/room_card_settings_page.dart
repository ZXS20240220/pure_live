import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/room_card_settings_controller.dart';
import 'package:pure_live/common/widgets/room_card_compact.dart';

class RoomCardSettingsPage extends StatefulWidget {
  const RoomCardSettingsPage({super.key});

  @override
  State<RoomCardSettingsPage> createState() => _RoomCardSettingsPageState();
}

class _RoomCardSettingsPageState extends State<RoomCardSettingsPage> {
  LiveRoom get _previewRoom => LiveRoom(
    roomId: 'room-card-preview',
    platform: 'bilibili',
    title: 'Pure Live · ${i18n('room_card_preview_title')}',
    nick: i18n('room_card_preview_anchor'),
    cover: '',
    avatar: '',
    popularity: '12800',
    liveStatus: LiveStatus.live,
  );

  LiveRoom get _previewOfflineRoom => LiveRoom(
    roomId: 'room-card-preview-offline',
    platform: 'bilibili',
    title: 'Pure Live · 未直播房间预览',
    nick: i18n('room_card_preview_anchor'),
    cover: '',
    avatar: '',
    popularity: '0',
    liveStatus: LiveStatus.offline,
    startTime: (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 3600 * 5,
  );

  @override
  Widget build(BuildContext context) {
    final controller = SettingsService.to.roomCard;
    return Scaffold(
      appBar: AppBar(
        title: Text(i18n('room_card_settings')),
        actions: [
          IconButton(
            key: const ValueKey('room-card-reset'),
            tooltip: i18n('room_card_reset_current'),
            onPressed: controller.reset,
            icon: const Icon(Remix.restart_line),
          ),
        ],
      ),
      body: Obx(() {
        final config = controller.current;
        return ListView(
          key: const ValueKey('room-card-settings-scroll'),
          physics: const PureLiveScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // 实时预览：标准卡片 + 紧凑列表卡片（带 pin + offline 两版）
            context.buildGroupTitle(i18n('room_card_preview')),
            Center(
              child: Column(
                key: const ValueKey('room-card-preview-column'),
                children: [
                  // 标准卡片预览（关注页 / 切换页封面布局）
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: RoomCard(
                      key: const ValueKey('room-card-preview-standard'),
                      room: _previewRoom,
                      isPinned: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 紧凑列表卡片预览（关注页列表布局 / 切换页列表布局）
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      children: [
                        RoomCardCompact(
                          key: const ValueKey('room-card-preview-compact-live'),
                          room: _previewRoom,
                          isPinned: true,
                        ),
                        const SizedBox(height: 8),
                        RoomCardCompact(
                          key: const ValueKey('room-card-preview-compact-offline'),
                          room: _previewOfflineRoom,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            context.buildGroupTitle(i18n('room_card_visible_content')),
            context.buildModernCard([
              _toggle(
                icon: Remix.user_3_line,
                title: i18n('room_card_show_avatar'),
                subtitle: i18n('room_card_show_avatar_subtitle'),
                value: config.showAvatar,
                onChanged: (v) => controller.updateConfig(config.copyWith(showAvatar: v)),
              ),
              _toggle(
                icon: Remix.account_circle_line,
                title: i18n('room_card_show_anchor'),
                subtitle: i18n('room_card_show_anchor_subtitle'),
                value: config.showAnchorName,
                onChanged: (v) => controller.updateConfig(config.copyWith(showAnchorName: v)),
              ),
              _toggle(
                icon: Remix.layout_grid_line,
                title: i18n('room_card_show_platform'),
                // 旧 subtitle 描述"自动"模式，现在只有简单开关，更新提示
                subtitle: '在卡片上始终显示直播平台徽章',
                value: config.showPlatformBadge,
                onChanged: (v) => controller.updateConfig(config.copyWith(showPlatformBadge: v)),
              ),
              _toggle(
                icon: Remix.group_line,
                title: i18n('room_card_show_audience'),
                subtitle: i18n('room_card_show_audience_subtitle'),
                value: config.showAudience,
                onChanged: (v) => controller.updateConfig(config.copyWith(showAudience: v)),
              ),
              _toggle(
                icon: Remix.video_line,
                title: i18n('room_card_show_replay'),
                subtitle: i18n('room_card_show_replay_subtitle'),
                value: config.showReplayBadge,
                onChanged: (v) => controller.updateConfig(config.copyWith(showReplayBadge: v)),
              ),
              _toggle(
                icon: Remix.pushpin_line,
                title: i18n('room_card_show_pin_badge'),
                subtitle: i18n('room_card_show_pin_badge_subtitle'),
                value: config.showPinBadge,
                onChanged: (v) => controller.updateConfig(config.copyWith(showPinBadge: v)),
              ),
              _toggle(
                icon: Remix.time_line,
                title: i18n('room_card_show_watch_time'),
                subtitle: i18n('room_card_show_watch_time_subtitle'),
                value: config.showWatchTimeBadge,
                onChanged: (v) => controller.updateConfig(config.copyWith(showWatchTimeBadge: v)),
              ),
              _toggle(
                icon: Remix.history_line,
                title: i18n('room_card_show_last_live'),
                subtitle: i18n('room_card_show_last_live_subtitle'),
                value: config.showLastLiveTime,
                onChanged: (v) => controller.updateConfig(config.copyWith(showLastLiveTime: v)),
              ),
            ]),
            const SizedBox(height: 20),
            context.buildGroupTitle(i18n('room_card_appearance')),
            context.buildModernCard([
              context.buildSliderTile(
                context,
                icon: Remix.rounded_corner,
                title: i18n('room_card_corner_radius'),
                subtitle: i18n('room_card_corner_radius_subtitle'),
                value: config.cornerRadius,
                min: RoomCardAppearance.minCornerRadius,
                max: RoomCardAppearance.maxCornerRadius,
                displayValue: config.cornerRadius.toStringAsFixed(0),
                onChanged: (v) => controller.updateConfig(config.copyWith(cornerRadius: v)),
              ),
            ]),
            const SizedBox(height: 16),
            Text(
              i18n('room_card_settings_scope_hint'),
              key: const ValueKey('room-card-settings-scope-hint'),
              style: AppTextStyles.t12.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        );
      }),
    );
  }

  Widget _toggle({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title, style: AppTextStyles.t15.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: AppTextStyles.t12),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.only(left: 16, top: 2, bottom: 2, right: 8),
    );
  }
}
