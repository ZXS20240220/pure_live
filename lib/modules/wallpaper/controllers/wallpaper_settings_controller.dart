import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';

class WallpaperSettingsController extends GetxController {
  static WallpaperSettingsController get to => Get.find<WallpaperSettingsController>();

  // ===== 壁纸源 =====
  final RxString wallpaperTypeName = hiveString('wallpaperType', WallpaperType.none.name);
  final RxString wallpaperSource = hiveString('wallpaperSource', '');

  // ===== 显示效果 =====
  final RxInt fitIndex = hiveInt('wallpaperFitIndex', WallpaperFit.cover);
  final RxDouble maskOpacity = hiveDouble('wallpaperMaskOpacity', 0.35);
  final RxDouble blurRadius = hiveDouble('wallpaperBlurRadius', 0.0);

  // ===== 视频壁纸专属 =====
  final RxDouble videoVolume = hiveDouble('wallpaperVideoVolume', 0.0);
  final RxBool videoLoop = hiveBool('wallpaperVideoLoop', true);
  final RxBool pauseVideoWhenLivePlaying = hiveBool('wallpaperPauseOnLive', true);

  // ===== 在线壁纸专属 =====
  final RxString itabCategory = hiveString('wallpaperItabCategory', 'anime');

  // ===== 计算属性 =====
  WallpaperType get wallpaperType => _parseType(wallpaperTypeName.v);

  set wallpaperType(WallpaperType type) => wallpaperTypeName.v = type.name;

  bool get isVideo => wallpaperType.isVideo;

  bool get isImage => wallpaperType.isImage;

  /// 是否存在有效壁纸（上游无总开关，清除背景即关闭）
  bool get hasWallpaper => wallpaperType != WallpaperType.none && wallpaperSource.v.isNotEmpty;

  BoxFit get resolvedFit => WallpaperFit.toBoxFit(fitIndex.v);

  // ===== 类型解析 =====
  static WallpaperType _parseType(String name) {
    return WallpaperType.values.firstWhere((e) => e.name == name, orElse: () => WallpaperType.none);
  }

  // ===== 应用壁纸 =====
  Future<void> applyWallpaper(WallpaperItem item) async {
    // 本地壁纸：复制一份到应用数据目录，避免原文件被删除后失效
    final savedUrl = await _saveWallpaperFileIfNeeded(item);
    wallpaperType = item.type;
    wallpaperSource.v = savedUrl;
    _syncWindowEffect();
  }

  /// 将本地壁纸文件复制到应用数据目录的 WALLPAPER 文件夹，返回保存后的路径。
  /// 在线壁纸直接返回原 URL。
  Future<String> _saveWallpaperFileIfNeeded(WallpaperItem item) async {
    if (!item.type.isLocal) return item.url;

    final sourceFile = File(item.url);
    if (!sourceFile.existsSync()) return item.url;

    try {
      final wallpaperDir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
      final fileName = p.basename(item.url);
      final destPath = p.join(wallpaperDir.path, fileName);
      final destFile = File(destPath);

      if (destFile.path != sourceFile.path) {
        await sourceFile.copy(destPath);
      }
      return destPath;
    } catch (_) {
      // 复制失败时回退到原路径
      return item.url;
    }
  }

  /// 选择本地图片作为壁纸
  Future<void> pickLocalImage() async {
    final result = await FilePicker.pickFile(type: FileType.image, dialogTitle: '选择壁纸图片');
    if (result?.path == null) return;
    final path = result!.path!;
    await applyWallpaper(WallpaperItem(id: path, type: WallpaperType.imageLocal, url: path, name: p.basename(path)));
  }

  /// 选择本地视频作为壁纸
  Future<void> pickLocalVideo() async {
    final result = await FilePicker.pickFile(type: FileType.video, dialogTitle: '选择壁纸视频');
    if (result?.path == null) return;
    final path = result!.path!;
    await applyWallpaper(WallpaperItem(id: path, type: WallpaperType.videoLocal, url: path, name: p.basename(path)));
  }

  /// 清除壁纸（恢复使用主题底色）
  void clearWallpaper() {
    wallpaperType = WallpaperType.none;
    wallpaperSource.v = '';
    _syncWindowEffect();
  }

  // ===== 显示效果调整 =====
  void updateFit(int index) {
    fitIndex.v = index;
  }

  void updateMaskOpacity(double opacity) {
    maskOpacity.v = opacity.clamp(0.0, 1.0);
  }

  void updateBlurRadius(double radius) {
    blurRadius.v = radius.clamp(0.0, 50.0);
  }

  // ===== 视频设置 =====
  void updateVideoVolume(double volume) {
    videoVolume.v = volume.clamp(0.0, 1.0);
  }

  // ===== Mica 效果协调 =====
  void _syncWindowEffect() {
    if (!Platform.isWindows) return;
    if (hasWallpaper) {
      Window.setEffect(effect: WindowEffect.disabled, dark: false);
    } else {
      Window.setEffect(
        effect: WindowEffect.mica,
        dark: ui.PlatformDispatcher.instance.platformBrightness == ui.Brightness.dark,
      );
    }
  }

  // ===== 生命周期 =====
  @override
  void onInit() {
    super.onInit();
    everAll([wallpaperTypeName, wallpaperSource], (_) => _syncWindowEffect());
    // 初始化时同步一次窗口效果
    _syncWindowEffect();
  }

  // ===== 序列化（对齐 ThemeSettingsController 模式）=====
  Map<String, dynamic> toJson() {
    return {
      'wallpaperType': wallpaperTypeName.v,
      'wallpaperSource': wallpaperSource.v,
      'fitIndex': fitIndex.v,
      'maskOpacity': maskOpacity.v,
      'blurRadius': blurRadius.v,
      'videoVolume': videoVolume.v,
      'videoLoop': videoLoop.v,
      'pauseVideoWhenLivePlaying': pauseVideoWhenLivePlaying.v,
      'itabCategory': itabCategory.v,
    };
  }

  /// 解析完整段，不通知观察者也不持久化值。
  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    return {
      'wallpaperType': _normalizeType((json['wallpaperType'] ?? WallpaperType.none.name) as String),
      'wallpaperSource': (json['wallpaperSource'] ?? '') as String,
      'fitIndex': (json['fitIndex'] ?? WallpaperFit.cover) as int,
      'maskOpacity': _toDouble(json['maskOpacity'], 0.35),
      'blurRadius': _toDouble(json['blurRadius'], 0.0),
      'videoVolume': _toDouble(json['videoVolume'], 0.0),
      'videoLoop': (json['videoLoop'] ?? true) as bool,
      'pauseVideoWhenLivePlaying': (json['pauseVideoWhenLivePlaying'] ?? true) as bool,
      'itabCategory': (json['itabCategory'] ?? 'anime') as String,
    };
  }

  void fromJson(Map<String, dynamic> json) {
    final parsed = parseConfig(json);
    wallpaperTypeName.v = parsed['wallpaperType'];
    wallpaperSource.v = parsed['wallpaperSource'];
    fitIndex.v = parsed['fitIndex'];
    maskOpacity.v = parsed['maskOpacity'];
    blurRadius.v = parsed['blurRadius'];
    videoVolume.v = parsed['videoVolume'];
    videoLoop.v = parsed['videoLoop'];
    pauseVideoWhenLivePlaying.v = parsed['pauseVideoWhenLivePlaying'];
    itabCategory.v = parsed['itabCategory'];
  }

  static Map<String, dynamic> extractConfig(Map<String, dynamic>? rootConfig) {
    final wallpaper = rootConfig?['wallpaper'] as Map<String, dynamic>? ?? {};
    final parsed = parseConfig(wallpaper);
    return {
      'wallpaperType': parsed['wallpaperType'],
      'wallpaperSource': parsed['wallpaperSource'],
      'fitIndex': parsed['fitIndex'],
      'maskOpacity': parsed['maskOpacity'],
      'blurRadius': parsed['blurRadius'],
      'videoVolume': parsed['videoVolume'],
      'videoLoop': parsed['videoLoop'],
      'pauseVideoWhenLivePlaying': parsed['pauseVideoWhenLivePlaying'],
      'itabCategory': parsed['itabCategory'],
    };
  }

  static Map<String, dynamic> mergeConfig(Map<String, dynamic> rootConfig, Map<String, dynamic> updateFields) {
    final wallpaper = Map<String, dynamic>.from(rootConfig['wallpaper'] ?? {});
    updateFields.forEach((k, v) => wallpaper[k] = v);
    rootConfig['wallpaper'] = wallpaper;
    return rootConfig;
  }

  // ===== 工具方法 =====
  static String _normalizeType(String name) {
    return WallpaperType.values.any((e) => e.name == name) ? name : WallpaperType.none.name;
  }

  static double _toDouble(dynamic value, double defaultValue) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return defaultValue;
  }
}
