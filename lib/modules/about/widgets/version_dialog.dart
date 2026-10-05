import 'package:pure_live/common/index.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:markdown_widget/config/configs.dart';
import 'package:markdown_widget/widget/markdown_block.dart';

double _clamp(double value, {double min = 0, required double max}) {
  return value < min ? min : (value > max ? max : value);
}

class NoNewVersionDialog extends StatelessWidget {
  const NoNewVersionDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final windowSize = MediaQuery.of(context).size;
    return AlertDialog(
      title: Text(i18n("check_update")),
      content: Text(i18n("no_new_version_info")),
      constraints: BoxConstraints(maxWidth: _clamp(windowSize.width * 0.5, max: 560)),
      actions: <Widget>[
        TextButton(
          child: Text(i18n("confirm")),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ],
    );
  }
}

class NewVersionDialog extends StatelessWidget {
  const NewVersionDialog({super.key, this.onOpenProject, this.onUpdate});

  final VoidCallback? onOpenProject;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final config = Get.isDarkMode ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
    final windowSize = MediaQuery.of(context).size;
    return AlertDialog(
      key: const ValueKey('new-version-dialog'),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: BoxConstraints(
        maxWidth: _clamp(windowSize.width * 0.72, max: 1600),
        maxHeight: _clamp(windowSize.height * 0.72, max: 900),
      ),
      title: Text(i18n("check_update")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            key: const ValueKey('new-version-open-project'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () {
              Navigator.pop(context);
              final callback = onOpenProject;
              if (callback != null) {
                callback();
              } else {
                launchUrl(Uri.parse(VersionUtil.projectUrl), mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(i18n('open_source_free'), style: AppTextStyles.t15),
          ),
          MarkdownBlock(data: VersionUtil.latestUpdateLog, config: config),
          const SizedBox(height: 10),
        ],
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actions: <Widget>[
        Row(
          children: [
            const _AutoCheckUpdateModeMenu(key: ValueKey('new-version-auto-check-menu')),
            const Spacer(),
            TextButton(
              key: const ValueKey('new-version-cancel'),
              onPressed: () => Navigator.pop(context),
              child: Text(i18n("cancel")),
            ),
            FilledButton(
              key: const ValueKey('new-version-update'),
              onPressed: () {
                Navigator.pop(context);
                final callback = onUpdate;
                if (callback != null) {
                  callback();
                } else {
                  Get.toNamed(RoutePath.kVersionPage);
                }
              },
              child: Text(i18n("update")),
            ),
          ],
        ),
      ],
    );
  }
}

/// 更新弹窗左下角的「自动检查更新」三态入口，与设置页共用同一存储项。
class _AutoCheckUpdateModeMenu extends StatelessWidget {
  const _AutoCheckUpdateModeMenu({super.key});

  static const _modeLabels = {
    AutoCheckUpdateMode.off: 'auto_check_update_mode_off',
    AutoCheckUpdateMode.all: 'auto_check_update_mode_all',
    AutoCheckUpdateMode.stableOnly: 'auto_check_update_mode_stable_only',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = theme.hintColor.withValues(alpha: 0.75);
    return Obx(() {
      final mode = SettingsService.to.app.autoCheckUpdateMode;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            i18n('auto_check_update'),
            style: AppTextStyles.t12.copyWith(color: mutedColor, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8), width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: PopupMenuButton<AutoCheckUpdateMode>(
              initialValue: mode,
              tooltip: i18n('enable_auto_check_update'),
              position: PopupMenuPosition.under,
              offset: const Offset(0, 6),
              color: theme.colorScheme.surfaceContainerHigh,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.6),
              ),
              onSelected: SettingsService.to.app.setAutoCheckUpdateMode,
              itemBuilder: (context) => [
                for (final m in AutoCheckUpdateMode.values)
                  PopupMenuItem<AutoCheckUpdateMode>(
                    value: m,
                    height: 38,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: m == mode
                              ? Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary)
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Text(i18n(_modeLabels[m]!), style: AppTextStyles.t13),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                // 注意：PopupMenuButton 自带的 padding 在使用自定义 child 时不生效，
                // 因此胶囊的内边距必须放在这里。
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      i18n(_modeLabels[mode]!),
                      style: AppTextStyles.t12.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more_rounded, size: 16, color: mutedColor),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}
