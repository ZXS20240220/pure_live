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
import 'package:pure_live/plugins/file_utils.dart';
import 'package:pure_live/plugins/locale_helper.dart';

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

  // ===== PPT 壁纸专属 =====
  /// 选中参与 PPT 播放的图片路径列表
  final RxList<String> pptImagePaths = hiveStringList('wallpaperPptImagePaths', <String>[]);

  /// 切换间隔（秒），范围 1~3600
  final RxInt pptInterval = hiveInt('wallpaperPptInterval', 5);

  /// 切换规则：sequential / random
  final RxString pptMode = hiveString('wallpaperPptMode', PptMode.sequential.name);

  // ===== 计算属性 =====
  WallpaperType get wallpaperType => _parseType(wallpaperTypeName.v);

  set wallpaperType(WallpaperType type) => wallpaperTypeName.v = type.name;

  bool get isVideo => wallpaperType.isVideo;

  bool get isImage => wallpaperType.isImage;

  bool get isColor => wallpaperType.isColor;

  bool get isSlideshow => wallpaperType.isSlideshow;

  /// 是否存在有效壁纸（上游无总开关，清除背景即关闭）
  bool get hasWallpaper => wallpaperType != WallpaperType.none && wallpaperSource.v.isNotEmpty;

  BoxFit get resolvedFit => WallpaperFit.toBoxFit(fitIndex.v);

  /// 解析纯色/渐变壁纸数据
  ColorWallpaperData? get colorData {
    if (!isColor) return null;
    return ColorWallpaperData.deserialize(wallpaperSource.v);
  }

  // ===== 路径解析（basename ↔ 绝对路径）=====

  /// 当前运行时 WALLPAPER 目录的绝对路径（同步，AppPathManager 初始化后可用）
  String get _wallpaperDirPath => p.join(AppPathManager().basePath, AppPathManager.dirWallpaper);

  /// 将任意路径或文件名统一为 basename。
  /// 输入绝对路径 → 输出文件名；输入已是文件名 → 原样返回。
  static String _toName(String pathOrName) => p.basename(pathOrName);

  /// 将存储的值解析为运行时可用的绝对路径。
  /// 自动兼容旧数据（绝对路径）和新数据（basename）。
  /// 对 color / online / slideshow 等非本地类型原样返回。
  String resolveWallpaperSourcePath() {
    final source = wallpaperSource.v;
    if (source.isEmpty) return source;
    final type = wallpaperType;
    if (!type.isLocal) return source;
    if (source.contains('\\') || source.contains('/')) return source;
    return p.join(_wallpaperDirPath, source);
  }

  /// 将存储的 PPT 文件名列表解析为绝对路径列表。
  /// 自动兼容旧数据（绝对路径）和新数据（basename）。
  List<String> resolvePptPaths() {
    final dir = _wallpaperDirPath;
    return pptImagePaths.map((stored) {
      if (stored.contains('\\') || stored.contains('/')) return stored;
      return p.join(dir, stored);
    }).toList();
  }

  // ===== 类型解析 =====
  static WallpaperType _parseType(String name) {
    return WallpaperType.values.firstWhere((e) => e.name == name, orElse: () => WallpaperType.none);
  }

  // ===== 应用壁纸 =====
  Future<void> applyWallpaper(WallpaperItem item) async {
    final savedUrl = await _saveWallpaperFileIfNeeded(item);

    WallpaperType finalType = item.type;
    if (item.type.isOnline) {
      if (File(savedUrl).existsSync()) {
        finalType = item.type == WallpaperType.videoOnline ? WallpaperType.videoLocal : WallpaperType.imageLocal;
      }
    }

    wallpaperType = finalType;
    if (finalType.isLocal) {
      wallpaperSource.v = _toName(savedUrl);
    } else {
      wallpaperSource.v = savedUrl;
    }
    _syncWindowEffect();
  }

  /// 启用 PPT 壁纸（使用当前选中的图片列表与设置）
  ///
  /// 不再限制最少图片数量：1 张时静态展示，≥2 张时轮播。
  /// 若过滤失效文件后列表为空，则保持关闭状态。
  void applyPpt() {
    final names = pptImagePaths.toList();
    final dir = _wallpaperDirPath;
    final valid = <String>[];
    for (final name in names) {
      final path = (name.contains('\\') || name.contains('/')) ? name : p.join(dir, name);
      if (File(path).existsSync()) {
        valid.add(_toName(path));
      }
    }
    pptImagePaths.assignAll(valid);
    if (valid.isEmpty) {
      clearWallpaper();
      return;
    }
    wallpaperType = WallpaperType.slideshow;
    wallpaperSource.v = 'slideshow';
    _syncWindowEffect();
  }

  /// 切换某张图片在 PPT 列表中的选中状态。
  /// 无论传入绝对路径还是文件名，内部统一存储 basename。
  void togglePptImage(String path, bool selected) {
    final name = _toName(path);
    if (selected) {
      if (!pptImagePaths.contains(name)) pptImagePaths.add(name);
    } else {
      pptImagePaths.remove(name);
    }
  }

  /// PPT 播放时移除失效路径（文件不存在）。
  /// 兼容传入绝对路径或 basename。
  void removeInvalidPptImage(String path) {
    pptImagePaths.remove(_toName(path));
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
    final result = await FilePicker.pickFile(
      type: FileType.image,
      dialogTitle: i18n('wallpaper_pick_image_dialog_title'),
    );
    FileUtils.cancelStalePointerEvents();
    if (result?.path == null) return;
    final path = result!.path!;
    await applyWallpaper(WallpaperItem(id: path, type: WallpaperType.imageLocal, url: path, name: p.basename(path)));
  }

  /// 选择本地视频作为壁纸
  Future<void> pickLocalVideo() async {
    final result = await FilePicker.pickFile(
      type: FileType.video,
      dialogTitle: i18n('wallpaper_pick_video_dialog_title'),
    );
    FileUtils.cancelStalePointerEvents();
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
        name: i18n('wallpaper_default_solid_name'),
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
        WallpaperItem(
          id: localPath,
          type: WallpaperType.imageLocal,
          url: localPath,
          name: name ?? i18n('wallpaper_default_online_image_name'),
        ),
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
        WallpaperItem(
          id: localPath,
          type: WallpaperType.videoLocal,
          url: localPath,
          name: name ?? i18n('wallpaper_preview_dynamic_wallpaper'),
        ),
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
      await applyWallpaper(
        WallpaperItem(
          id: localPath,
          type: WallpaperType.imageLocal,
          url: localPath,
          name: i18n('wallpaper_default_random_name'),
        ),
      );
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
    return applyOnlineImage(item.fullUrl, name: i18n('wallpaper_default_random_name_with_id', args: {'id': item.id}));
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
    _normalizeStorage();
  }

  /// 将旧备份中的绝对路径统一迁移为 basename。
  /// - 对 wallpaperSource：仅 imageLocal / videoLocal 类型需要迁移
  /// - 对 pptImagePaths：全部条目迁移
  /// 幂等：已是 basename 的值不会重复触发 assignAll，避免无谓的 UI 刷新。
  void _normalizeStorage() {
    final type = wallpaperType;
    if ((type == WallpaperType.imageLocal || type == WallpaperType.videoLocal)) {
      final source = wallpaperSource.v;
      if (source.isNotEmpty && (source.contains('\\') || source.contains('/'))) {
        wallpaperSource.v = _toName(source);
      }
    }
    final hasOldPaths = pptImagePaths.any((s) => s.contains('\\') || s.contains('/'));
    if (hasOldPaths) {
      pptImagePaths.assignAll(pptImagePaths.map(_toName).toList());
    }
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
      'pptImagePaths': pptImagePaths.toList(),
      'pptInterval': pptInterval.v,
      'pptMode': pptMode.v,
    };
  }

  /// 解析完整段，不通知观察者也不持久化值。
  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    final rawPptPaths = json['pptImagePaths'];
    final pptImagePaths = rawPptPaths is List ? rawPptPaths.map((e) => e.toString()).toList() : <String>[];
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
      'pptImagePaths': pptImagePaths,
      'pptInterval': (json['pptInterval'] ?? 5) as int,
      'pptMode': (json['pptMode'] ?? PptMode.sequential.name) as String,
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
    pptImagePaths.assignAll(parsed['pptImagePaths'] as List<String>);
    pptInterval.v = parsed['pptInterval'] as int;
    pptMode.v = parsed['pptMode'] as String;

    _normalizeStorage();

    final type = wallpaperType;
    if (type.isOnline && wallpaperSource.v.isNotEmpty) {
      _downloadOnlineWallpaperToLocal(type, wallpaperSource.v);
    }
  }

  /// 将在线壁纸下载到本地，成功后转为本地类型并存储 basename。
  Future<void> _downloadOnlineWallpaperToLocal(WallpaperType type, String url) async {
    try {
      final localPath = await WallpaperMediaStore.download(url);
      if (File(localPath).existsSync()) {
        wallpaperSource.v = _toName(localPath);
        wallpaperType = type == WallpaperType.videoOnline ? WallpaperType.videoLocal : WallpaperType.imageLocal;
      }
    } catch (_) {}
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
      'pptImagePaths': parsed['pptImagePaths'],
      'pptInterval': parsed['pptInterval'],
      'pptMode': parsed['pptMode'],
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
    // 幻灯片模式没有单一当前壁纸
    if (wallpaperType == WallpaperType.slideshow) return false;
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

    final name = item.file.split('?').first.split('/').last;
    if (wallpaperType.isOnline) {
      return source == item.file || source.endsWith('/$name') || source == name;
    }
    return source == name;
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
