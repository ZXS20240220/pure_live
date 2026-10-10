import 'dart:io';
import 'dart:convert';

import 'file_utils.dart';

import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:date_format/date_format.dart' hide S;
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/common/services/settings/backup_controller.dart';
import 'package:pure_live/plugins/db_service.dart';
import 'package:pure_live/plugins/utils.dart';
import 'package:hive_ce/hive.dart';

/// 完整备份 zip 内的清单文件名，用于恢复时校验格式与版本。
const String _fullBackupManifestName = 'manifest.json';

/// 完整备份格式版本，恢复时据此判断兼容性。
const int _fullBackupVersion = 1;

class BackupRecoveryService {
  /// 已设置备份目录时直接在该目录创建备份文件；未设置时仅提示用户先设置，
  /// 不再弹出目录选择框。
  Future<String?> createAppSettingsBackup(String backupDirectory) async {
    final backup = Get.find<BackupController>();
    if (backupDirectory.isEmpty) {
      ToastUtil.show(i18n("please_set_backup_directory"));
      return null;
    }

    final granted = await FileUtils.requestStoragePermission();
    if (!granted) {
      ToastUtil.show(i18n("grant_storage_permission_first"));
      return null;
    }

    final dateStr = formatDate(DateTime.now(), [yyyy, '-', mm, '-', dd, 'T', HH, '_', nn, '_', ss]);
    final file = File('$backupDirectory/purelive_$dateStr.txt');

    if (backup.backup(file)) {
      ToastUtil.show(i18n("create_backup_success"));
      return backupDirectory;
    } else {
      ToastUtil.show(i18n("create_backup_failed"));
      return null;
    }
  }

  /// 创建完整备份：将设置(Hive)、IPTV 数据库、已下载字体打包为 zip，
  /// 写入已设置的备份目录。未设置目录时仅提示。
  Future<String?> createFullBackup(String backupDirectory) async {
    if (backupDirectory.isEmpty) {
      ToastUtil.show(i18n("please_set_backup_directory"));
      return null;
    }

    final granted = await FileUtils.requestStoragePermission();
    if (!granted) {
      ToastUtil.show(i18n("grant_storage_permission_first"));
      return null;
    }

    try {
      // 1. 落盘 Hive 数据，确保复制到的是最新状态。
      await HivePrefUtil.flush();

      // 2. SQLite WAL checkpoint，把 WAL 日志合并入主数据库文件。
      try {
        await Get.find<DbService>().db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {
        // checkpoint 失败不致命，仍会复制 wal/shm 文件。
      }

      final dateStr = formatDate(DateTime.now(), [yyyy, '-', mm, '-', dd, 'T', HH, '_', nn, '_', ss]);
      final zipPath = p.join(backupDirectory, 'purelive_full_$dateStr.zip');

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      // 清单文件
      final manifest = <String, dynamic>{
        'type': 'full_backup',
        'version': _fullBackupVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'modules': ['hive', 'iptv', 'fonts', 'wallpaper', 'wallpaperThumb'],
      };
      encoder.addArchiveFile(
        ArchiveFile.string(_fullBackupManifestName, const JsonEncoder.withIndent('  ').convert(manifest)),
      );

      // 设置(Hive)
      final hiveDir = await AppPathManager().getDir(AppPathManager.dirHiveDB);
      await _addDirectoryToZip(encoder, hiveDir, 'hive');

      // IPTV 数据库
      final iptvDir = await AppPathManager().getDir(AppPathManager.dirIptvCache);
      final iptvDbDir = Directory(p.join(iptvDir.path, AppPathManager.iptvTable));
      if (await iptvDbDir.exists()) {
        await _addDirectoryToZip(encoder, iptvDbDir, 'iptv');
      }

      // 已下载字体
      final downloadDir = await AppPathManager().getDir(AppPathManager.dirDownload);
      final fontsDir = Directory(p.join(downloadDir.path, AppPathManager.fontDirectoryName));
      if (await fontsDir.exists()) {
        await _addDirectoryToZip(encoder, fontsDir, 'fonts');
      }

      // 壁纸文件
      final wallpaperDir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
      if (await wallpaperDir.exists()) {
        await _addDirectoryToZip(encoder, wallpaperDir, 'wallpaper');
      }

      // 壁纸缩略图缓存
      final wallpaperThumbDir = await AppPathManager().getDir('WALLPAPER_THUMB');
      if (await wallpaperThumbDir.exists()) {
        await _addDirectoryToZip(encoder, wallpaperThumbDir, 'wallpaperThumb');
      }

      encoder.closeSync();

      ToastUtil.show(i18n("create_full_backup_success"));
      return zipPath;
    } catch (e) {
      ToastUtil.show(i18n("create_full_backup_failed"));
      return null;
    }
  }

  /// 递归把目录下的文件加入 zip，归档内路径以 [archivePrefix] 为根。
  /// 跳过 .lock 和 -shm 等临时/共享内存文件（Hive/SQLite 会自动重建），
  /// 并使用 readAsBytes 读取文件内容以避免 archive 的 InputFileStream
  /// 独占文件锁导致失败。
  Future<void> _addDirectoryToZip(ZipFileEncoder encoder, Directory dir, String archivePrefix) async {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.lock') || entity.path.endsWith('-shm')) continue;
      final relative = p.relative(entity.path, from: dir.path);
      final archivePath = p.posix.joinAll([archivePrefix, ...p.split(relative)]);
      final bytes = await entity.readAsBytes();
      encoder.addArchiveFile(ArchiveFile.bytes(archivePath, bytes));
    }
  }

  /// 恢复备份：根据文件扩展名自动识别完整备份(zip)或设置备份(txt)。
  Future<void> recoverSettingsFromFile() async {
    final result = await FilePicker.pickFile(
      dialogTitle: i18n("select_recover_file"),
      type: FileType.custom,
      allowedExtensions: ['txt', 'zip'],
    );

    // 原生文件选择对话框关闭后，清理残留的手势状态，避免 ListTile 卡在 pressed 状态。
    FileUtils.cancelStalePointerEvents();

    if (result?.path == null) return;

    final file = File(result!.path!);
    final ext = p.extension(file.path).toLowerCase();

    if (ext == '.zip') {
      await _recoverFromFullBackup(file);
    } else {
      final backup = Get.find<BackupController>();
      if (await backup.recover(file)) {
        ToastUtil.show(i18n("recover_backup_success"));
      } else {
        ToastUtil.show(i18n("recover_backup_failed"));
      }
    }
  }

  /// 从完整备份 zip 恢复。
  ///
  /// 时序保证（原子性）：先校验清单，再询问用户是否继续；
  /// 用户确认后才执行「解压 → 关闭连接 → 覆盖文件 → 重启」，
  /// 中间不再有用户交互空档，避免文件已替换但连接未重启的不一致状态。
  Future<void> _recoverFromFullBackup(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 1. 校验清单（只读，不产生副作用）
      final manifestEntry = archive.findFile(_fullBackupManifestName);
      if (manifestEntry == null) {
        ToastUtil.show(i18n("recover_full_backup_invalid"));
        return;
      }
      final manifest = jsonDecode(utf8.decode(manifestEntry.content)) as Map<String, dynamic>;
      if (manifest['type'] != 'full_backup') {
        ToastUtil.show(i18n("recover_full_backup_invalid"));
        return;
      }
      final version = manifest['version'];
      if (version is! int || version > _fullBackupVersion) {
        ToastUtil.show(i18n("recover_full_backup_unsupported"));
        return;
      }

      // 2. 询问用户：恢复后将自动重启，是否继续？
      //    此时尚未关闭任何连接、未覆盖任何文件，用户取消则应用不受影响。
      final confirmed = await Utils.showAlertDialog(
        i18n("recover_full_backup_restart_content"),
        title: i18n("recover_full_backup_restart_title"),
        confirm: i18n("restart_app"),
        cancel: i18n("cancel"),
        barrierDismissible: false,
      );
      if (!confirmed) return;

      // 3. 用户确认后，原子执行恢复并重启，中间不再交互。
      final tempDir = await Directory.systemTemp.createTemp('purelive_restore_');
      try {
        extractArchiveToDiskSync(archive, tempDir.path);

        // 关闭 Hive box 与数据库连接，再覆盖文件。
        try {
          await HivePrefUtil.flush();
        } catch (_) {}
        try {
          await Hive.box('app_settings').close();
        } catch (_) {}
        try {
          await Get.find<DbService>().db.close();
        } catch (_) {}

        // 恢复 Hive 设置
        final hiveRestoreDir = Directory(p.join(tempDir.path, 'hive'));
        if (await hiveRestoreDir.exists()) {
          final hiveTargetDir = await AppPathManager().getDir(AppPathManager.dirHiveDB);
          await _copyDirectoryContents(hiveRestoreDir, hiveTargetDir);
        }

        // 恢复 IPTV 数据库
        final iptvRestoreDir = Directory(p.join(tempDir.path, 'iptv'));
        if (await iptvRestoreDir.exists()) {
          final iptvCacheDir = await AppPathManager().getDir(AppPathManager.dirIptvCache);
          final iptvTargetDir = Directory(p.join(iptvCacheDir.path, AppPathManager.iptvTable));
          await iptvTargetDir.create(recursive: true);
          await _copyDirectoryContents(iptvRestoreDir, iptvTargetDir);
        }

        // 恢复字体
        final fontsRestoreDir = Directory(p.join(tempDir.path, 'fonts'));
        if (await fontsRestoreDir.exists()) {
          final downloadDir = await AppPathManager().getDir(AppPathManager.dirDownload);
          final fontsTargetDir = Directory(p.join(downloadDir.path, AppPathManager.fontDirectoryName));
          await fontsTargetDir.create(recursive: true);
          await _copyDirectoryContents(fontsRestoreDir, fontsTargetDir);
        }

        // 恢复壁纸文件
        final wallpaperRestoreDir = Directory(p.join(tempDir.path, 'wallpaper'));
        if (await wallpaperRestoreDir.exists()) {
          final wallpaperTargetDir = await AppPathManager().getDir(AppPathManager.dirWallpaper);
          await _copyDirectoryContents(wallpaperRestoreDir, wallpaperTargetDir);
        }

        // 恢复壁纸缩略图缓存
        final wallpaperThumbRestoreDir = Directory(p.join(tempDir.path, 'wallpaperThumb'));
        if (await wallpaperThumbRestoreDir.exists()) {
          final wallpaperThumbTargetDir = await AppPathManager().getDir('WALLPAPER_THUMB');
          await _copyDirectoryContents(wallpaperThumbRestoreDir, wallpaperThumbTargetDir);
        }

        ToastUtil.show(i18n("recover_full_backup_success"));
        // 文件已替换、连接已关闭，直接重启，不再二次询问。
        await _requestAppRestart();
      } finally {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      ToastUtil.show(i18n("recover_full_backup_failed"));
    }
  }

  /// 把 [source] 目录下的所有文件复制到 [target]，覆盖同名文件。
  Future<void> _copyDirectoryContents(Directory source, Directory target) async {
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source.path);
      final destPath = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destPath).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destPath)).create(recursive: true);
        await entity.copy(destPath);
      }
    }
  }

  /// 重启应用：复用托盘菜单同款实现，走原生 MethodChannel 拉起新进程。
  Future<void> _requestAppRestart() async {
    await Utils.restartDesktopApplication();
  }

  Future<String?> updateBackupDirectory() async {
    final backup = Get.find<BackupController>();
    String? selectedDirectory = await FilePicker.getDirectoryPath();
    FileUtils.cancelStalePointerEvents();
    if (selectedDirectory == null) return null;

    backup.backupDirectory.v = selectedDirectory;
    return selectedDirectory;
  }

  Future<bool> pushSettingsToRemoteServer(String httpAddress) async {
    final backup = Get.find<BackupController>();
    try {
      final response = await HttpClient.instance.postJson(
        '$httpAddress/api/setSettings',
        queryParameters: {"settings": jsonEncode(backup.exportToTVSettings())},
      );
      return jsonDecode(response)['data'] ?? false;
    } catch (e) {
      return false;
    }
  }
}
