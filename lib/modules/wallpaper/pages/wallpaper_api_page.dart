import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_api_catalog.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_api_group_page.dart';

/// 随机图源分组列表页
///
/// 显示所有图源分组及其来源数量，点击分组进入该组的图源列表。
class WallpaperApiPage extends StatelessWidget {
  const WallpaperApiPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: SettingsCrumbs.wallpaperApi)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        physics: const PureLiveScrollPhysics(),
        children: <Widget>[
          context.buildModernCard(<Widget>[
            for (final WallpaperApiGroup group in kWallpaperApiGroups)
              context.buildTile(
                icon: Remix.sparkling_2_line,
                title: group.name,
                subtitle: '${group.sources.length} 个来源',
                trailing: const Icon(Remix.arrow_right_s_line),
                onTap: () => SettingsNavigator.open(
                  SettingsCrumb(
                    labelText: group.name,
                    routeName: '/settings/wallpaper/api/group',
                    pageBuilder: () => WallpaperApiGroupPage(groupId: group.id),
                    parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperApi],
                  ),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}
