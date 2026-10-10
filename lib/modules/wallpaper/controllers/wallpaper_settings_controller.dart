import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_library_service.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_media_store.dart';

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

  bool get isColor => wallpaperType.isColor;

  /// 是否存在有效壁纸（上游无总开关，清除背景即关闭）
  bool get hasWallpaper => wallpaperType != WallpaperType.none && wallpaperSource.v.isNotEmpty;

  BoxFit get resolvedFit => WallpaperFit.toBoxFit(fitIndex.v);

  /// 解析纯色/渐变壁纸数据
  ColorWallpaperData? get colorData {
    if (!isColor) return null;
    return ColorWallpaperData.deserialize(wallpaperSource.v);
  }

  // ===== 类型解析 =====
  static WallpaperType _parseType(String name) {
    return WallpaperType.values.firstWhere((e) => e.name == name, orElse: () => WallpaperType.none);
  }

  // ===== 应用壁纸 =====
  Future<void> applyWallpaper(WallpaperItem item) async {
    final savedUrl = await _saveWallpaperFileIfNeeded(item);

    // 在线类型下载成功后转为本地类型，确保 wallpaperSource 始终指向本地文件
    WallpaperType finalType = item.type;
    if (item.type.isOnline) {
      if (File(savedUrl).existsSync()) {
        finalType = item.type == WallpaperType.videoOnline ? WallpaperType.videoLocal : WallpaperType.imageLocal;
      }
    }

    wallpaperType = finalType;
    wallpaperSource.v = savedUrl;
    _syncWindowEffect();
  }

  /// 将壁纸文件保存到应用数据目录的 WALLPAPER 文件夹，返回保存后的路径。
  /// - 本地类型：复制到 WALLPAPER 目录
  /// - 在线类型：下载到 WALLPAPER 目录
  /// - 纯色/渐变：直接返回序列化数据
  Future<String> _saveWallpaperFileIfNeeded(WallpaperItem item) async {
    if (item.type == WallpaperType.color) return item.url;

    if (item.type.isOnline) {
      try {
        return await WallpaperMediaStore.download(item.url);
      } catch (_) {
        return item.url;
      }
    }

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

  /// 应用纯色/渐变壁纸
  Future<void> applyColorWallpaper(ColorWallpaperData data) async {
    await applyWallpaper(
      WallpaperItem(
        id: 'color-${DateTime.now().millisecondsSinceEpoch}',
        type: WallpaperType.color,
        url: data.serialize(),
        name: '纯色壁纸',
      ),
    );
  }

  /// 应用在线图片壁纸（先下载到本地再应用）
  Future<bool> applyOnlineImage(String url, {String? name}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    try {
      final localPath = await WallpaperMediaStore.download(trimmed);
      await applyWallpaper(
        WallpaperItem(id: localPath, type: WallpaperType.imageLocal, url: localPath, name: name ?? '在线图片'),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 应用在线视频壁纸（先下载到本地再应用）
  Future<bool> applyOnlineVideo(String url, {String? name}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    try {
      final localPath = await WallpaperMediaStore.download(trimmed);
      await applyWallpaper(
        WallpaperItem(id: localPath, type: WallpaperType.videoLocal, url: localPath, name: name ?? '动态壁纸'),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 应用从随机图源获取的图片字节（保存为本地文件后应用）
  Future<bool> applyImageBytes(Uint8List bytes) async {
    try {
      final localPath = await WallpaperMediaStore.saveImageBytes(bytes);
      await applyWallpaper(WallpaperItem(id: localPath, type: WallpaperType.imageLocal, url: localPath, name: '随机壁纸'));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 随机获取一张壁纸并应用（下载到本地后应用）
  /// [categories]: 100=通用 010=动漫 001=人物，默认 111（全部）
  Future<bool> applyRandomWallpaper({String categories = '111'}) async {
    final items = await WallhavenService.search(categories: categories, sorting: 'random', page: 1);
    if (items.isEmpty) return false;
    final item = items.first;
    return applyOnlineImage(item.fullUrl, name: '随机壁纸 ${item.id}');
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
    _syncWindowEffect();
    _fixWallpaperPathIfNeeded();
  }

  /// 跨设备恢复时，wallpaperSource 中的绝对路径可能指向旧设备。
  /// 若文件不存在但 WALLPAPER 目录中有同名文件，则更新为当前设备的路径。
  Future<void> _fixWallpaperPathIfNeeded() async {
    final type = wallpaperType;
    if (type != WallpaperType.imageLocal && type != WallpaperType.videoLocal) return;
    final source = wallpaperSource.v;
    if (source.isEmpty) return;
    if (File(source).existsSync()) return;

    try {
      final wallpaperDir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
      final fileName = p.basename(source);
      final candidate = File(p.join(wallpaperDir.path, fileName));
      if (candidate.existsSync()) {
        wallpaperSource.v = candidate.path;
      }
    } catch (_) {}
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

    // 兼容旧备份：若导入的是在线壁纸 URL，异步下载到本地并转为本地类型
    final type = wallpaperType;
    if (type.isOnline && wallpaperSource.v.isNotEmpty) {
      _downloadOnlineWallpaperToLocal(type, wallpaperSource.v);
    } else {
      // 本地壁纸跨设备恢复时修正路径
      _fixWallpaperPathIfNeeded();
    }
  }

  /// 将在线壁纸下载到本地，成功后转为本地类型。
  Future<void> _downloadOnlineWallpaperToLocal(WallpaperType type, String url) async {
    try {
      final localPath = await WallpaperMediaStore.download(url);
      if (File(localPath).existsSync()) {
        wallpaperSource.v = localPath;
        wallpaperType = type == WallpaperType.videoOnline ? WallpaperType.videoLocal : WallpaperType.imageLocal;
      }
    } catch (_) {
      // 下载失败保持原样，渲染层会用 CachedNetworkImage 兜底
    }
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

  /// 判断目录中的条目是否就是当前应用的壁纸
  ///
  /// 下载到本地的文件通过文件名匹配，因为应用时用的是本地副本而非原始 URL。
  bool usesWallpaper(CatalogWallpaperItem item) {
    if (wallpaperType == WallpaperType.none) return false;
    final source = wallpaperSource.v;
    if (source.isEmpty) return false;

    // 纯色/渐变：比较颜色
    if (wallpaperType == WallpaperType.color) {
      final stops = item.gradient?.map((s) => colorFromHex(s.color)).whereType<Color>().toList();
      final data = colorData;
      if (stops == null || stops.isEmpty || data == null) return false;
      if (stops.length != data.colors.length) return false;
      for (var i = 0; i < stops.length; i++) {
        if (stops[i] != data.colors[i]) return false;
      }
      return true;
    }

    // 图片/视频：比较 URL 或文件名
    final name = item.file.split('?').first.split('/').last;
    return source == item.file || source.endsWith('/$name');
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
