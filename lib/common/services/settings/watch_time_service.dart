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

class WatchTimeService extends GetxService with WidgetsBindingObserver {
  static WatchTimeService get to => Get.find<WatchTimeService>();

  static const String _storageKey = 'room_watch_durations';
  static const String eventWatchTimeChanged = 'watch_time_changed';

  static const int _flushThresholdSeconds = 30;

  static const Duration _sortRefreshDebounce = Duration(seconds: 3);

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
    if (!counting) unawaited(_flush());
  }

  bool get isCountingNow => _playing && !_loading && !_hasError;

  void _tick() {
    if (!isCountingNow) return;

    if (!Get.isRegistered<RouteObserverController>()) return;
    if (RouteObserverController.to.currentRoute.value != RoutePath.kLivePlay) return;

    final player = GlobalPlayerService.instance.player;

    if (player.currentPlayer == null || !player.isPlayingNow) {
      if (_unflushedSeconds > 0) unawaited(_flush());
      return;
    }

    if (player.isCompactModeActive) {
      if (_unflushedSeconds > 0) unawaited(_flush());
      return;
    }

    final LiveRoom? room = player.currentFloatRoom;
    if (room == null || !room.isLiveNow) return;

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

  void _notifyWatchTimeChanged() {
    _sortDebounce?.cancel();
    _sortDebounce = Timer(_sortRefreshDebounce, () {
      EventBus.instance.emit(eventWatchTimeChanged, true);
    });
  }

  int secondsOf(String identityKey) => durations[identityKey] ?? 0;

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

  static String formatCompact(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    if (totalSeconds < 3600) return '${totalSeconds ~/ 60}m';
    final hours = totalSeconds / 3600;
    return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)}h';
  }

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

  Future<void> flushNow() => _flush();

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

  static void removeFor(String identityKey) {
    if (identityKey.isEmpty) return;
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._removeFor(identityKey);
  }

  static void clearAllRecords() {
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._clearAll();
    EventBus.instance.emit(eventWatchTimeChanged, true);
  }

  static int secondsFor(String identityKey) {
    if (identityKey.isEmpty) return 0;
    if (!Get.isRegistered<WatchTimeService>()) return 0;
    return to.durations[identityKey] ?? 0;
  }

  static Map<String, int> exportDurations() {
    if (!Get.isRegistered<WatchTimeService>()) return const <String, int>{};
    return Map<String, int>.from(to.durations);
  }

  static void importDurations(dynamic raw) {
    final parsed = _parseDurations(raw);
    if (parsed.isEmpty) return;
    if (!Get.isRegistered<WatchTimeService>()) return;
    to._importMap(parsed);
    to._pruneToFollowed();
    EventBus.instance.emit(eventWatchTimeChanged, true);
  }

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
