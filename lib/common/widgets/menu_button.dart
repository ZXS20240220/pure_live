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
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    showDialog(context: rootContext, builder: (ctx) => const _KeyboardShortcutsDialog());
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

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';

    final favoriteSection = isZh
        ? _ShortcutSectionData(
            title: '关注页',
            items: [
              _ShortcutItem(keys: const ['1'], desc: '切换到上一个直播平台'),
              _ShortcutItem(keys: const ['2'], desc: '切换到下一个直播平台'),
              _ShortcutItem(keys: const ['F5'], desc: '刷新关注直播间'),
              _ShortcutItem(keys: const ['Ctrl', 'F'], desc: '聚焦搜索框'),
              _ShortcutItem(keys: const ['←'], desc: '上一页'),
              _ShortcutItem(keys: const ['→'], desc: '下一页'),
              _ShortcutItem(keys: const ['↑'], desc: '向上滚一屏'),
              _ShortcutItem(keys: const ['↓'], desc: '向下滚一屏'),
            ],
          )
        : _ShortcutSectionData(
            title: 'Favorite Page',
            items: [
              _ShortcutItem(keys: const ['1'], desc: 'Previous platform'),
              _ShortcutItem(keys: const ['2'], desc: 'Next platform'),
              _ShortcutItem(keys: const ['F5'], desc: 'Refresh all favorite rooms'),
              _ShortcutItem(keys: const ['Ctrl', 'F'], desc: 'Focus search box'),
              _ShortcutItem(keys: const ['←'], desc: 'Previous page'),
              _ShortcutItem(keys: const ['→'], desc: 'Next page'),
              _ShortcutItem(keys: const ['↑'], desc: 'Scroll up one page'),
              _ShortcutItem(keys: const ['↓'], desc: 'Scroll down one page'),
            ],
          );

    final playerSection = isZh
        ? _ShortcutSectionData(
            title: '播放页',
            items: [
              _ShortcutItem(keys: const ['Space'], desc: '播放 / 暂停'),
              _ShortcutItem(keys: const ['F5'], desc: '刷新当前直播'),
              _ShortcutItem(keys: const ['Ctrl', 'F'], desc: '窗口全屏切换'),
              _ShortcutItem(keys: const ['Ctrl', 'E'], desc: '跳到当前直播进度'),
              _ShortcutItem(keys: const ['Ctrl', 'S'], desc: '截取当前画面并保存'),
              _ShortcutItem(keys: const ['Ctrl', 'W'], desc: '全局静音开关'),
              _ShortcutItem(keys: const ['1'], desc: '切换到上一个直播间'),
              _ShortcutItem(keys: const ['2'], desc: '切换到下一个直播间'),
              _ShortcutItem(keys: const ['↑'], desc: '音量 +5%'),
              _ShortcutItem(keys: const ['↓'], desc: '音量 -5%'),
              _ShortcutItem(keys: const ['←'], desc: '后退 5 秒'),
              _ShortcutItem(keys: const ['→'], desc: '前进 5 秒'),
              _ShortcutItem(keys: const ['shift', '←'], desc: '后退 30 秒'),
              _ShortcutItem(keys: const ['shift', '→'], desc: '前进 30 秒'),
              _ShortcutItem(keys: const ['`'], desc: '沉浸模式侧栏开关'),
              _ShortcutItem(keys: const ['Esc'], desc: '退出全屏 / 关闭页面'),
            ],
          )
        : _ShortcutSectionData(
            title: 'Player Page',
            items: [
              _ShortcutItem(keys: const ['Space'], desc: 'Play / Pause'),
              _ShortcutItem(keys: const ['F5'], desc: 'Refresh current stream'),
              _ShortcutItem(keys: const ['Ctrl', 'F'], desc: 'Toggle fullscreen'),
              _ShortcutItem(keys: const ['Ctrl', 'E'], desc: 'Seek to live edge'),
              _ShortcutItem(keys: const ['Ctrl', 'S'], desc: 'Take screenshot'),
              _ShortcutItem(keys: const ['1'], desc: 'Previous room'),
              _ShortcutItem(keys: const ['2'], desc: 'Next room'),
              _ShortcutItem(keys: const ['↑'], desc: 'Volume +5%'),
              _ShortcutItem(keys: const ['↓'], desc: 'Volume -5%'),
              _ShortcutItem(keys: const ['←'], desc: 'Back 5s (Shift 30s)'),
              _ShortcutItem(keys: const ['→'], desc: 'Forward 5s (Shift 30s)'),
              _ShortcutItem(keys: const ['`'], desc: 'Toggle immersive panel'),
              _ShortcutItem(keys: const ['Esc'], desc: 'Exit fullscreen / Close page'),
            ],
          );

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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                children: [
                  _ShortcutSection(section: favoriteSection),
                  const SizedBox(height: 20),
                  _ShortcutSection(section: playerSection),
                ],
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
                  child: Text(isZh ? '知道了' : 'Got it', style: const TextStyle(fontWeight: FontWeight.w700)),
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
