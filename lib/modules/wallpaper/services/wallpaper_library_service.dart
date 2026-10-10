import 'package:pure_live/core/common/http_client.dart';

/// Wallhaven 壁纸条目
class WallhavenItem {
  final String id;
  final String url;
  final String fullUrl;
  final String thumbUrl;
  final int width;
  final int height;
  final String fileType;
  final int fileSize;

  const WallhavenItem({
    required this.id,
    required this.url,
    required this.fullUrl,
    required this.thumbUrl,
    required this.width,
    required this.height,
    required this.fileType,
    required this.fileSize,
  });

  factory WallhavenItem.fromJson(Map<String, dynamic> json) {
    final thumbs = json['thumbs'] as Map<String, dynamic>? ?? const {};
    return WallhavenItem(
      id: json['id'] as String? ?? '',
      url: json['url'] as String? ?? '',
      fullUrl: json['path'] as String? ?? '',
      thumbUrl: thumbs['small'] as String? ?? thumbs['original'] as String? ?? '',
      width: (json['dimension_x'] as num?)?.toInt() ?? 0,
      height: (json['dimension_y'] as num?)?.toInt() ?? 0,
      fileType: json['file_type'] as String? ?? '',
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Wallhaven 搜索服务
class WallhavenService {
  static const String _baseUrl = 'https://wallhaven.cc/api/v1/search';

  /// 搜索 Wallhaven 壁纸
  /// - [query]: 搜索关键词
  /// - [categories]: 分类，100=通用 010=动漫 001=人物，默认 111（全部）
  /// - [purity]: 内容分级，100=SFW 010=Sketchy，默认 100
  /// - [sorting]: 排序方式，date_added/relevance/random/views/favorites/toplist
  /// - [page]: 页码
  static Future<List<WallhavenItem>> search({
    String query = '',
    String categories = '111',
    String purity = '100',
    String sorting = 'random',
    int page = 1,
  }) async {
    try {
      final params = <String, dynamic>{'categories': categories, 'purity': purity, 'sorting': sorting, 'page': page};
      if (query.isNotEmpty) params['q'] = query;

      final data = await HttpClient.instance.getJson(_baseUrl, queryParameters: params);
      if (data is Map<String, dynamic>) {
        final list = data['data'] as List? ?? const [];
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => WallhavenItem.fromJson(e))
            .where((e) => e.fullUrl.isNotEmpty && e.fileType.startsWith('image/'))
            .toList();
      }
    } catch (_) {
      // 网络请求失败返回空列表
    }
    return const [];
  }
}

/// Bing 每日壁纸条目
class BingWallpaperItem {
  final String url;
  final String copyright;
  final String title;

  const BingWallpaperItem({required this.url, required this.copyright, required this.title});

  factory BingWallpaperItem.fromJson(Map<String, dynamic> json) {
    final urlBase = json['urlbase'] as String? ?? '';
    return BingWallpaperItem(
      url: 'https://www.bing.com${urlBase}_UHD.jpg',
      copyright: json['copyright'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}

/// Bing 每日壁纸服务
class BingWallpaperService {
  static const String _baseUrl = 'https://www.bing.com/HPImageArchive.aspx';

  /// 获取 Bing 每日壁纸列表
  /// - [idx]: 起始偏移（0=今天，1=昨天...）
  /// - [n]: 获取数量（最多 8）
  static Future<List<BingWallpaperItem>> getDaily({int idx = 0, int n = 8}) async {
    try {
      final data = await HttpClient.instance.getJson(
        _baseUrl,
        queryParameters: {'format': 'js', 'idx': idx, 'n': n, 'mkt': 'zh-CN'},
      );
      if (data is Map<String, dynamic>) {
        final list = data['images'] as List? ?? const [];
        return list.whereType<Map<String, dynamic>>().map((e) => BingWallpaperItem.fromJson(e)).toList();
      }
    } catch (_) {
      // 网络请求失败返回空列表
    }
    return const [];
  }
}
