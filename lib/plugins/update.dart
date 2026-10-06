import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/widgets/download_apk_dialog.dart';
import 'package:pure_live/plugins/file_utils.dart';

Uri? updateDownloadUri(String rawUrl) {
  final uri = FileUtils.parseHttpUrl(rawUrl);
  return uri == null || uri.userInfo.isNotEmpty ? null : uri;
}

final List<String> mirrors = [
  'https://gh-proxy.org/',
  'https://gh.h233.eu.org/',
  'https://git.yylx.win/',
  'https://ghproxy.cc/',
  'https://cdn.gh-proxy.org/',
  'https://wget.la/',
  'https://github.ednovas.xyz/',
  'https://down.npee.cn/?',
  'https://slink.ltd/',
  'https://gitproxy.click/',
];

List<String> getMirrorUrls(String apkUrl, {bool githubOriginOnly = false}) {
  final uri = updateDownloadUri(apkUrl);
  if (uri == null) return const [];
  final normalizedUrl = uri.toString();
  if (githubOriginOnly) return [normalizedUrl];
  final mirrorsUrl = mirrors.map((e) => '$e$normalizedUrl').toList();
  mirrorsUrl.add(normalizedUrl);
  return mirrorsUrl.toSet().toList(growable: false);
}

/// 解析更新包下载目录：已设置时直接复用；未设置时弹出文件夹选择窗口，
/// 用户取消选择则返回 null 中止下载，选择结果持久化为默认下载目录。
Future<String?> _resolveDownloadDirectory() async {
  final app = SettingsService.to.app;
  final saved = app.downloadDirectory.v;
  if (saved.isNotEmpty) return saved;

  final selected = await FilePicker.getDirectoryPath();
  if (selected == null || selected.isEmpty) return null;
  app.downloadDirectory.v = selected;
  return selected;
}

Future<void> downloadAndInstallApk(String apkUrl, {String? fileName}) async {
  final uri = updateDownloadUri(apkUrl);
  if (uri == null) {
    ToastUtil.show(i18n('download_failed'));
    return;
  }
  final downloadDirectory = await _resolveDownloadDirectory();
  if (downloadDirectory == null) return;
  final resolvedFileName = safeDownloadFileName(uri.toString(), suggestedName: fileName);
  ToastUtil.show(
    fileName == null
        ? i18n('downloading_apk', args: {'version': VersionUtil.effectiveLatestVersion})
        : i18n('downloading_app', args: {'app': resolvedFileName}),
  );
  Get.dialog(
    DownloadApkDialog(
      apkUrl: uri.toString(),
      version: VersionUtil.effectiveLatestVersion,
      fileName: fileName == null ? null : resolvedFileName,
      downloadDirectoryProvider: () async => Directory(downloadDirectory),
    ),
    barrierDismissible: false,
  );
}
