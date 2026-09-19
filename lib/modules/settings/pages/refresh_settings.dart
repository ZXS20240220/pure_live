import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';

class RefreshSettingsPage extends GetView<RefreshConfigController> {
  const RefreshSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(i18n("refresh_settings"))),
      body: ListView(
        physics: const PureLiveScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          context.buildGroupTitle(i18n("auto_refresh_settings")),
          context.buildModernCard([
            context.buildSwitchTile(
              icon: Remix.refresh_line,
              title: i18n("auto_refresh_follow"),
              subtitle: i18n("auto_refresh_follow_subtitle"),
              value: controller.autoRefreshFavorite,
            ),
            context.buildSwitchTile(
              icon: Remix.refresh_line,
              title: i18n("refresh_follow_on_resume"),
              subtitle: i18n("refresh_follow_on_resume_subtitle"),
              value: controller.refreshFavoriteOnResume,
            ),
            Obx(() {
              if (!controller.autoRefreshFavorite.value) {
                return const SizedBox.shrink();
              }
              return context.buildTile(
                icon: Remix.time_line,
                title: i18n("auto_refresh_interval"),
                subtitle: _getIntervalText(controller.autoRefreshInterval.value),
                onTap: () => showRefreshIntervalDialog(context),
              );
            }),
            Obx(
              () => context.buildTile(
                icon: Remix.shield_check_line,
                title: i18n("refresh_success_cooldown"),
                subtitle:
                    '${controller.successCooldownSeconds.value <= 0 ? i18n("cooldown_disabled") : "${controller.successCooldownSeconds.value} ${i18n("second")}"} · ${i18n("refresh_success_cooldown_subtitle")}',
                isLong: true,
                onTap: () => showSuccessCooldownDialog(context),
              ),
            ),
            Obx(
              () => context.buildTile(
                icon: Remix.error_warning_line,
                title: i18n("refresh_failure_cooldown"),
                subtitle:
                    '${controller.failureRetryMinutes.value <= 0 ? i18n("cooldown_disabled") : "${controller.failureRetryMinutes.value} ${i18n("minute")}"} · ${i18n("refresh_failure_cooldown_subtitle")}',
                isLong: true,
                onTap: () => showFailureCooldownDialog(context),
              ),
            ),
            Obx(
              () => context.buildTile(
                icon: Remix.server_line,
                title: i18n("max_concurrent_refresh"),
                subtitle:
                    '${controller.maxConcurrentRefresh.value} ${i18n('concurrent_tasks')} · ${i18n('max_concurrent_refresh_subtitle')}',
                isLong: true,
                onTap: () => showMaxConcurrentDialog(context),
              ),
            ),
            Obx(() {
              final sites = Sites().availableSites();
              if (sites.isEmpty) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final site in sites)
                    context.buildTile(
                      icon: Remix.server_line,
                      title: site.name,
                      subtitle:
                          '${controller.platformConcurrencyOf(site.id)} ${i18n('concurrent_tasks')} · ${controller.hasPlatformConcurrencyOverride(site.id) ? i18n('platform_concurrency_custom') : i18n('platform_concurrency_follow_default')}',
                      onTap: () => showPlatformMaxConcurrentDialog(context, site),
                    ),
                ],
              );
            }),
            context.buildSwitchTile(
              icon: Remix.image_2_line,
              title: i18n('auto_refresh_thumbnails'),
              subtitle: i18n('auto_refresh_thumbnails_subtitle'),
              value: controller.autoRefreshThumbnails,
            ),
            Obx(() {
              if (!controller.autoRefreshThumbnails.value) {
                return const SizedBox.shrink();
              }
              return context.buildTile(
                icon: Remix.time_line,
                title: i18n('thumbnail_refresh_interval'),
                subtitle: _getIntervalText(controller.thumbnailRefreshInterval.value),
                onTap: () => showThumbnailRefreshIntervalDialog(context),
              );
            }),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _getIntervalText(int minute) {
    if (minute < 60) {
      return "$minute ${i18n("minute")}";
    }
    if (minute == 60) {
      return "1 ${i18n("hour")}";
    }
    if (minute == 90) {
      return "1.5 ${i18n("hour")}";
    }
    return "${minute ~/ 60} ${i18n("hour")}";
  }

  Future<void> showRefreshIntervalDialog(BuildContext context) async {
    final Map<int, String> intervals = {
      5: "5 ${i18n("minute")}",
      10: "10 ${i18n("minute")}",
      15: "15 ${i18n("minute")}",
      20: "20 ${i18n("minute")}",
      30: "30 ${i18n("minute")}",
      45: "45 ${i18n("minute")}",
      60: "1 ${i18n("hour")}",
      90: "1.5 ${i18n("hour")}",
      120: "2 ${i18n("hour")}",
      180: "3 ${i18n("hour")}",
      240: "4 ${i18n("hour")}",
      360: "6 ${i18n("hour")}",
    };

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: i18n("auto_refresh_interval"),
          value: controller.autoRefreshInterval.value,
          items: intervals,
        );
      },
    );

    if (value != null && value != controller.autoRefreshInterval.value) {
      controller.autoRefreshInterval.value = value;
    }
  }

  /// 刷新成功保护（秒）：0~60，0 = 关闭。默认 15 秒（推荐）。
  Future<void> showSuccessCooldownDialog(BuildContext context) async {
    final Map<int, String> values = {
      0: i18n("cooldown_disabled"),
      for (final i in const [5, 10, 15, 20, 30, 45, 60]) i: "$i ${i18n("second")}",
    };
    values[15] = "15 ${i18n("second")} · ${i18n('recommended')}";

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: i18n("refresh_success_cooldown"),
          hint: i18n("refresh_success_cooldown_hint"),
          value: controller.successCooldownSeconds.value,
          items: values,
        );
      },
    );

    if (value != null && value != controller.successCooldownSeconds.value) {
      controller.successCooldownSeconds.value = value;
    }
  }

  /// 刷新失败保护（分钟）：0~60，0 = 关闭。默认 5 分钟（推荐）。
  Future<void> showFailureCooldownDialog(BuildContext context) async {
    final Map<int, String> values = {
      0: i18n("cooldown_disabled"),
      for (final i in const [1, 2, 3, 5, 10, 15, 30, 60]) i: "$i ${i18n("minute")}",
    };
    values[5] = "5 ${i18n("minute")} · ${i18n('recommended')}";

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: i18n("refresh_failure_cooldown"),
          hint: i18n("refresh_failure_cooldown_hint"),
          value: controller.failureRetryMinutes.value,
          items: values,
        );
      },
    );

    if (value != null && value != controller.failureRetryMinutes.value) {
      controller.failureRetryMinutes.value = value;
    }
  }

  Future<void> showMaxConcurrentDialog(BuildContext context) async {
    final Map<int, String> values = {
      for (int i = 1; i <= 20; i++)
        i: i == RefreshConfigController.defaultMaxConcurrentRefresh ? '$i · ${i18n('recommended')}' : i.toString(),
    };

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: i18n("max_concurrent_refresh"),
          hint: i18n('max_concurrent_refresh_hint'),
          value: controller.maxConcurrentRefresh.value,
          items: values,
        );
      },
    );

    if (value != null && value != controller.maxConcurrentRefresh.value) {
      controller.maxConcurrentRefresh.value = value;
    }
  }

  Future<void> showPlatformMaxConcurrentDialog(BuildContext context, Site site) async {
    final Map<int, String> values = {
      for (int i = 1; i <= RefreshConfigController.maxAllowedConcurrentRefresh; i++)
        i: i == RefreshConfigController.recommendedPlatformMaxConcurrentRefresh
            ? '$i · ${i18n('recommended')}'
            : i.toString(),
    };

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: '${site.name} · ${i18n('max_concurrent_refresh')}',
          hint: i18n('platform_max_concurrent_hint'),
          value: controller.platformConcurrencyOf(site.id),
          items: values,
        );
      },
    );

    if (value != null && value != controller.platformConcurrencyOf(site.id)) {
      controller.setPlatformConcurrency(site.id, value);
    }
  }

  Future<void> showThumbnailRefreshIntervalDialog(BuildContext context) async {
    final Map<int, String> intervals = {
      5: "5 ${i18n("minute")}",
      10: "10 ${i18n("minute")}",
      15: "15 ${i18n("minute")}",
      30: "30 ${i18n("minute")}",
      60: "1 ${i18n("hour")}",
      120: "2 ${i18n("hour")}",
      240: "4 ${i18n("hour")}",
      360: "6 ${i18n("hour")}",
    };

    final int? value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return _RefreshRadioDialog(
          title: i18n('thumbnail_refresh_interval'),
          value: controller.thumbnailRefreshInterval.value,
          items: intervals,
        );
      },
    );

    if (value != null && value != controller.thumbnailRefreshInterval.value) {
      controller.thumbnailRefreshInterval.value = value;
    }
  }
}

class _RefreshRadioDialog extends StatelessWidget {
  final String title;
  final String? hint;
  final int value;
  final Map<int, String> items;

  const _RefreshRadioDialog({required this.title, required this.value, required this.items, this.hint});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(title),
      contentPadding: const EdgeInsets.only(top: 8, bottom: 8),
      content: RadioGroup<int>(
        groupValue: value,
        onChanged: (selectedValue) {
          if (selectedValue == null) {
            return;
          }
          Navigator.of(context).pop(selectedValue);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hint != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(hint!, style: Theme.of(context).textTheme.bodySmall),
              ),
            ...items.entries.map(
              (entry) => RadioListTile<int>(
                title: Text(entry.value),
                value: entry.key,
                activeColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
