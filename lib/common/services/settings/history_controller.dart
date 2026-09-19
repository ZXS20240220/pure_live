import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/utils/backup_migration_util.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/plugins/event_bus.dart';

const int defaultHistoryLimit = 50;
const int unlimitedHistoryLimit = 0;

int normalizeHistoryLimit(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  if (parsed == null || parsed < 0) return defaultHistoryLimit;
  return parsed;
}

List<T> applyHistoryLimit<T>(Iterable<T> values, int limit) {
  final normalized = normalizeHistoryLimit(limit);
  return normalized == unlimitedHistoryLimit
      ? List<T>.of(values, growable: true)
      : values.take(normalized).toList(growable: true);
}

List<LiveRoom> upsertHistoryRoom(
  List<LiveRoom> current,
  LiveRoom room, {
  required int watchedAt,
  int limit = defaultHistoryLimit,
}) {
  final maxLength = normalizeHistoryLimit(limit);
  final next = List<LiveRoom>.from(current)..removeWhere((entry) => entry.hasSameIdentity(room));
  next.insert(0, room.normalizedIdentityCopy().copyWith(lastWatchedAt: watchedAt));
  if (maxLength != unlimitedHistoryLimit && next.length > maxLength) {
    next.removeRange(maxLength, next.length);
  }
  return next;
}

LiveRoom preserveHistoryMetadata(LiveRoom refreshed, LiveRoom previous) {
  return refreshed.withAudienceFallbackFrom(previous).copyWith(lastWatchedAt: previous.lastWatchedAt);
}

List<LiveRoom> removeHistorySnapshotEntries(Iterable<LiveRoom> current, Iterable<LiveRoom> snapshot) {
  final ownedEntries = Set<LiveRoom>.identity()..addAll(snapshot);
  if (ownedEntries.isEmpty) return List<LiveRoom>.of(current, growable: true);
  return current.where((room) => !ownedEntries.contains(room)).toList(growable: true);
}

class HistoryController extends GetxController {
  static HistoryController get to => Get.find();

  static const String historyLimitKey = 'historyLimit';

  final Rx<List<LiveRoom>> historyRooms = hiveObject(
    'historyRooms',
    <LiveRoom>[],
    fromJson: (json) {
      return (json['list'] as List).map((e) => LiveRoom.fromJson(e)).toList();
    },
    toJson: (list) {
      return {'list': list.map((e) => e.toJson()).toList()};
    },
  );

  final historyLimit = hiveInt(historyLimitKey, defaultHistoryLimit);

  @override
  void onInit() {
    super.onInit();
    setHistoryLimit(historyLimit.v);
  }

  void setHistoryLimit(int value) {
    final normalized = normalizeHistoryLimit(value);
    historyLimit.v = normalized;
    if (normalized != unlimitedHistoryLimit && historyRooms.v.length > normalized) {
      historyRooms.v = historyRooms.v.take(normalized).toList(growable: true);
    }
  }

  void addRoomToHistory(LiveRoom room) {
    historyRooms.v = upsertHistoryRoom(
      historyRooms.v,
      room,
      watchedAt: DateTime.now().millisecondsSinceEpoch,
      limit: historyLimit.v,
    );
    EventBus.instance.emit('history_changed', true);
  }

  void removeRoomFromHistory(LiveRoom room) {
    historyRooms.v = List<LiveRoom>.from(historyRooms.v)..removeWhere((entry) => entry.hasSameIdentity(room));
    EventBus.instance.emit('history_changed', true);
  }

  void removeRoomFromHistoryAt(int index) {
    if (index < 0 || index >= historyRooms.v.length) return;
    historyRooms.v = List<LiveRoom>.from(historyRooms.v)..removeAt(index);
    EventBus.instance.emit('history_changed', true);
  }

  void clearHistory() {
    historyRooms.v = <LiveRoom>[];
    EventBus.instance.emit('history_changed', true);
  }

  void clearHistorySnapshot(Iterable<LiveRoom> snapshot) {
    historyRooms.v = removeHistorySnapshotEntries(historyRooms.v, snapshot);
  }

  void applyRefreshedRooms(List<LiveRoom> snapshot, List<LiveRoom?> refreshed) {
    // LiveRoom equality compares room identity, not the particular watch/import.
    // Only replace the exact entries still owned by this refresh snapshot.
    final replacements = Map<LiveRoom, LiveRoom>.identity();
    for (var i = 0; i < snapshot.length && i < refreshed.length; i++) {
      final updated = refreshed[i];
      if (updated != null) replacements[snapshot[i]] = updated;
    }
    historyRooms.v = applyHistoryLimit(historyRooms.v.map((room) => replacements[room] ?? room), historyLimit.v);
  }

  Map<String, dynamic> toJson() {
    return {'historyRooms': historyRooms.v.map((e) => e.toJson()).toList(), historyLimitKey: historyLimit.v};
  }

  void fromJson(Map<String, dynamic> json) {
    final parsed = parseConfig(json);
    historyLimit.v = parsed[historyLimitKey];
    historyRooms.v = parsed['historyRooms'];
  }

  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    final limit = normalizeHistoryLimit(json[historyLimitKey]);
    return {
      historyLimitKey: limit,
      'historyRooms': applyHistoryLimit(
        BackupMigrationUtil.parseObjectList(json['historyRooms'], LiveRoom.fromJson, strict: true),
        limit,
      ),
    };
  }

  static Map<String, dynamic> extractConfig(Map<String, dynamic>? rootConfig) {
    final history = rootConfig?['history'] as Map<String, dynamic>? ?? {};

    final list = BackupMigrationUtil.parseObjectList(history['historyRooms'], LiveRoom.fromJson);

    final limit = normalizeHistoryLimit(history[historyLimitKey]);
    return {'historyRooms': applyHistoryLimit(list, limit).map((e) => e.toJson()).toList(), historyLimitKey: limit};
  }

  static Map<String, dynamic> mergeConfig(Map<String, dynamic> rootConfig, Map<String, dynamic> updateFields) {
    final history = Map<String, dynamic>.from(rootConfig['history'] ?? {});

    updateFields.forEach((k, v) => history[k] = v);
    rootConfig['history'] = history;

    return rootConfig;
  }

  Future<({List<LiveRoom> rooms, bool allSuccess})?> refreshRoomDetails(
    List<LiveRoom> rooms, {
    bool Function()? shouldCancel,
    // 可选的详情拉取注入点（测试用），默认走各平台 LiveSite。
    Future<LiveRoom> Function(LiveRoom room)? fetch,
  }) async {
    var allSuccess = true;
    final valid = <LiveRoom>[];
    for (final room in rooms) {
      if ((room.platform?.isNotEmpty ?? false) && (room.roomId?.isNotEmpty ?? false)) {
        valid.add(room);
      } else {
        allSuccess = false;
      }
    }
    if (valid.isEmpty) {
      return (rooms: List<LiveRoom>.from(rooms), allSuccess: allSuccess);
    }

    final groups = <String, List<LiveRoom>>{};
    for (final room in valid) {
      groups.putIfAbsent(room.normalizedPlatformId, () => []).add(room);
    }

    final refreshConfig = SettingsService.to.refreshConfig;
    final siteCache = <String, LiveSite>{};

    final groupResults = await Future.wait(
      groups.entries.map((entry) {
        return boundedAsyncMap<LiveRoom, LiveRoom>(
          entry.value,
          maxConcurrent: refreshConfig.platformConcurrencyOf(entry.key),
          task: (room) => _refreshOneRoom(room, siteCache, () => allSuccess = false, fetch: fetch),
          shouldCancel: shouldCancel,
        );
      }),
    );

    if (shouldCancel?.call() ?? false) return null;

    final refreshedByIdentity = <String, LiveRoom>{};
    for (final results in groupResults) {
      for (final room in results) {
        if (room != null) refreshedByIdentity[room.identityKey] = room;
      }
    }

    return (rooms: [for (final room in rooms) refreshedByIdentity[room.identityKey] ?? room], allSuccess: allSuccess);
  }

  Future<LiveRoom> _refreshOneRoom(
    LiveRoom room,
    Map<String, LiveSite> siteCache,
    void Function() markFailure, {
    Future<LiveRoom> Function(LiveRoom)? fetch,
  }) async {
    try {
      final platform = room.normalizedPlatformId;
      final roomId = room.normalizedRoomId;
      final liveSite = siteCache.putIfAbsent(platform, () => Sites.of(platform).liveSite);
      final operation =
          fetch?.call(room) ??
          (liveSite is LiveSiteRoomRefresher
              ? (liveSite as LiveSiteRoomRefresher).getRoomDetailForRefresh(roomId: roomId, platform: platform)
              : liveSite.getRoomDetail(roomId: roomId, platform: platform));
      final refreshed = await operation.timeout(const Duration(seconds: 12));
      return preserveHistoryMetadata(refreshed, room);
    } catch (_) {
      markFailure();
      return room;
    }
  }
}
