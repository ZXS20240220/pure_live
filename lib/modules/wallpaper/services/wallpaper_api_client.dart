import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_api_catalog.dart';

/// 从随机图源 API 获取一张随机图片
///
/// 不同 API 返回格式不同：
/// - [WallpaperApiKind.direct]：URL 直接返回图片字节
/// - [WallpaperApiKind.json]：URL 返回 JSON，需解析出图片地址再下载
/// - [WallpaperApiKind.alcy]：分类作为路径段追加到基础 URL
class WallpaperApiClient {
  WallpaperApiClient._();

  static final WallpaperApiClient instance = WallpaperApiClient._();

  /// 桌面端 UA，部分 API 会拒绝移动端 UA 或返回 HTML
  static const Map<String, dynamic> _headers = <String, dynamic>{
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36',
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };

  final Random _random = Random();

  /// 获取一张随机图片的字节数据，失败返回 null
  Future<Uint8List?> fetchRandomImage(WallpaperApiSource source) async {
    final String? imageUrl = switch (source.kind) {
      WallpaperApiKind.direct => source.url,
      WallpaperApiKind.alcy =>
        '${source.url}${WallpaperApiSource.alcyCategories[_random.nextInt(WallpaperApiSource.alcyCategories.length)]}',
      WallpaperApiKind.json => await _resolveJsonUrl(source),
    };
    if (imageUrl == null || imageUrl.isEmpty) return null;
    return _downloadImage(imageUrl);
  }

  /// 从 JSON 响应中解析图片地址
  Future<String?> _resolveJsonUrl(WallpaperApiSource source) async {
    final String? apiKey = source.apiKey;
    final String query = apiKey == null ? '' : '${source.url.contains('?') ? '&' : '?'}type=json&apiKey=$apiKey';
    try {
      final dynamic data = await HttpClient.instance.getJson('${source.url}$query', header: _headers);
      return _pickUrl(data);
    } catch (_) {
      return null;
    }
  }

  /// 从各种 JSON 结构中提取图片 URL
  static String? _pickUrl(dynamic data) {
    if (data is String) {
      final String value = data.trim().replaceAll('&amp;', '&');
      return value.startsWith('http') ? value : null;
    }
    if (data is Map) {
      for (final String key in const <String>[
        'image_url',
        'imageUrl',
        'content',
        'url',
        'img',
        'imgurl',
        'data',
        'image',
        'images',
      ]) {
        final String? found = _pickUrl(data[key]);
        if (found != null) return found;
      }
      return null;
    }
    if (data is List && data.isNotEmpty) return _pickUrl(data.first);
    return null;
  }

  /// 下载图片字节并校验是否为有效图片
  Future<Uint8List?> _downloadImage(String url) async {
    try {
      final response = await HttpClient.instance.dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes, headers: _headers),
      );
      final bytes = response.data;
      if (bytes == null || bytes.length < 256) return null;
      final uint8 = Uint8List.fromList(bytes);
      return _isValidImage(uint8) ? uint8 : null;
    } catch (_) {
      return null;
    }
  }

  /// 通过魔数判断是否为有效图片格式
  static bool _isValidImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true;
    }
    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true;
    }
    // WebP: 52 49 46 46 ... 57 45 42 50
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true;
    }
    return false;
  }
}
