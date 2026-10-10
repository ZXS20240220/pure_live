import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_gallery_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_items_page.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_repository.dart';

/// 壁纸库首页：列出图片类图源
///
/// 动态壁纸与纯色渐变在壁纸设置首页已有专门入口，此处不再重复。
/// 图源树是编译时常量，页面立即可绘制，无需加载状态。
/// 点击图源：多分组图源进入分组页，单分组图源直接进入网格页。
class WallpaperLibraryPage extends StatelessWidget {
  const WallpaperLibraryPage({super.key});

  static const Set<String> _excludedSourceIds = {WallpaperSourceIds.video, WallpaperSourceIds.solidColor};

  @override
  Widget build(BuildContext context) {
    final sources = WallpaperRepository.instance
        .loadCatalog()
        .sources
        .where((source) => !_excludedSourceIds.contains(source.id))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: SettingsBreadcrumbBar(node: SettingsCrumbs.wallpaperLibrary)),
      body: sources.isEmpty
          ? const Center(child: Text('暂无图源'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                context.buildModernCard([
                  for (final source in sources)
                    context.buildTile(
                      icon: _sourceIcon(source.kind),
                      title: wallpaperSourceName(source.id),
                      subtitle: source.categorized && source.visibleGroups.length > 1
                          ? '${source.visibleGroups.length} 个分类'
                          : null,
                      trailing: const Icon(Remix.arrow_right_s_line),
                      onTap: () => _open(context, source),
                    ),
                ]),
              ],
            ),
    );
  }

  IconData _sourceIcon(WallpaperKind kind) {
    switch (kind) {
      case WallpaperKind.video:
        return Remix.film_line;
      case WallpaperKind.gradient:
        return Remix.palette_line;
      case WallpaperKind.image:
        return Remix.image_2_line;
    }
  }

  void _open(BuildContext context, CatalogWallpaperSource source) {
    final groups = source.visibleGroups;
    if (groups.isEmpty) return;
    if (source.categorized && groups.length > 1) {
      SettingsNavigator.open(
        SettingsCrumb(
          labelText: wallpaperSourceName(source.id),
          routeName: '/settings/wallpaper/library/gallery',
          pageBuilder: () => WallpaperGalleryPage(sourceId: source.id),
          parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperLibrary],
        ),
      );
      return;
    }
    final title = source.categorized ? wallpaperGroupName(source.id, groups.first.id) : wallpaperSourceName(source.id);
    SettingsNavigator.open(
      SettingsCrumb(
        labelText: title,
        routeName: '/settings/wallpaper/library/items',
        pageBuilder: () => WallpaperItemsPage(sourceId: source.id, groupId: groups.first.id),
        parents: [SettingsCrumbs.root, SettingsCrumbs.wallpaper, SettingsCrumbs.wallpaperLibrary],
      ),
    );
  }
}
