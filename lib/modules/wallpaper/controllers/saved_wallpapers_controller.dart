import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_thumbnail_service.dart';

/// 已保存壁纸条目（应用过的壁纸会复制到 WALLPAPER 目录）
class SavedWallpaperItem {
  final String path;
  final String name;
  final bool isVideo;
  final DateTime createdTime;

  const SavedWallpaperItem({required this.path, required this.name, required this.isVideo, required this.createdTime});
}

/// 已保存壁纸列表控制器
///
/// 扫描 WALLPAPER 目录，列出所有图片和视频文件，支持应用和删除。
class SavedWallpapersController extends ServerAllPageController<SavedWallpaperItem> {
  static SavedWallpapersController get to => Get.find<SavedWallpapersController>();

  Timer? _viewportPageDebounce;
  Worker? _wallpaperSourceWorker;

  @override
  void onInit() {
    super.onInit();
    // 监听当前壁纸变化，实时刷新选中状态
    final settings = WallpaperSettingsController.to;
    _wallpaperSourceWorker = ever(settings.wallpaperSource, (_) {
      update();
    });
  }

  void applyViewportPageSize(int capacity) {
    if (isClosed) return;
    final target = capacity < 10 ? 10 : capacity;
    if (pageSize.value == target) return;
    _viewportPageDebounce?.cancel();
    _viewportPageDebounce = Timer(const Duration(milliseconds: 150), () {
      if (isClosed) return;
      setPageSize(target);
    });
  }

  @override
  void onClose() {
    _viewportPageDebounce?.cancel();
    _wallpaperSourceWorker?.dispose();
    super.onClose();
  }

  @override
  Future<List<SavedWallpaperItem>> fetchAllServerData() async {
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    if (!await dir.exists()) return const <SavedWallpaperItem>[];

    final items = <SavedWallpaperItem>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      final name = p.basename(entity.path);
      final lower = name.toLowerCase();
      final isVideo =
          lower.endsWith('.mp4') ||
          lower.endsWith('.avi') ||
          lower.endsWith('.wmv') ||
          lower.endsWith('.rmvb') ||
          lower.endsWith('.mpg') ||
          lower.endsWith('.mpeg') ||
          lower.endsWith('.3gp') ||
          lower.endsWith('.webm') ||
          lower.endsWith('.mov') ||
          lower.endsWith('.mkv');
      final isImage =
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.bmp') ||
          lower.endsWith('.webp');
      if (!isVideo && !isImage) continue;
      // Windows 上 stat.changed 即文件创建时间
      items.add(SavedWallpaperItem(path: entity.path, name: name, isVideo: isVideo, createdTime: stat.changed));
    }

    // 创建时间越新越靠前
    items.sort((a, b) => b.createdTime.compareTo(a.createdTime));
    return items;
  }

  /// 判断条目是否为当前应用的壁纸
  bool isCurrent(SavedWallpaperItem item) {
    final controller = WallpaperSettingsController.to;
    if (!controller.hasWallpaper) return false;
    final source = controller.wallpaperSource.v;
    if (source.isEmpty) return false;
    return source == item.path || source.endsWith('/${item.name}') || source.endsWith('\\${item.name}');
  }

  /// 应用壁纸
  Future<void> apply(SavedWallpaperItem item) async {
    final type = item.isVideo ? WallpaperType.videoLocal : WallpaperType.imageLocal;
    await WallpaperSettingsController.to.applyWallpaper(
      WallpaperItem(id: item.path, type: type, url: item.path, name: item.name),
    );
  }

  /// 删除壁纸文件
  Future<void> delete(SavedWallpaperItem item) async {
    try {
      final file = File(item.path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 删除失败忽略
    }
    // 删除对应的缩略图缓存
    if (item.isVideo) {
      await WallpaperThumbnailService.to.deleteThumbnail(item.path);
    }
    // 若删除的是当前壁纸，清除壁纸状态
    if (isCurrent(item)) {
      WallpaperSettingsController.to.clearWallpaper();
    }
    await refreshData();
  }

  /// 一键清空所有已保存壁纸，并清除当前壁纸
  Future<void> clearAll() async {
    final dir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }

    // 清除缩略图缓存
    await WallpaperThumbnailService.to.clearAll();

    // 清除当前壁纸
    WallpaperSettingsController.to.clearWallpaper();

    await refreshData();
  }
}
