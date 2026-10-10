import 'dart:convert';

import 'package:pure_live/core/common/http_client.dart';

/// iTab 壁纸 API 客户端
///
/// 复用 iTab 浏览器扩展的接口，无需鉴权，请求带特定 Header 即可。
/// 走项目全局 [HttpClient]，自动继承代理配置。
class ItabWallpaperClient {
  ItabWallpaperClient._();
  static final ItabWallpaperClient instance = ItabWallpaperClient._();

  /// JSON API 主机
  static const String baseUrl = 'https://base.itab.link';

  /// 静态文件主机（图片/视频）
  static const String filesUrl = 'https://files.itab.link';

  /// 分辨率提示，服务器最高返回 2560 宽
  static const String resolution = '3840x2160';

  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36',
    'fp': 'zhVusd_0lS.1758762915',
    'mode': 'itab',
    'origin': 'chrome-extension://mhloojimgilafopcmlcikiidgbbnelip',
    'version': '2.2.25',
    'accept': 'application/json, text/plain, */*',
    'Referer': 'https://www.itab.link/',
  };

  /// 获取一页动态壁纸列表
  ///
  /// [page] 从 1 开始，[size] 每页数量。
  Future<List<VideoWallpaperItem>> fetchVideoList({int page = 1, int size = 24}) async {
    final json = await getJson('/wallpaper/video/list', <String, dynamic>{
      'sortKey': 'updateTime',
      'size': '$size',
      'page': '$page',
    });
    final rows = json['data'];
    if (rows is! List) return const <VideoWallpaperItem>[];
    final items = <VideoWallpaperItem>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final item = VideoWallpaperItem.fromJson(Map<String, dynamic>.from(row));
      if (item != null) items.add(item);
    }
    return items;
  }

  /// GET [route] 并解析为 JSON 对象
  Future<Map<String, dynamic>> getJson(String route, Map<String, dynamic> query) async {
    final data = await HttpClient.instance.getJson(
      '$baseUrl$route',
      queryParameters: <String, dynamic>{'lang': 'cn', ...query},
      header: _headers,
    );
    final Map<String, dynamic> json;
    if (data is Map) {
      json = Map<String, dynamic>.from(data);
    } else if (data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is! Map) {
        throw const FormatException('iTab response is not a JSON object');
      }
      json = Map<String, dynamic>.from(decoded);
    } else {
      throw const FormatException('iTab response is empty');
    }
    final code = json['code'];
    if (code is num && code != 200 && code != 0) {
      throw Exception('iTab code=$code ${json['msg'] ?? ''}');
    }
    return json;
  }
}

/// 动态壁纸条目
class VideoWallpaperItem {
  const VideoWallpaperItem({required this.url, this.thumb, this.poster, this.name, this.id});

  /// 视频地址
  final String url;

  /// 缩略图（网格预览）
  final String? thumb;

  /// 海报图
  final String? poster;

  /// 名称
  final String? name;

  /// 服务端 ID
  final String? id;

  /// 从 API 行解析，缺少 url 时返回 null
  static VideoWallpaperItem? fromJson(Map<String, dynamic> row) {
    final url = row['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return VideoWallpaperItem(
      url: url,
      thumb: row['thumb']?.toString(),
      poster: row['poster']?.toString(),
      name: row['name']?.toString() ?? _stem(url),
      id: (row['id'] ?? row['_id'])?.toString(),
    );
  }

  static String _stem(String url) {
    final segment = url.split('/').last;
    final dot = segment.indexOf('.');
    return dot > 0 ? segment.substring(0, dot) : segment;
  }
}
