import 'dart:io';

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:pure_live/common/utils/windows_multi_instance_launcher.dart';

class MenuButton extends StatelessWidget {
  const MenuButton({super.key});

  Future<void> _autoMatchAreaTags(BuildContext context) async {
    final controller = Get.find<FavoriteController>();
    final theme = Theme.of(context);

    await Future.delayed(Duration.zero);

    if (!context.mounted) return;

    final rootContext = Navigator.of(context, rootNavigator: true).context;

    final currentRx = 0.obs;
    final totalRx = 0.obs;

    showDialog(
      context: rootContext,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Obx(
                () => SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(
                    value: totalRx.value > 0 ? currentRx.value / totalRx.value : null,
                    strokeWidth: 3,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(i18n('tag_auto_match_progress'), style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Obx(
                () => Text(
                  totalRx.value > 0 ? '${currentRx.value} / ${totalRx.value}' : '',
                  style: AppTextStyles.t12.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    final result = await controller.autoMatchAreaTags(
      onProgress: (c, t, status) {
        currentRx.value = c;
        totalRx.value = t;
      },
    );

    if (rootContext.mounted) {
      Navigator.of(rootContext).pop();
    }

    if (!rootContext.mounted) return;

    final summary = i18n(
      'tag_auto_match_detail',
      args: {
        'total': result.totalRooms.toString(),
        'success': result.successRooms.toString(),
        'created_tags': result.createdTags.toString(),
        'no_area': result.noAreaRooms.toString(),
        'skipped': result.skippedExistingTag.toString(),
      },
    );

    showDialog(
      context: rootContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(i18n('tag_auto_match_done'), style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w800)),
        content: Text(summary, style: AppTextStyles.t14.copyWith(height: 1.55)),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            ),
            onPressed: () => Navigator.of(rootContext).pop(),
            child: Text(i18n('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showKeyboardShortcuts(BuildContext context) {
    showKeyboardShortcutsDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton(
      tooltip: i18n('menu'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      offset: const Offset(12, 0),
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.menu_rounded),
      onSelected: (int index) async {
        switch (index) {
          case 0:
            Get.toNamed(RoutePath.kSettings);
            break;
          case 1:
            final rootContext = Navigator.of(context, rootNavigator: true).context;
            showDialog(
              context: rootContext,
              builder: (ctx) {
                final theme = Theme.of(ctx);
                return AlertDialog(
                  backgroundColor: theme.colorScheme.surface,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  title: Text(
                    i18n('tag_auto_match_confirm_title'),
                    style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w800),
                  ),
                  content: Text(
                    i18n('tag_auto_match_confirm_content'),
                    style: AppTextStyles.t14.copyWith(height: 1.55),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(i18n('cancel'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _autoMatchAreaTags(rootContext);
                      },
                      child: Text(i18n('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                );
              },
            );
            break;
          case 2:
            Get.toNamed(RoutePath.kAbout);
            break;
          case 3:
            Get.toNamed(RoutePath.kHistory);
            break;
          case 4:
            Get.toNamed(RoutePath.kBackup);
            break;
          case 5:
            try {
              await WindowsMultiInstanceLauncher.launch();
            } catch (_) {
              ToastUtil.show(i18n('open_new_window_failed'));
            }
            break;
          case 6:
            _showKeyboardShortcuts(context);
            break;
          case 7:
            final rootContext = Navigator.of(context, rootNavigator: true).context;
            showDialog(
              context: rootContext,
              builder: (ctx) {
                final theme = Theme.of(ctx);
                return AlertDialog(
                  backgroundColor: theme.colorScheme.surface,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  title: Text(
                    i18n('watch_time_clear_confirm_title'),
                    style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w800),
                  ),
                  content: Text(
                    i18n('watch_time_clear_confirm_content'),
                    style: AppTextStyles.t14.copyWith(height: 1.55),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(i18n('cancel'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        WatchTimeService.clearAllRecords();
                        ToastUtil.show(i18n('watch_time_cleared'));
                      },
                      child: Text(i18n('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                );
              },
            );
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 0,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.settings_5_line), text: i18n('settings_title')),
        ),
        PopupMenuItem(
          value: 1,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.price_tag_3_line), text: i18n('tag_auto_match')),
        ),
        PopupMenuItem(
          value: 2,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.information_line), text: i18n('about')),
        ),
        PopupMenuItem(
          value: 3,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.history_line), text: i18n('history')),
        ),
        PopupMenuItem(
          value: 4,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.cloud_line), text: i18n('backup_recover')),
        ),
        if (Platform.isWindows && SettingsService.to.app.enableNewWindowPlay.v)
          PopupMenuItem(
            value: 5,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: MenuListTile(leading: const Icon(Icons.add_to_photos_outlined), text: i18n('open_new_window')),
          ),
        PopupMenuItem(
          value: 6,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(
            leading: const Icon(Icons.keyboard_arrow_left_rounded, size: 20),
            text: i18n('keyboard_shortcuts'),
          ),
        ),
        PopupMenuItem(
          value: 7,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MenuListTile(leading: const Icon(Remix.delete_bin_line), text: i18n('watch_time_clear_all')),
        ),
      ],
    );
  }
}

class MenuListTile extends StatelessWidget {
  final Widget? leading;
  final String text;
  final Widget? trailing;

  const MenuListTile({super.key, required this.leading, required this.text, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Text(text, style: Theme.of(context).textTheme.labelMedium),
        if (trailing != null) ...[const SizedBox(width: 24), trailing!],
      ],
    );
  }
}

class KeyboardShortcutsDialog extends StatelessWidget {
  const KeyboardShortcutsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currentRoute = Get.currentRoute;

    final favoriteSection = _ShortcutSectionData(
      title: i18n('shortcut_group_favorite'),
      items: [
        _ShortcutItem(keys: const ['1'], desc: i18n('shortcut_prev_platform')),
        _ShortcutItem(keys: const ['2'], desc: i18n('shortcut_next_platform')),
        _ShortcutItem(keys: const ['F5'], desc: i18n('shortcut_refresh_favorites')),
        _ShortcutItem(keys: const ['Ctrl', 'F'], desc: i18n('shortcut_focus_search')),
        _ShortcutItem(keys: const ['←'], desc: i18n('shortcut_prev_page')),
        _ShortcutItem(keys: const ['→'], desc: i18n('shortcut_next_page')),
        _ShortcutItem(keys: const ['↑'], desc: i18n('shortcut_scroll_up_page')),
        _ShortcutItem(keys: const ['↓'], desc: i18n('shortcut_scroll_down_page')),
        _ShortcutItem(keys: const ['Mouse Wheel'], desc: i18n('shortcut_wheel_paging')),
        _ShortcutItem(keys: const ['Ctrl', 'Click'], desc: i18n('shortcut_ctrl_click_float_play')),
      ],
    );

    final playerSection = _ShortcutSectionData(
      title: i18n('shortcut_group_live_play'),
      items: [
        _ShortcutItem(keys: const ['Space'], desc: i18n('shortcut_play_pause')),
        _ShortcutItem(keys: const ['F5'], desc: i18n('shortcut_refresh_stream')),
        _ShortcutItem(keys: const ['Ctrl', 'F'], desc: i18n('shortcut_toggle_fullscreen')),
        _ShortcutItem(keys: const ['Ctrl', 'E'], desc: i18n('shortcut_seek_live_edge')),
        _ShortcutItem(keys: const ['Ctrl', 'S'], desc: i18n('shortcut_take_screenshot')),
        _ShortcutItem(keys: const ['Ctrl', 'D'], desc: i18n('shortcut_toggle_danmaku')),
        _ShortcutItem(keys: const ['Ctrl', 'W'], desc: i18n('shortcut_toggle_global_mute')),
        _ShortcutItem(keys: const ['1'], desc: i18n('shortcut_prev_tab')),
        _ShortcutItem(keys: const ['2'], desc: i18n('shortcut_next_tab')),
        _ShortcutItem(keys: const ['↑'], desc: i18n('shortcut_volume_up')),
        _ShortcutItem(keys: const ['↓'], desc: i18n('shortcut_volume_down')),
        _ShortcutItem(keys: const ['←'], desc: i18n('shortcut_back_5s')),
        _ShortcutItem(keys: const ['→'], desc: i18n('shortcut_forward_5s')),
        _ShortcutItem(keys: const ['shift', '←'], desc: i18n('shortcut_back_30s')),
        _ShortcutItem(keys: const ['shift', '→'], desc: i18n('shortcut_forward_30s')),
        _ShortcutItem(keys: const ['`'], desc: i18n('shortcut_toggle_immersive_panel')),
        _ShortcutItem(keys: const ['Mouse Wheel'], desc: i18n('shortcut_adjust_volume')),
        _ShortcutItem(keys: const ['Ctrl', 'Mouse Wheel'], desc: i18n('shortcut_zoom_at_cursor')),
        _ShortcutItem(keys: const ['Ctrl', 'Drag'], desc: i18n('shortcut_pan_zoomed_video')),
        _ShortcutItem(keys: const ['Ctrl', 'Click'], desc: i18n('shortcut_open_mini_window')),
        _ShortcutItem(keys: const ['Ctrl', 'Mouse Wheel'], desc: i18n('shortcut_resize_mini_window')),
        _ShortcutItem(keys: const ['Double Click'], desc: i18n('shortcut_mini_window_to_main')),
        _ShortcutItem(keys: const ['Esc'], desc: i18n('shortcut_exit_fullscreen_or_close')),
      ],
    );

    final localPlayerSection = _ShortcutSectionData(
      title: i18n('shortcut_group_local_play'),
      items: [
        _ShortcutItem(keys: const ['Space'], desc: i18n('shortcut_play_pause')),
        _ShortcutItem(keys: const ['Ctrl', 'F'], desc: i18n('shortcut_toggle_fullscreen')),
        _ShortcutItem(keys: const ['Ctrl', 'S'], desc: i18n('shortcut_take_screenshot')),
        _ShortcutItem(keys: const ['Ctrl', 'D'], desc: i18n('shortcut_toggle_danmaku')),
        _ShortcutItem(keys: const ['Ctrl', 'W'], desc: i18n('shortcut_toggle_mute')),
        _ShortcutItem(keys: const ['Ctrl', 'B'], desc: i18n('shortcut_toggle_pip')),
        _ShortcutItem(keys: const ['↑'], desc: i18n('shortcut_volume_up')),
        _ShortcutItem(keys: const ['↓'], desc: i18n('shortcut_volume_down')),
        _ShortcutItem(keys: const ['←'], desc: i18n('shortcut_back_5s')),
        _ShortcutItem(keys: const ['→'], desc: i18n('shortcut_forward_5s')),
        _ShortcutItem(keys: const ['shift', '←'], desc: i18n('shortcut_back_30s')),
        _ShortcutItem(keys: const ['shift', '→'], desc: i18n('shortcut_forward_30s')),
        _ShortcutItem(keys: const ['Mouse Wheel'], desc: i18n('shortcut_adjust_volume')),
        _ShortcutItem(keys: const ['Ctrl', 'Mouse Wheel'], desc: i18n('shortcut_adjust_playback_speed')),
        _ShortcutItem(keys: const ['Double Click'], desc: i18n('shortcut_double_click_fullscreen')),
        _ShortcutItem(keys: const ['Esc'], desc: i18n('shortcut_exit_pip_fullscreen_or_close')),
      ],
    );

    final sections = <_ShortcutSectionData>[];
    if (currentRoute == RoutePath.kLocalPlayback) {
      sections.add(localPlayerSection);
    } else if (currentRoute == RoutePath.kLivePlay || currentRoute == RoutePath.kMultiview) {
      sections.add(playerSection);
    } else {
      sections.addAll([favoriteSection, playerSection]);
    }

    return Dialog(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.keyboard, color: colorScheme.primary, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    i18n('keyboard_shortcuts_title'),
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ScrollConfiguration(
                behavior: const MouseDraggableScrollBehavior(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  children: [
                    for (int i = 0; i < sections.length; i++) ...[
                      _ShortcutSection(section: sections[i]),
                      if (i != sections.length - 1) const SizedBox(height: 20),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(i18n('shortcut_got_it'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutItem {
  final List<String> keys;
  final String desc;
  const _ShortcutItem({required this.keys, required this.desc});
}

class _ShortcutSectionData {
  final String title;
  final List<_ShortcutItem> items;
  const _ShortcutSectionData({required this.title, required this.items});
}

class _ShortcutSection extends StatelessWidget {
  final _ShortcutSectionData section;
  const _ShortcutSection({required this.section});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            section.title,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: colorScheme.primary),
          ),
        ),
        ...section.items.map(
          (item) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                _KeyCombo(keys: item.keys),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.desc,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _KeyCombo extends StatelessWidget {
  final List<String> keys;
  const _KeyCombo({required this.keys});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                '+',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 2, offset: const Offset(0, 1)),
              ],
            ),
            child: Text(
              keys[i],
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

void showKeyboardShortcutsDialog(BuildContext context) {
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  showDialog(context: rootContext, builder: (ctx) => const KeyboardShortcutsDialog());
}
