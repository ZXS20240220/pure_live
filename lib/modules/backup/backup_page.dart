import 'dart:async';
import 'dart:io';

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pure_live/core/common/log.dart';
import 'package:pure_live/plugins/file_utils.dart';
import 'package:pure_live/modules/backup/scan_page.dart';
import 'package:pure_live/plugins/backup_recovery_service.dart';
import 'package:pure_live/common/services/settings/log_controller.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final LogController logController = LogController.to;
  String get backupDirectory => SettingsService.to.backup.backupDirectory.v;
  String get m3uDirectory => SettingsService.to.iptv.m3uDirectory.v;

  Future<void> _openLogDirectory() async {
    try {
      final logDir = await LogFileWriter.resolveLogDirectory();
      if (!await logDir.exists()) {
        ToastUtil.show(i18n('log_dir_not_exist'));
        return;
      }
      if (!await FileUtils.openFileOrUrl(logDir.path)) {
        ToastUtil.show(i18n('open_log_dir_failed'));
      }
    } catch (_) {
      ToastUtil.show(i18n('open_log_dir_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(i18n("backup_recover"))),
      body: ListView(
        physics: const PureLiveScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          context.buildGroupTitle(i18n("cloud_backup")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.qr_scan_2_line,
              title: i18n('remote_sync'),
              subtitle: i18n('remote_sync_subtitle'),
              onTap: () => Get.toNamed(RoutePath.kRemoteSync),
            ),
            context.buildTile(
              icon: Remix.cloud_line,
              title: i18n("webdav"),
              subtitle: i18n("backup_to_webdav"),
              isLong: true,
              onTap: () => Get.toNamed(RoutePath.kWebDavPage),
            ),
            if (Platform.isAndroid || Platform.isIOS)
              context.buildTile(
                icon: Remix.qr_code_line,
                title: i18n("sync_tv_data"),
                subtitle: i18n("sync_tv_data_subtitle"),
                isLong: true,
                onTap: () => Get.to(() => const ScanCodePage()),
              ),
          ]),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("local_backup")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.file_download_line,
              title: i18n("create_backup"),
              subtitle: i18n("create_backup_subtitle"),
              isLong: true,
              onTap: () async {
                // The export flow chooses a directory and remembers the first
                // successful choice; no separate first-run settings step.
                await BackupRecoveryService().createAppSettingsBackup(backupDirectory);
              },
            ),
            context.buildTile(
              icon: Remix.file_upload_line,
              title: i18n("recover_backup"),
              subtitle: i18n("recover_backup_subtitle"),
              isLong: true,
              onTap: () => BackupRecoveryService().recoverSettingsFromFile(),
            ),
          ]),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("backup_settings")),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.folder_open_line,
              title: i18n("backup_directory"),
              subtitle: backupDirectory.isEmpty ? i18n('please_set_backup_directory') : backupDirectory,
              isLong: true,
              onTap: () async {
                await BackupRecoveryService().updateBackupDirectory();
              },
            ),
          ]),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("log_manage")),
          context.buildModernCard([
            Obx(() {
              final applying = logController.isApplyingLogStatus.v;
              final statusKey = logController.logStatusKey.v;
              final subtitleKey = applying
                  ? 'local_log_applying'
                  : statusKey.isNotEmpty
                  ? statusKey
                  : 'enable_local_log_desc';
              return context.buildTile(
                icon: Remix.file_text_line,
                title: i18n("enable_local_log"),
                subtitle: i18n(subtitleKey),
                subtitleColor: statusKey.isNotEmpty && !applying ? Theme.of(context).colorScheme.error : null,
                isLong: true,
                stackTrailingOnNarrow: true,
                showNavigationChevronWhenStacked: false,
                trailing: Switch(
                  key: const ValueKey('local-log-switch'),
                  value: logController.storedEnableLog.v,
                  onChanged: applying ? null : (value) => unawaited(logController.setLoggingEnabled(value)),
                ),
                onTap: applying
                    ? null
                    : () => unawaited(logController.setLoggingEnabled(!logController.storedEnableLog.v)),
              );
            }),
            Obx(() {
              if (!logController.enableLog ||
                  logController.isApplyingLogStatus.v ||
                  logController.serverPort.value == 0) {
                return const SizedBox.shrink();
              }
              final uri = Uri(
                scheme: 'http',
                host: logController.serverAddress.value,
                port: logController.serverPort.value,
              );
              return context.buildTile(
                icon: Remix.global_line,
                title: i18n("view_logs_in_browser"),
                subtitle: uri.toString(),
                isLong: true,
                trailing: const Icon(Remix.arrow_right_s_line),
                onTap: () async {
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              );
            }),

            context.buildTile(
              icon: Remix.folder_open_line,
              title: i18n("open_log_dir"),
              subtitle: i18n("open_log_dir_desc"),
              isLong: true,
              onTap: _openLogDirectory,
            ),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
