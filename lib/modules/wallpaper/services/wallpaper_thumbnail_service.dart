import 'dart:io';

import 'package:ffmpeg_kit_extended_flutter/ffmpeg_kit_extended_flutter.dart' hide Log;
import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/recorder/services/ffmpeg_service.dart';

/// 视频壁纸缩略图服务
///
/// 使用 FFmpeg 截取视频第一帧，缓存到缩略图目录，供网格卡片显示。
class WallpaperThumbnailService {
  WallpaperThumbnailService._internal();
  static final WallpaperThumbnailService _instance = WallpaperThumbnailService._internal();
  static WallpaperThumbnailService get to => _instance;

  static const String _thumbDir = 'WALLPAPER_THUMB';
  static const Duration _seekPosition = Duration(milliseconds: 500);

  final Map<String, Future<String?>> _pending = {};
  Future<void>? _ffmpegInit;

  /// 确保 FFmpeg 已初始化（桌面端默认不预热，需按需初始化）
  Future<void> _ensureFFmpegReady() async {
    if (_ffmpegInit != null) return _ffmpegInit;
    _ffmpegInit = FFmpegService.to.initialize();
    try {
      await _ffmpegInit;
    } catch (_) {
      _ffmpegInit = null;
      rethrow;
    }
  }

  /// 获取视频缩略图文件路径。
  ///
  /// 已缓存时直接返回路径；否则异步生成并返回生成后的路径。
  Future<String?> getThumbnail(String videoPath) async {
    final thumbPath = await _thumbPath(videoPath);
    if (File(thumbPath).existsSync()) return thumbPath;

    final pending = _pending[videoPath];
    if (pending != null) return pending;

    final future = _generate(videoPath, thumbPath);
    _pending[videoPath] = future;
    final result = await future;
    _pending.remove(videoPath);
    return result;
  }

  Future<String> _thumbPath(String videoPath) async {
    final dir = await AppPathManager().getDir(_thumbDir);
    final base = p.basenameWithoutExtension(videoPath);
    return p.join(dir.path, '$base.jpg');
  }

  Future<String?> _generate(String videoPath, String thumbPath) async {
    try {
      await _ensureFFmpegReady();
    } catch (_) {
      return null;
    }

    try {
      final args = <String>[
        '-ss',
        '${_seekPosition.inMilliseconds / 1000}',
        '-i',
        videoPath,
        '-frames:v',
        '1',
        '-q:v',
        '3',
        '-vf',
        'scale=480:-2',
        '-y',
        thumbPath,
      ];
      final session = FFmpegKit.createSessionFromArguments(args);
      await session.executeAsync();
      final code = session.getReturnCode();
      if (code == 0 && File(thumbPath).existsSync()) {
        return thumbPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 删除指定视频对应的缩略图缓存
  Future<void> deleteThumbnail(String videoPath) async {
    final thumbPath = await _thumbPath(videoPath);
    final file = File(thumbPath);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// 清空所有缩略图缓存
  Future<void> clearAll() async {
    _pending.clear();
    final dir = await AppPathManager().getDir(_thumbDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
