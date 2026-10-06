import 'dart:async';

import 'package:pure_live/gen/env.g.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/race_http.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pure_live/common/utils/githup_mirror.dart';
import 'package:pure_live/common/global/platform_utils.dart';

class VersionUtil {
  static PackageInfo? _packageInfo;

  /// Release/update repository for this maintained distribution.
  ///
  /// Keeping the owner configurable lets downstream builders select their own
  /// release feed without editing runtime code. The owner is supplied by the
  /// generated AppConfig (.env / .env.prod).
  static final String updateOwner = AppConfig.pureliveUpdateOwner;
  static final String updateRepository = AppConfig.pureliveUpdateRepository;
  static final String projectUrl = 'https://github.com/$updateOwner/$updateRepository';
  static final String issuesUrl = '$projectUrl/issues';
  static final String githubUrl = 'https://github.com/$updateOwner';

  static const String email = '17792321552@163.com';
  static const String emailUrl = 'mailto:17792321552@163.com?subject=PureLive Feedback';

  static const String telegramGroup = 't.me/pure_live_channel';
  static const String telegramGroupUrl = 'https://t.me/pure_live_channel';

  static final String releaseUrl = 'https://api.github.com/repos/$updateOwner/$updateRepository/releases?per_page=30';

  // 独立分支：version.json 跟随 dev_from_v3.1.4 分支发布。
  static final GitHubMirror mirror = GitHubMirror(
    owner: updateOwner,
    repo: updateRepository,
    branch: 'dev_from_v3.1.4',
  );

  static List<String> get _versionUrls => SettingsService.to.app.useGitHubOriginForUpdates.v
      ? [mirror.rawUrl('assets/version.json')]
      : mirror.mirrors('assets/version.json');

  final isHasNewVersion = false.obs;

  static String latestVersion = '';
  static int? latestBuildNumber;
  static int latestVersionNum = 0;
  static String latestUpdateLog = '';
  static bool prerelease = false;
  static String downloadUrl = '';
  static bool latestWindowsMsixAvailable = false;
  static bool latestWindowsSetupAvailable = false;

  // 最新稳定版信息（stableOnly 模式下使用），由 version.json 的 latest_stable 字段提供。
  static String latestStableVersion = '';
  static int? latestStableBuildNumber;
  static int latestStableVersionNum = 0;
  static String latestStableUpdateLog = '';
  static bool latestStablePrerelease = false;
  static String latestStableDownloadUrl = '';
  static bool latestStableWindowsMsixAvailable = false;
  static bool latestStableWindowsSetupAvailable = false;

  static bool get _isStableOnlyMode {
    try {
      return SettingsService.to.app.autoCheckUpdateMode == AutoCheckUpdateMode.stableOnly;
    } catch (_) {
      return false;
    }
  }

  static String get effectiveLatestVersion => _isStableOnlyMode ? latestStableVersion : latestVersion;
  static int? get effectiveLatestBuildNumber => _isStableOnlyMode ? latestStableBuildNumber : latestBuildNumber;
  static int get effectiveLatestVersionNum => _isStableOnlyMode ? latestStableVersionNum : latestVersionNum;
  static String get effectiveLatestUpdateLog => _isStableOnlyMode ? latestStableUpdateLog : latestUpdateLog;
  static bool get effectivePrerelease => _isStableOnlyMode ? latestStablePrerelease : prerelease;
  static String get effectiveDownloadUrl => _isStableOnlyMode ? latestStableDownloadUrl : downloadUrl;
  static bool get effectiveWindowsMsixAvailable =>
      _isStableOnlyMode ? latestStableWindowsMsixAvailable : latestWindowsMsixAvailable;
  static bool get effectiveWindowsSetupAvailable =>
      _isStableOnlyMode ? latestStableWindowsSetupAvailable : latestWindowsSetupAvailable;
  var allReleased = [].obs;

  static Map<String, dynamic>? _cachedVersionJson;

  static final RxBool historyLoading = false.obs;
  static final RxBool historyError = false.obs;

  static Future<void> initPackageInfo() async {
    _packageInfo = await PackageInfo.fromPlatform();
  }

  static String get version {
    if (_packageInfo == null) return '0.0.0';
    return _packageInfo!.version;
  }

  static int get buildNumber {
    if (_packageInfo == null) return 0;
    return int.tryParse(_packageInfo!.buildNumber) ?? 0;
  }

  /// 完整版本标识，例如 3.1.4+4200；无 build 号时回退为 3.1.4。
  static String get fullVersion => buildNumber > 0 ? '$version+$buildNumber' : version;

  Future<bool> checkUpdate() async {
    if (_cachedVersionJson != null) {
      try {
        _applyVersionData(_cachedVersionJson!);
        isHasNewVersion.value = hasNewVersion();
        return true;
      } catch (_) {
        _cachedVersionJson = null;
        _resetAfterFailedCheck();
        return false;
      }
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final urls = _versionUrls.map((e) => '$e?ts=$timestamp').toList();

      final data = await RaceHttp.fetchJson(
        urls,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (data == null) {
        _resetAfterFailedCheck();
        return false;
      }

      _applyVersionData(data);
      _cachedVersionJson = data;
      isHasNewVersion.value = hasNewVersion();
      debugPrint("🏁 更新线路成功");
      return true;
    } catch (e) {
      debugPrint("⚠️ 更新检查失败: $e");
      _resetAfterFailedCheck();
      return false;
    }
  }

  static void _applyVersionData(Map<String, dynamic> data) {
    final selected = selectPlatformVersionData(data, platform: _currentPlatformKey);
    final parsedVersion = selected['version']?.toString().trim() ?? '';
    final parsedBuildNumber = _versionInt(selected['build_number']);
    if (parsedVersion.isEmpty || parsedBuildNumber == null || parsedBuildNumber <= 0) {
      throw const FormatException('Incomplete release identity');
    }
    latestVersion = parsedVersion;
    latestVersionNum = _versionInt(selected['version_num']) ?? 0;
    latestBuildNumber = parsedBuildNumber;
    latestUpdateLog = selected['version_desc']?.toString() ?? '';
    prerelease = selected['prerelease'] == true;
    // 预发布版本正常提示更新，但在更新日志前注明其预发布身份。
    if (prerelease && latestUpdateLog.isNotEmpty) {
      latestUpdateLog = '> **预发布版本**：此为 Pre-release 测试版，包含未充分验证的改动，请谨慎升级。\n\n$latestUpdateLog';
    }
    downloadUrl = selected['download_url']?.toString() ?? '';
    latestWindowsMsixAvailable = selected['windows_msix_available'] == true;
    latestWindowsSetupAvailable = selected['windows_setup_available'] == true;

    // 解析 latest_stable（若存在），供 stableOnly 模式使用。
    final latestStable = data['latest_stable'];
    if (latestStable is Map) {
      final stableSelected = selectPlatformVersionData(
        Map<String, dynamic>.from(latestStable),
        platform: _currentPlatformKey,
      );
      final stableVersion = stableSelected['version']?.toString().trim() ?? '';
      final stableBuildNumber = _versionInt(stableSelected['build_number']);
      if (stableVersion.isNotEmpty && stableBuildNumber != null && stableBuildNumber > 0) {
        latestStableVersion = stableVersion;
        latestStableVersionNum = _versionInt(stableSelected['version_num']) ?? 0;
        latestStableBuildNumber = stableBuildNumber;
        latestStableUpdateLog = stableSelected['version_desc']?.toString() ?? '';
        latestStablePrerelease = stableSelected['prerelease'] == true;
        latestStableDownloadUrl = stableSelected['download_url']?.toString() ?? '';
        latestStableWindowsMsixAvailable = stableSelected['windows_msix_available'] == true;
        latestStableWindowsSetupAvailable = stableSelected['windows_setup_available'] == true;
      } else {
        _resetStableFields();
      }
    } else {
      _resetStableFields();
    }
  }

  static void _resetStableFields() {
    latestStableVersion = '';
    latestStableBuildNumber = null;
    latestStableVersionNum = 0;
    latestStableUpdateLog = '';
    latestStablePrerelease = false;
    latestStableDownloadUrl = '';
    latestStableWindowsMsixAvailable = false;
    latestStableWindowsSetupAvailable = false;
  }

  /// Keeps update announcements aligned with the artifacts that were really
  /// published for each platform. The top-level object remains the fallback
  /// for older feeds and older clients.
  static Map<String, dynamic> selectPlatformVersionData(Map<String, dynamic> data, {required String platform}) {
    final platforms = data['platforms'];
    final platformData = platforms is Map ? platforms[platform] : null;
    if (platformData is! Map) return data;
    return {...data, ...Map<String, dynamic>.from(platformData)};
  }

  static String get _currentPlatformKey {
    if (PlatformUtils.isWindows) return 'windows';
    if (PlatformUtils.isAndroid) return 'android';
    if (PlatformUtils.isMacOS) return 'macos';
    if (PlatformUtils.isIOS) return 'ios';
    if (PlatformUtils.isLinux) return 'linux';
    return 'default';
  }

  /// 根据当前自动检查更新模式判断是否有新版本。
  /// - all 模式：对比最新版本（可能为预发布版）
  /// - stableOnly 模式：对比最新稳定版
  static bool hasNewVersion() {
    if (_isStableOnlyMode) return hasNewStableVersion();
    return _hasNewVersionAgainst(latestVersion, latestBuildNumber);
  }

  /// 判断是否有比当前版本更新的稳定版。
  static bool hasNewStableVersion() {
    if (latestStableVersion.isEmpty) return false;
    return _hasNewVersionAgainst(latestStableVersion, latestStableBuildNumber);
  }

  static bool _hasNewVersionAgainst(String targetVersion, int? targetBuildNumber) {
    if (isNewerVersion(targetVersion, version)) return true;
    // 语义版本相同（独立分支在同一语义版本上按 build 号迭代，如
    // 3.1.4+4103 → 3.1.4+4200）时，回退比较构建号。
    final targetBuild = targetBuildNumber;
    if (targetBuild != null && buildNumber > 0 && _normalizeVersion(targetVersion) == _normalizeVersion(version)) {
      return targetBuild > buildNumber;
    }
    return false;
  }

  static String _normalizeVersion(String value) =>
      value.split(RegExp(r'[-+]')).first.replaceFirst(RegExp('^[vV]'), '').trim();

  static bool isNewerVersion(String latest, String current) {
    try {
      final latestClean = latest.split(RegExp(r'[-+]'))[0].replaceFirst(RegExp('^[vV]'), '').trim();
      final currentClean = current.split(RegExp(r'[-+]'))[0].replaceFirst(RegExp('^[vV]'), '').trim();

      final latestParts = latestClean.split('.').map(int.parse).toList();
      final currentParts = currentClean.split('.').map(int.parse).toList();

      final maxLength = latestParts.length > currentParts.length ? latestParts.length : currentParts.length;

      while (latestParts.length < maxLength) {
        latestParts.add(0);
      }
      while (currentParts.length < maxLength) {
        currentParts.add(0);
      }

      for (int i = 0; i < maxLength; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
    } catch (_) {}
    return false;
  }

  static int? _versionInt(Object? value) {
    return switch (value) {
      int number => number,
      num number => number.toInt(),
      String text => int.tryParse(text.trim()),
      _ => null,
    };
  }

  void _resetAfterFailedCheck() {
    latestVersion = version;
    latestBuildNumber = buildNumber > 0 ? buildNumber : null;
    latestVersionNum = 0;
    latestUpdateLog = '';
    prerelease = false;
    downloadUrl = '';
    latestWindowsMsixAvailable = false;
    latestWindowsSetupAvailable = false;
    _resetStableFields();
    isHasNewVersion.value = false;
  }
}
