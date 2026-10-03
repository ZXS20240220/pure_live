import 'dart:io';
import 'dart:convert';

import 'file_utils.dart';

import 'package:pure_live/common/index.dart';
import 'package:file_picker/file_picker.dart';
import 'package:date_format/date_format.dart' hide S;
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/common/services/settings/backup_controller.dart';

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

  Future<void> recoverSettingsFromFile() async {
    final backup = Get.find<BackupController>();
    final result = await FilePicker.pickFile(
      dialogTitle: i18n("select_recover_file"),
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );

    if (result?.path == null) return;

    final file = File(result!.path!);
    if (await backup.recover(file)) {
      ToastUtil.show(i18n("recover_backup_success"));
    } else {
      ToastUtil.show(i18n("recover_backup_failed"));
    }
  }

  Future<String?> updateBackupDirectory() async {
    final backup = Get.find<BackupController>();
    String? selectedDirectory = await FilePicker.getDirectoryPath();
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
