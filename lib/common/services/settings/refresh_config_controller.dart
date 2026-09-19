import 'package:rxdart/rxdart.dart' hide Rx;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/medels/refresh_config_model.dart';

class RefreshConfigController extends GetxController {
  static const int defaultRefreshInterval = 30;
  static const int minRefreshInterval = 5;
  static const int maxRefreshInterval = 360;
  static const int defaultMaxConcurrentRefresh = 4;
  static const int maxAllowedConcurrentRefresh = 20;
  static const int recommendedPlatformMaxConcurrentRefresh = 3;
  static const int defaultSuccessCooldownSeconds = 15;
  static const int maxSuccessCooldownSeconds = 60;
  static const int defaultFailureRetryMinutes = 5;
  static const int maxFailureRetryMinutes = 60;

  static int normalizeRefreshInterval(int value) {
    return value.clamp(minRefreshInterval, maxRefreshInterval);
  }

  /// 刷新成功保护间隔（秒）：0 表示关闭保护，上限 60 秒。
  static int normalizeSuccessCooldownSeconds(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    return (parsed ?? defaultSuccessCooldownSeconds).clamp(0, maxSuccessCooldownSeconds);
  }

  /// 刷新失败保护间隔（分钟）：0 表示关闭保护，上限 60 分钟。
  static int normalizeFailureRetryMinutes(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    return (parsed ?? defaultFailureRetryMinutes).clamp(0, maxFailureRetryMinutes);
  }

  static int normalizeMaxConcurrentRefresh(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    return (parsed ?? defaultMaxConcurrentRefresh).clamp(1, maxAllowedConcurrentRefresh);
  }

  static Map<String, int> normalizePlatformConcurrencyMap(Object? raw) {
    if (raw is! Map) return const <String, int>{};
    final out = <String, int>{};
    raw.forEach((key, value) {
      final id = key.toString().trim().toLowerCase();
      if (id.isEmpty) return;
      out[id] = normalizeMaxConcurrentRefresh(value);
    });
    return out;
  }

  final RxBool autoRefreshFavorite = hiveBool('autoRefreshFavorite', false);
  // Foregrounding an existing process is the common Android interpretation of
  // "opening" the app. Default to a fresh status pass so cached live flags do
  // not survive indefinitely; users who prefer no foreground traffic can still
  // disable this independently from periodic refresh.
  final refreshFavoriteOnResume = hiveBool('refreshFavoriteOnResume', true);
  final RxInt autoRefreshInterval = hiveInt('autoRefreshInterval', defaultRefreshInterval);
  final RxInt maxConcurrentRefresh = hiveInt('maxConcurrentRefresh', defaultMaxConcurrentRefresh);

  final Rx<Map<String, int>> platformMaxConcurrentRefresh = hiveObject<Map<String, int>>(
    'platformMaxConcurrentRefresh',
    const <String, int>{},
    fromJson: normalizePlatformConcurrencyMap,
    toJson: (value) => Map<String, dynamic>.from(value),
  );
  final RxBool autoRefreshThumbnails = hiveBool('autoRefreshThumbnails', false);
  final RxInt thumbnailRefreshInterval = hiveInt('thumbnailRefreshInterval', defaultRefreshInterval);
  final RxInt successCooldownSeconds = hiveInt('refreshSuccessCooldownSeconds', defaultSuccessCooldownSeconds);
  final RxInt failureRetryMinutes = hiveInt('refreshFailureRetryMinutes', defaultFailureRetryMinutes);

  final _configStream = BehaviorSubject<RefreshConfig>();
  Stream<RefreshConfig> get configChanges => _configStream.stream;
  Worker? _configWorker;

  @override
  void onInit() {
    super.onInit();
    autoRefreshInterval.value = normalizeRefreshInterval(autoRefreshInterval.value);
    maxConcurrentRefresh.value = normalizeMaxConcurrentRefresh(maxConcurrentRefresh.value);
    thumbnailRefreshInterval.value = normalizeRefreshInterval(thumbnailRefreshInterval.value);
    successCooldownSeconds.value = normalizeSuccessCooldownSeconds(successCooldownSeconds.value);
    failureRetryMinutes.value = normalizeFailureRetryMinutes(failureRetryMinutes.value);
    _emitConfig();
    _configWorker = everAll([
      autoRefreshFavorite,
      refreshFavoriteOnResume,
      autoRefreshInterval,
      maxConcurrentRefresh,
      autoRefreshThumbnails,
      thumbnailRefreshInterval,
      successCooldownSeconds,
      failureRetryMinutes,
    ], (_) => _emitConfig());
  }

  void _emitConfig() {
    _configStream.add(
      RefreshConfig(
        autoRefreshFavorite: autoRefreshFavorite.value,
        refreshFavoriteOnResume: refreshFavoriteOnResume.value,
        autoRefreshInterval: autoRefreshInterval.value,
        maxConcurrentRefresh: maxConcurrentRefresh.value,
        autoRefreshThumbnails: autoRefreshThumbnails.value,
        thumbnailRefreshInterval: thumbnailRefreshInterval.value,
        successCooldownSeconds: successCooldownSeconds.value,
        failureRetryMinutes: failureRetryMinutes.value,
      ),
    );
  }

  int platformConcurrencyOf(String platformId) {
    final id = platformId.trim().toLowerCase();
    return normalizeMaxConcurrentRefresh(platformMaxConcurrentRefresh.v[id] ?? maxConcurrentRefresh.value);
  }

  bool hasPlatformConcurrencyOverride(String platformId) {
    return platformMaxConcurrentRefresh.v.containsKey(platformId.trim().toLowerCase());
  }

  void setPlatformConcurrency(String platformId, int value) {
    final id = platformId.trim().toLowerCase();
    if (id.isEmpty) return;
    final next = Map<String, int>.from(platformMaxConcurrentRefresh.v);
    next[id] = normalizeMaxConcurrentRefresh(value);
    platformMaxConcurrentRefresh.v = next;
  }

  Map<String, dynamic> toJson() {
    return {
      'autoRefreshFavorite': autoRefreshFavorite.v,
      'refreshFavoriteOnResume': refreshFavoriteOnResume.v,
      'autoRefreshInterval': autoRefreshInterval.v,
      'maxConcurrentRefresh': maxConcurrentRefresh.v,
      'platformMaxConcurrentRefresh': platformMaxConcurrentRefresh.v,
      'autoRefreshThumbnails': autoRefreshThumbnails.v,
      'thumbnailRefreshInterval': thumbnailRefreshInterval.v,
      'refreshSuccessCooldownSeconds': successCooldownSeconds.v,
      'refreshFailureRetryMinutes': failureRetryMinutes.v,
    };
  }

  /// Parse the complete section without notifying observers or persisting values.
  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    return {
      'autoRefreshFavorite': (json['autoRefreshFavorite'] ?? false) as bool,
      'refreshFavoriteOnResume': (json['refreshFavoriteOnResume'] ?? true) as bool,
      'autoRefreshInterval': normalizeRefreshInterval((json['autoRefreshInterval'] ?? defaultRefreshInterval) as int),
      'maxConcurrentRefresh': normalizeMaxConcurrentRefresh(json['maxConcurrentRefresh']),
      'platformMaxConcurrentRefresh': normalizePlatformConcurrencyMap(json['platformMaxConcurrentRefresh']),
      'autoRefreshThumbnails': (json['autoRefreshThumbnails'] ?? false) as bool,
      'thumbnailRefreshInterval': normalizeRefreshInterval(
        (json['thumbnailRefreshInterval'] ?? defaultRefreshInterval) as int,
      ),
      'refreshSuccessCooldownSeconds': normalizeSuccessCooldownSeconds(json['refreshSuccessCooldownSeconds']),
      'refreshFailureRetryMinutes': normalizeFailureRetryMinutes(json['refreshFailureRetryMinutes']),
    };
  }

  void fromJson(Map<String, dynamic> json) {
    final parsed = parseConfig(json);
    autoRefreshFavorite.v = parsed['autoRefreshFavorite'];
    refreshFavoriteOnResume.v = parsed['refreshFavoriteOnResume'];
    autoRefreshInterval.v = parsed['autoRefreshInterval'];
    maxConcurrentRefresh.v = parsed['maxConcurrentRefresh'];
    platformMaxConcurrentRefresh.v = parsed['platformMaxConcurrentRefresh'];
    autoRefreshThumbnails.v = parsed['autoRefreshThumbnails'];
    thumbnailRefreshInterval.v = parsed['thumbnailRefreshInterval'];
    successCooldownSeconds.v = parsed['refreshSuccessCooldownSeconds'];
    failureRetryMinutes.v = parsed['refreshFailureRetryMinutes'];
  }

  @override
  void onClose() {
    _configWorker?.dispose();
    _configStream.close();
    super.onClose();
  }

  static Map<String, dynamic> extractConfig(Map<String, dynamic>? rootConfig) {
    final refresh = rootConfig?['refresh'] as Map<String, dynamic>? ?? {};
    return {
      'autoRefreshFavorite': refresh['autoRefreshFavorite'] ?? false,
      'refreshFavoriteOnResume': refresh['refreshFavoriteOnResume'] ?? true,
      'autoRefreshInterval': normalizeRefreshInterval(
        (refresh['autoRefreshInterval'] ?? defaultRefreshInterval) as int,
      ),
      'maxConcurrentRefresh': normalizeMaxConcurrentRefresh(refresh['maxConcurrentRefresh']),
      'platformMaxConcurrentRefresh': normalizePlatformConcurrencyMap(refresh['platformMaxConcurrentRefresh']),
      'autoRefreshThumbnails': refresh['autoRefreshThumbnails'] ?? false,
      'thumbnailRefreshInterval': normalizeRefreshInterval(
        (refresh['thumbnailRefreshInterval'] ?? defaultRefreshInterval) as int,
      ),
      'refreshSuccessCooldownSeconds': normalizeSuccessCooldownSeconds(refresh['refreshSuccessCooldownSeconds']),
      'refreshFailureRetryMinutes': normalizeFailureRetryMinutes(refresh['refreshFailureRetryMinutes']),
    };
  }

  static Map<String, dynamic> mergeConfig(Map<String, dynamic> rootConfig, Map<String, dynamic> updateFields) {
    final refresh = Map<String, dynamic>.from(rootConfig['refresh'] ?? {});
    updateFields.forEach((k, v) => refresh[k] = v);
    rootConfig['refresh'] = refresh;
    return rootConfig;
  }
}
