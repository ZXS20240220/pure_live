import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/services/itab_wallpaper_client.dart';

/// 壁纸数据仓库
///
/// 图源树是编译时常量 [WallpaperCatalog.builtIn]，图片来自 iTab API。
/// 纯色/渐变和 deepin 图源是本地数据，不需要网络请求。
class WallpaperRepository {
  WallpaperRepository._();

  static final WallpaperRepository instance = WallpaperRepository._();

  static const int officialPageSize = 24;
  static const int bingPageSize = 16;

  WallpaperCatalog loadCatalog() => WallpaperCatalog.builtIn();

  bool isLocalSource(String sourceId) =>
      sourceId == WallpaperSourceIds.solidColor || sourceId == WallpaperSourceIds.deepin;

  List<CatalogWallpaperItem> localItems(String sourceId) => LocalWallpapers.of(sourceId);

  int serverPageSize(String sourceId) => sourceId == WallpaperSourceIds.bing ? bingPageSize : officialPageSize;

  /// 获取一页壁纸数据
  Future<List<CatalogWallpaperItem>> fetchPage({
    required CatalogWallpaperSource source,
    required CatalogWallpaperGroup group,
    required int page,
    required int size,
  }) async {
    if (isLocalSource(source.id)) return localItems(source.id);

    final String route;
    final Map<String, dynamic> query;
    String? nameKey;
    var uhd = false;
    var video = false;

    if (source.id == WallpaperSourceIds.wallhaven) {
      route = '/wallpaper/wallhaven';
      query = <String, dynamic>{
        'sr': ItabWallpaperClient.resolution,
        if (group.apiQuery.isNotEmpty) 'q': group.apiQuery,
      };
    } else if (source.id == WallpaperSourceIds.bing) {
      route = '/bing/list';
      query = const <String, dynamic>{};
      nameKey = 'copyright';
      uhd = true;
    } else if (source.id == WallpaperSourceIds.video) {
      route = '/wallpaper/video/list';
      query = const <String, dynamic>{'sortKey': 'updateTime'};
      video = true;
    } else {
      route = '/wallpaper/list';
      query = <String, dynamic>{
        'sr': ItabWallpaperClient.resolution,
        'category': group.apiQuery,
        'sortKey': 'updateTime',
      };
    }

    final json = await ItabWallpaperClient.instance.getJson(route, <String, dynamic>{
      ...query,
      'size': '$size',
      'page': '$page',
    });

    final rows = json['data'];
    if (rows is! List) return const <CatalogWallpaperItem>[];

    final items = <CatalogWallpaperItem>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final item = _item(Map<String, dynamic>.from(row), nameKey: nameKey, uhd: uhd, video: video);
      if (item != null) items.add(item);
    }
    return items;
  }

  static CatalogWallpaperItem? _item(
    Map<String, dynamic> row, {
    String? nameKey,
    bool uhd = false,
    bool video = false,
  }) {
    var raw = (video ? row['url'] : (row['raw'] ?? row['url']))?.toString() ?? '';
    if (raw.isEmpty) return null;
    if (uhd) raw = _bingUhd(raw);

    final thumb = row['thumb']?.toString() ?? '';
    final poster = row['poster']?.toString() ?? '';
    String name = row['name']?.toString() ?? '';
    if (name.isEmpty && nameKey != null) name = row[nameKey]?.toString() ?? '';
    if (name.isEmpty) name = _stem(raw);

    return CatalogWallpaperItem(
      file: raw,
      thumb: thumb.isNotEmpty ? thumb : cdnThumb(raw),
      poster: video && poster.isNotEmpty ? poster : null,
      id: (row['id'] ?? row['_id'])?.toString(),
      name: name,
    );
  }

  static String _bingUhd(String raw) => raw.replaceFirst('1920x1080.jpg&rf=LaDigue_1920x1080.jpg&pid=hp', 'UHD.jpg');

  static String _stem(String url) {
    final path = url.split('?').first;
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
