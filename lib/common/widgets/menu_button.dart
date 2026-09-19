import 'dart:io';

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:pure_live/common/utils/windows_multi_instance_launcher.dart';

class MenuButton extends StatelessWidget {
  const MenuButton({super.key});

  /// 5.6 一键匹配分类标签：进度弹窗 → 执行匹配 → 结果摘要弹窗。
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
            // 5.6 一键匹配分类标签：主菜单入口 → 确认弹窗。
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
            // 7.1 观看时长：清空所有累计观看时长记录。
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
