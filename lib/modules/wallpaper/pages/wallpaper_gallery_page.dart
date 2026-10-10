import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_items_page.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_repository.dart';

/// 图源分组页
///
/// 展示某个图源下的所有分组，点击进入对应分组的壁纸网格。
class WallpaperGalleryPage extends StatelessWidget {
  const WallpaperGalleryPage({super.key, required this.sourceId});

  final String sourceId;

  SettingsCrumb get _crumb {
    final source = WallpaperRepository.instance.loadCatalog().sourceById(sourceId);
    return SettingsCrumb(
      labelText: source == null ? '壁纸库' : wallpaperSourceName(source.id),
      routeName: '/settings/wallpaper/library/gallery',
      pageBuilder: () => this,
      parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperLibrary],
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = WallpaperRepository.instance.loadCatalog().sourceById(sourceId);
    if (source == null) {
      return Scaffold(
        appBar: AppBar(title: SettingsBreadcrumbBar(node: _crumb)),
        body: const Center(child: Text('未找到该图源')),
      );
    }

    final groups = source.visibleGroups;
    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: _crumb)),
      body: groups.isEmpty
          ? const Center(child: Text('暂无分组'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                context.buildModernCard([
                  for (final group in groups)
                    context.buildTile(
                      icon: Remix.image_2_line,
                      title: wallpaperGroupName(source.id, group.id),
                      trailing: const Icon(Remix.arrow_right_s_line),
                      onTap: () => SettingsNavigator.open(
                        SettingsCrumb(
                          labelText: wallpaperGroupName(source.id, group.id),
                          routeName: '/settings/wallpaper/library/items',
                          pageBuilder: () => WallpaperItemsPage(sourceId: source.id, groupId: group.id),
                          parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperLibrary],
                        ),
                      ),
                    ),
                ]),
              ],
            ),
    );
  }
}
