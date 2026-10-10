import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/core/common/http_client.dart';

/// 壁纸媒体文件缓存层。
///
/// 对齐上游 `WallpaperMediaStore`：网络壁纸不直接流式播放，而是先下载到
/// 应用数据目录的 WALLPAPER 文件夹，再以本地路径应用。这样做有两个原因：
/// 1. 网络波动时不会出现黑屏（本地文件不会半开失败）
/// 2. 同一壁纸重复应用时直接命中缓存，无需再次下载
class WallpaperMediaStore {
  const WallpaperMediaStore._();

  /// 下载 [url] 到 WALLPAPER 目录并返回本地路径。
  ///
  /// 若文件已存在且非空则直接复用，避免重复下载。
  static Future<String> download(String url, {void Function(int received, int total)? onProgress}) async {
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    final file = File(p.join(dir.path, _fileName(url)));
    if (await file.exists() && await file.length() > 0) return file.path;

    await HttpClient.instance.download(
      url,
      file.path,
      header: wallpaperVideoHttpHeaders(),
      onReceiveProgress: onProgress,
    );
    return file.path;
  }

  /// 将用户选择的本地文件复制到 WALLPAPER 目录，返回新路径。
  ///
  /// 若源文件已在 WALLPAPER 目录内则直接返回原路径。
  static Future<String> importFile(String sourcePath) async {
    final source = File(sourcePath);
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    final target = File(p.join(dir.path, _fileName(p.basename(sourcePath))));
    if (p.equals(target.path, source.path)) return target.path;
    await source.copy(target.path);
    return target.path;
  }

  /// 保存随机图源返回的图片字节，返回本地路径。
  ///
  /// 用内容哈希命名，相同图片复用同一文件；用魔数判断真实格式后缀。
  static Future<String> saveImageBytes(Uint8List bytes) async {
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    final extension = imageFormatOf(bytes) ?? 'img';
    final file = File(p.join(dir.path, 'random-${_contentHash(bytes)}.$extension'));
    if (await file.exists() && await file.length() > 0) return file.path;
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 通过魔数判断图片格式，返回小写扩展名；非图片返回 null。
  static String? imageFormatOf(Uint8List bytes) {
    if (bytes.length < 12) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return 'png';
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return 'gif';
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
      final brand = String.fromCharCodes(bytes.sublist(8, 12));
      if (brand.startsWith('avi')) return 'avif';
      if (brand.startsWith('hei') || brand.startsWith('mif')) return 'heic';
    }
    return null;
  }

  /// FNV-1a 哈希，跨平台稳定。
  static String _contentHash(Uint8List bytes) {
    var hash = 0x811C9DC5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${hash.toRadixString(16).padLeft(8, '0')}-${bytes.length.toRadixString(16)}';
  }

  /// 检查 [url] 是否已缓存，返回本地路径；未缓存返回 null。
  static Future<String?> cachedPath(String url) async {
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    final file = File(p.join(dir.path, _fileName(url)));
    if (await file.exists() && await file.length() > 0) return file.path;
    return null;
  }

  /// 从 URL 或路径派生安全的文件名。
  static String _fileName(String source) {
    final raw = source.split('?').first.split('/').last;
    if (raw.isEmpty) return 'wallpaper.mp4';
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

/// iTab CDN 所需的请求头。
///
/// 缺少这些头 CDN 会返回 403，视频无法播放。
Map<String, String> wallpaperVideoHttpHeaders() => const <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36',
  'Referer': 'https://www.itab.link/',
};
