import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_api_catalog.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_api_preview_page.dart';

/// 某个随机图源分组内的图源列表
///
/// 点击某个图源后，打开预览页获取一张随机图片。
class WallpaperApiGroupPage extends StatelessWidget {
  const WallpaperApiGroupPage({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    WallpaperApiGroup? group;
    for (final WallpaperApiGroup candidate in kWallpaperApiGroups) {
      if (candidate.id == groupId) {
        group = candidate;
        break;
      }
    }
    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('随机图源')),
        body: const Center(child: Text('分组不存在')),
      );
    }
    final WallpaperApiGroup resolved = group;
    return Scaffold(
      appBar: AppBar(
        title: SettingsBreadcrumbBar(
          node: SettingsCrumb(
            labelText: resolved.name,
            routeName: '/settings/wallpaper/api/group',
            pageBuilder: () => this,
            parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperApi],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        physics: const PureLiveScrollPhysics(),
        children: <Widget>[
          context.buildModernCard(<Widget>[
            for (final WallpaperApiSource source in resolved.sources)
              context.buildTile(
                icon: Remix.global_line,
                title: source.name,
                subtitle: source.host,
                trailing: const Icon(Remix.arrow_right_s_line),
                onTap: () => Get.to<void>(() => WallpaperApiPreviewPage(source: source)),
              ),
          ]),
        ],
      ),
    );
  }
}
