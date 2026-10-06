import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:package_info_plus/package_info_plus.dart';

typedef VersionUpdateChecker = Future<bool> Function();
typedef VersionPackageInfoLoader = Future<PackageInfo> Function();

class ReleaseAssetUrls {
  const ReleaseAssetUrls({required this.projectUrl, required this.version, required this.buildNumber});

  final String projectUrl;
  final String version;
  final int buildNumber;

  String get normalizedVersion {
    final value = version.trim();
    return value.startsWith('v') || value.startsWith('V') ? value.substring(1) : value;
  }

  bool get isValid {
    final uri = Uri.tryParse(projectUrl.trim());
    final safeVersion =
        RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$').hasMatch(normalizedVersion) && !normalizedVersion.contains('..');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.userInfo.isEmpty &&
        safeVersion &&
        buildNumber > 0;
  }

  String get releaseBase {
    if (!isValid) return '';
    final normalizedProject = projectUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$normalizedProject/releases/download/v$normalizedVersion';
  }

  String _asset(String suffix) {
    if (!isValid) return '';
    return '$releaseBase/PureLive-dev-$normalizedVersion-$buildNumber-$suffix';
  }

  String get windowsSetup => _asset('windows-x64-setup.exe');
  String get windowsMsix => _asset('windows-x64.msix');
  String get windowsPortable => _asset('windows-x64-portable.zip');
  String get macosUniversal => _asset('macos-universal.zip');
}

class VersionController extends GetxController {
  VersionController({this.updateChecker, this.packageInfoLoader});

  final VersionUpdateChecker? updateChecker;
  final VersionPackageInfoLoader? packageInfoLoader;
  bool _checking = false;

  final hasNewVersion = false.obs;

  // =========================
  // Windows
  // =========================
  final windowsSetupUrl = ''.obs;
  final windowsMsixUrl = ''.obs;
  final windowsPortableUrl = ''.obs;

  // =========================
  // macOS
  // =========================
  final macosUrl = ''.obs;

  late PackageInfo packageInfo;

  final loading = true.obs;
  final error = false.obs;
  final updateLog = ''.obs;

  @override
  void onInit() {
    super.onInit();
    unawaited(checkNewVersion());
  }

  Future<void> getPackageInfo() async {
    packageInfo = await (packageInfoLoader?.call() ?? PackageInfo.fromPlatform());
  }

  Future<void> checkNewVersion() async {
    if (_checking) return;
    _checking = true;
    loading.value = true;
    error.value = false;
    _clearReleaseState();
    try {
      final updateSucceeded = await (updateChecker?.call() ?? VersionUtil().checkUpdate(forceRefresh: true));
      if (!updateSucceeded) throw StateError('Update feed request failed');
      await getPackageInfo();

      final latestVersion = VersionUtil.effectiveLatestVersion.trim();
      final newVersion = VersionUtil.isNewerVersion(latestVersion, packageInfo.version);
      final assets = ReleaseAssetUrls(
        projectUrl: VersionUtil.projectUrl,
        version: latestVersion,
        buildNumber: VersionUtil.effectiveLatestBuildNumber ?? 0,
      );
      if (!assets.isValid) throw const FormatException('Incomplete release identity');

      hasNewVersion.value = newVersion;
      updateLog.value = VersionUtil.effectiveLatestUpdateLog;
      windowsSetupUrl.value = VersionUtil.effectiveWindowsSetupAvailable ? assets.windowsSetup : '';
      windowsMsixUrl.value = VersionUtil.effectiveWindowsMsixAvailable ? assets.windowsMsix : '';
      windowsPortableUrl.value = assets.windowsPortable;
      macosUrl.value = assets.macosUniversal;
    } catch (_) {
      error.value = true;
      _clearReleaseState();
    } finally {
      loading.value = false;
      _checking = false;
    }
  }

  void _clearReleaseState() {
    hasNewVersion.value = false;
    updateLog.value = '';
    windowsSetupUrl.value = '';
    windowsMsixUrl.value = '';
    windowsPortableUrl.value = '';
    macosUrl.value = '';
  }
}
