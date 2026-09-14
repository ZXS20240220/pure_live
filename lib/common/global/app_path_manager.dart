import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pure_live/common/utils/windows_multi_instance_launcher.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'windows_portable_path_provider.dart';

class AppPathManager {
  static final AppPathManager _instance = AppPathManager._internal();
  factory AppPathManager() => _instance;
  AppPathManager._internal();

  static const String dirAppData = 'AppData';
  static const String softNameDir = 'PURE_LIVE';
  static const String dirIptvCache = 'IPTV_CACHE';
  static const String iptvTable = 'pure_live_tv';
  static const String dirDownload = 'DOWNLOADS';
  static const String dirLogs = 'LOGS';
  static const String dirHiveDB = 'HIVE_DB';
  static const String dirImageCache = 'IMAGE_CACHE';
  static const String dirRecords = 'RECORDS';
  static const String dirEmojiCache = 'EMOJI_CACHE';
  static const String dirMigrationBackup = 'MIGRATION_BACKUP';

  static const String fontDirectoryName = 'fonts';
  static const String fontCacheDir = fontDirectoryName;
  static const String iptvCategoryFile = 'categories.json';
  static const String iptvHotFile = 'hot.m3u';
  static const String iptvHotRemoteFile =
      'https://raw.githubusercontent.com/YueChan/Live/main/GNTV.m3u';

  String? _basePath;
  final List<String> _legacyHiveFiles = const [];

  List<String> get legacyHiveFiles => List.unmodifiable(_legacyHiveFiles);

  Future<void> initialize({String instanceId = ''}) async {
    final sanitizedInstanceId = WindowsMultiInstanceLauncher.sanitizeInstanceId(instanceId);

    final originalPathProvider = PathProviderPlatform.instance;
    final appDir = await getApplicationDocumentsDirectory();
    final supportDir = await getApplicationSupportDirectory();

    var rootPath = '';
    if (kIsWeb) {
      rootPath = softNameDir;
    } else if (Platform.isWindows) {
      rootPath = await _selectWindowsDataRoot(supportDir);
    } else {
      rootPath = p.join(appDir.path, softNameDir);
    }

    if (sanitizedInstanceId.isNotEmpty) {
      rootPath = p.join(rootPath, sanitizedInstanceId);
    }
    await Directory(rootPath).create(recursive: true);
    _basePath = rootPath;

    if (!kIsWeb && Platform.isWindows && !_isWindowsMsix) {
      PathProviderPlatform.instance = WindowsPortablePathProvider(
        delegate: originalPathProvider,
        dataRoot: rootPath,
      );
      configureWindowsPortableSharedPreferences(rootPath);
    }
  }

  Future<String> _selectWindowsDataRoot(Directory supportDir) async {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final localRoot = p.join(exeDir, dirAppData);
    if (await _checkDirectoryWritable(localRoot)) return localRoot;

    final fallback = p.join(supportDir.path, softNameDir);
    await Directory(fallback).create(recursive: true);
    log('Windows 安装目录只读，数据目录回退至 $fallback');
    return fallback;
  }

  Future<bool> _checkDirectoryWritable(String path) async {
    try {
      final testDir = Directory(path);
      await testDir.create(recursive: true);
      final testFile = File(
        p.join(path, '.permission_test_${DateTime.now().microsecondsSinceEpoch}'),
      );
      await testFile.writeAsString('test', flush: true);
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> getDir(String segment) async {
    final targetPath = p.join(basePath, segment);
    final directory = Directory(targetPath);
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> get iptvCacheDir => getDir(dirIptvCache);
  Future<Directory> get downloadDir => getDir(dirDownload);
  Future<Directory> get logsDir => getDir(dirLogs);
  Future<Directory> get logFilesDir => getDir(p.join(dirLogs, 'log'));
  Future<Directory> get hiveDbDir => getDir(dirHiveDB);
  Future<Directory> get imageCacheDir => getDir(dirImageCache);
  Future<Directory> get recordsDir => getDir(dirRecords);
  Future<Directory> get emojiCacheDir => getDir(dirEmojiCache);
  Future<Directory> get migrationWorkingDir => getDir(p.join(dirMigrationBackup, 'working'));

  String get basePath => _basePath ?? (throw StateError('AppPathManager 尚未初始化'));

  Future<String> getFontFamilyFolderPath(String id) async {
    final downloadDir = await getDir(dirDownload);
    return fontFamilyFolderPath(downloadDir.path, id);
  }

  bool get _isWindowsMsix {
    if (!Platform.isWindows) return false;
    return isWindowsMsixExecutablePath(Platform.resolvedExecutable);
  }

  @visibleForTesting
  static bool isWindowsMsixExecutablePath(String path) {
    final normalized = path.replaceAll('/', r'\').toLowerCase();
    return normalized.contains(r'\windowsapps\');
  }

  @visibleForTesting
  static String fontFamilyFolderPath(String downloadPath, String id) {
    return p.join(downloadPath, fontDirectoryName, id);
  }

  static String logFilesDirectoryPath(String logsRoot) {
    return p.join(logsRoot, 'log');
  }
}
