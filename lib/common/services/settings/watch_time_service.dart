import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/models/live_room.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/player/global_player_service.dart';
import 'package:pure_live/player/models/player_exception.dart';
import 'package:pure_live/routes/route_observer_controller.dart';
import 'package:pure_live/routes/route_path.dart';

/// 关注直播间累计观看时长服务。
///
/// 计时规则：
/// - 只统计已关注、且处于开播状态（非录播/离线）的直播间；
/// - 直播流处于 playing 且未在缓冲、无播放错误时累计；
/// - 用户主动暂停、连接失败、断网缓冲时停止计时，恢复后继续；
/// - 时长按房间维度累计持久化，退出程序不清空；取消关注即清零。
class WatchTimeService extends GetxService with WidgetsBindingObserver {
  static WatchTimeService get to => Get.find<WatchTimeService>();

  static const String _storageKey = 'room_watch_durations';
  static const String eventWatchTimeChanged = 'watch_time_changed';

  /// 连续计时达到该秒数后写盘一次，避免每秒触发 Hive 写入。
  static const int _flushThresholdSeconds = 30;

  /// 观看时长变化后通知关注列表重排的防抖间隔。
  static const Duration _sortRefreshDebounce = Duration(seconds: 3);

  /// identityKey -> 累计秒数
  final RxMap<String, int> durations = <String, int>{}.obs;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _loadingSub;
  StreamSubscription<PlayerException>? _errorSub;
  Timer? _tickTimer;
  Timer? _bindTimer;
  Timer? _sortDebounce;

  bool _playing = false;
  bool _loading = false;
  bool _hasError = false;
  int _unflushedSeconds = 0;
  bool _flushing = false;
  bool _lastCountingState = false;

  @override
  void onInit() {
    super.onInit();
    _loadFromDisk();
    WidgetsBinding.instance.addObserver(this);
    _bindTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (GlobalPlayerService.instance.initialized) {
        _bindTimer?.cancel();
        _bindTimer = null;
        _bindPlayer();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 播放器状态绑定
  // ---------------------------------------------------------------------------

  void _bindPlayer() {
    final player = GlobalPlayerService.instance.player;
    _playingSub = player.onPlaying.listen((playing) {
      _playing = playing;
      if (playing) _hasError = false;
      _onCountingStateMaybeChanged();
    });
    _loadingSub = player.onLoading.listen((loading) {
      _loading = loading;
      _onCountingStateMaybeChanged();
    });
    _errorSub = player.onError.listen((error) {
      _hasError = true;
      _onCountingStateMaybeChanged();
    });
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _onCountingStateMaybeChanged() {
    final counting = isCountingNow;
    if (counting == _lastCountingState) return;
    _lastCountingState = counting;
    // 从计时切换到停止：把未落库的秒数立刻持久化。
    if (!counting) unawaited(_flush());
  }

  /// 当前是否满足计时条件（正在播放真实直播流）。
  bool get isCountingNow => _playing && !_loading && !_hasError;

  // ---------------------------------------------------------------------------
  // 计时核心
  // ---------------------------------------------------------------------------

  void _tick() {
    if (!isCountingNow) return;

    // 路由级权威校验：只有当前正停留在直播间页面才计时（"在直播间中"）。
    // 播放器状态在退出路径上可能延迟复位（浮窗续播/异步 close），而路由在
    // didPop 时已切换，是退出行为的最终信号，任何退出方式都不会漏判。
    if (!Get.isRegistered<RouteObserverController>()) return;
    if (RouteObserverController.to.currentRoute.value != RoutePath.kLivePlay) return;

    final player = GlobalPlayerService.instance.player;

    // 实时快照二次校验（不依赖事件时序）：播放器实例已销毁（退出直播间的
    // 硬停止路径）或聚合 playing 已复位时不计时，防止事件丢失导致假"播放中"。
    if (player.currentPlayer == null || !player.isPlayingNow) {
      if (_unflushedSeconds > 0) unawaited(_flush());
      return;
    }

    // 退出直播间后应用内浮窗/PiP 仍在播放（playing 保持 true），但用户已
    // 不在直播间内：停表并把未落盘的秒数立刻持久化。
    if (player.isCompactModeActive) {
      if (_unflushedSeconds > 0) unawaited(_flush());
      return;
    }

    final LiveRoom? room = player.currentFloatRoom;
    if (room == null || !room.isLiveNow) return;

    // 只统计关注的直播间（保证中途取关立即停表）。
    if (!SettingsService.to.fav.isFavorite(room)) return;

    final key = room.identityKey;
    if (key.isEmpty) return;

    durations[key] = (durations[key] ?? 0) + 1;
    _unflushedSeconds++;
    if (_unflushedSeconds >= _flushThresholdSeconds) {
      unawaited(_flush());
    }
    _notifyWatchTimeChanged();
  }

  /// 观看时长变化后防抖通知关注列表（仅用于按观看时长排序时重排）。
  void _notifyWatchTimeChanged() {
    _sortDebounce?.cancel();
    _sortDebounce = Timer(_sortRefreshDebounce, () {
      EventBus.instance.emit(eventWatchTimeChanged, true);
    });
  }

  // ---------------------------------------------------------------------------
  // 查询与格式化
  // ---------------------------------------------------------------------------

  int secondsOf(String identityKey) => durations[identityKey] ?? 0;

  /// HH:MM:SS（超过小时补齐两位），用于播放页 Header 与 Tooltip。
  static String formatFull(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    return '$mm:$ss';
  }

  /// 紧凑格式（卡片封面徽标）：59s / 25m / 3.2h。
  static String formatCompact(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    if (totalSeconds < 3600) return '${totalSeconds ~/ 60}m';
    final hours = totalSeconds / 3600;
    return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)}h';
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  void _loadFromDisk() {
    final raw = HivePrefUtil.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecodeMap(raw);
      decoded.removeWhere((key, value) => key.isEmpty || value <= 0);
      durations.assignAll(decoded);
    } catch (_) {}
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    _unflushedSeconds = 0;
    try {
      await HivePrefUtil.setString(_storageKey, jsonEncodeMap(durations));
    } catch (_) {
    } finally {
      _flushing = false;
    }
  }

  /// 立即把内存中的累计秒数写入磁盘（退出/生命周期切后台时调用）。
  Future<void> flushNow() => _flush();

  // ---------------------------------------------------------------------------
  // 数据维护（取关清零 / 清空 / 备份导入）
  // ---------------------------------------------------------------------------

  void _removeFor(String identityKey) {
    if (!durations.containsKey(identityKey)) return;
    final next = Map<String, int>.from(durations);
    next.remove(identityKey);
    durations.assignAll(next);
    unawaited(_flush());
  }

  void _clearAll() {
    if (durations.isEmpty) {
      unawaited(_flush());
      return;
    }
    durations.clear();
    unawaited(_flush());
  }

  void _importMap(Map<String, int> incoming) {
    final next = Map<String, int>.from(durations);
    next.addAll(incoming);
    durations.assignAll(next);
    unawaited(_flush());
  }

  void _replaceAll(Map<String, int> incoming) {
    durations.assignAll(incoming);
    unawaited(_flush());
  }

  /// 只保留仍在关注列表中的记录（备份导入后调用）。
  void _pruneToFollowed() {
    final followed = SettingsService.to.fav.favoriteRooms.value.map((e) => e.identityKey).toSet();
    final stale = durations.keys.where((key) => !followed.contains(key)).toList();
    if (stale.isEmpty) return;
    final next = Map<String, int>.from(durations);
    for (final key in stale) {
      next.remove(key);
    }
    durations.assignAll(next);
    unawaited(_flush());
  }

  // ---------------------------------------------------------------------------
  // 供外部（不依赖服务注册时序）调用的静态入口
  // ---------------------------------------------------------------------------

  /// 取消关注后清空该直播间累计时长。
  static void removeFor(String identityKey) {
    if (identityKey.isEmpty) return;
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._removeFor(identityKey);
  }

  /// 清空所有观看记录。
  static void clearAllRecords() {
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._clearAll();
    EventBus.instance.emit(eventWatchTimeChanged, true);
  }

  /// 查询某直播间累计观看秒数（服务未注册时返回 0），供排序比较使用。
  static int secondsFor(String identityKey) {
    if (identityKey.isEmpty) return 0;
    if (!Get.isRegistered<WatchTimeService>()) return 0;
    return to.durations[identityKey] ?? 0;
  }

  /// 备份导出：累计时长快照。
  static Map<String, int> exportDurations() {
    if (!Get.isRegistered<WatchTimeService>()) return const <String, int>{};
    return Map<String, int>.from(to.durations);
  }

  /// 备份导入：合并旧备份中没有的记录；旧版本备份（无该字段）不触碰现有数据。
  static void importDurations(dynamic raw) {
    final parsed = _parseDurations(raw);
    if (parsed.isEmpty) return;
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._importMap(parsed);
    to._pruneToFollowed();
    EventBus.instance.emit(eventWatchTimeChanged, true);
  }

  /// 备份导入（整体替换语义，用于全新安装首次导入）。
  static void replaceDurations(dynamic raw) {
    final parsed = _parseDurations(raw);
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._replaceAll(parsed);
    to._pruneToFollowed();
    EventBus.instance.emit(eventWatchTimeChanged, true);
  }

  static Map<String, int> _parseDurations(dynamic raw) {
    final result = <String, int>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        final seconds = value is int ? value : int.tryParse(value?.toString() ?? '');
        final identity = key?.toString() ?? '';
        if (seconds == null || seconds <= 0 || identity.isEmpty) return;
        result[identity] = seconds;
      });
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecodeMap(raw);
        decoded.forEach((key, value) {
          if (value > 0 && key.isNotEmpty) result[key] = value;
        });
      } catch (_) {}
    }
    return result;
  }

  static Map<String, int> jsonDecodeMap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, int>{};
    return decoded.map((key, value) {
      final seconds = value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
      return MapEntry(key?.toString() ?? '', seconds);
    });
  }

  static String jsonEncodeMap(Map<String, int> data) {
    return jsonEncode(data);
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_flush());
    }
  }

  @override
  void onClose() {
    unawaited(_flush());
    WidgetsBinding.instance.removeObserver(this);
    _bindTimer?.cancel();
    _tickTimer?.cancel();
    _sortDebounce?.cancel();
    _playingSub?.cancel();
    _loadingSub?.cancel();
    _errorSub?.cancel();
    super.onClose();
  }
}
