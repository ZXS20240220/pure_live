import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';

class SettingsPage extends GetView<SettingsService> {
  const SettingsPage({super.key});

  BuildContext get context => Get.context!;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final scaledActionFontSize = mediaQuery.textScaler.scale(14);
    final useCompactConfigAction = screenWidth < 520 || scaledActionFontSize > 18;
    final configPreviewLabel = i18n('config_preview');
    void openConfigPreview() => SettingsNavigator.open(SettingsCrumbs.configPreview);

    return Scaffold(
      appBar: SettingsBreadcrumbAppBar(
        node: SettingsCrumbs.root,
        scrolledUnderElevation: screenWidth > 640 ? 0 : null,
        actions: [
          if (useCompactConfigAction)
            IconButton(
              key: const ValueKey('settings-config-preview-action'),
              tooltip: configPreviewLabel,
              onPressed: openConfigPreview,
              icon: const Icon(Remix.file_text_line, size: 20),
            )
          else
            TextButton.icon(
              key: const ValueKey('settings-config-preview-action'),
              onPressed: openConfigPreview,
              icon: const Icon(Remix.file_text_line, size: 18),
              label: Text(configPreviewLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        physics: const PureLiveScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          context.buildGroupTitle(i18n("theme_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.palette_line,
              title: i18n("theme_customization"),
              subtitle: i18n("theme_customization_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.theme),
            ),
            context.buildTile(
              icon: Remix.image_line,
              title: '壁纸设置',
              subtitle: '自定义全局壁纸背景（图片/视频）',
              onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaper),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("general_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.settings_4_line,
              title: i18n("general"),
              subtitle: i18n("general_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.general),
            ),
            context.buildTile(
              icon: Remix.menu_line,
              title: i18n("navigation_display_settings"),
              subtitle: i18n("navigation_display_settings_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.navigation),
            ),
            context.buildTile(
              icon: Remix.apps_2_line,
              title: i18n("platform_settings"),
              subtitle: i18n("platform_settings_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.platform),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("refresh_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.refresh_line,
              title: i18n("refresh_settings"),
              subtitle: i18n("refresh_settings_subtitle"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.refresh),
            ),
          ]),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("video_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.film_line,
              title: i18n("video"),
              subtitle: i18n("video_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.video),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("iptv_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.tv_line,
              title: i18n("iptv_settings"),
              subtitle: i18n("manage_iptv_sources"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.iptv),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("player_kernel_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.cpu_line,
              title: i18n("player_kernel"),
              subtitle: i18n("player_kernel_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.kernel),
            ),
          ]),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("network_proxy_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.global_line,
              title: i18n("custom_network_proxy"),
              subtitle: i18n("custom_network_proxy_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.proxy),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n('local_interaction_settings')),
          context.buildModernCard([
            context.buildTile(
              icon: Icons.auto_awesome_rounded,
              title: i18n('local_interaction_title'),
              subtitle: i18n('local_interaction_settings_desc'),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.localInteraction),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("data_manage")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.database_2_line,
              title: i18n("cache_and_data"),
              subtitle: i18n("cache_and_data_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.cache),
            ),
          ]),

          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("backup_manage")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.cloud_line,
              title: i18n("backup_recover"),
              subtitle: i18n("backup_recover_desc"),
              onTap: () => SettingsNavigator.open(SettingsCrumbs.backup),
            ),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
