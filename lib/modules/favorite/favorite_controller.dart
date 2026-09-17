import 'dart:async';
import 'dart:developer' as developer;

import 'package:pure_live/common/index.dart';
import 'package:synchronized/synchronized.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/modules/tags/live_tag.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';
import 'package:pure_live/modules/favorite/favorite_startup_policy.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:pure_live/routes/route_observer_controller.dart';
import 'package:pure_live/common/consts/app_consts.dart';

enum OnlineSortMode { audience, startTime, watchTime }

/// 刷新遮罩展示的范围语义：全量（所有关注）或按当前筛选（平台/标签/搜索）。
enum FavoriteRefreshScope { all, filtered }

class FavoriteController extends LocalReactivePageController<LiveRoom>
    with GetTickerProviderStateMixin, WidgetsBindingObserver {
  final TagManagementController tagController = Get.find<TagManagementController>();
  final RefreshConfigController refreshConfigController = Get.find<RefreshConfigController>();

  late TabController tabController;

  final tabBottomIndex = 0.obs;
  final tabSiteIndex = 0.obs;
  final tabOnlineIndex = 1.obs;
  String selectedPlatformId = Sites.allSite;
  StreamSubscription<dynamic>? subscription;
  StreamSubscription<dynamic>? roomChangedSubscription;
  StreamSubscription<dynamic>? _watchTimeSubscription;

  StreamSubscription<dynamic>? _configSubscription;
  Timer? _autoRefreshTimer;
  Timer? _debounceTimer;
  Timer? _resumeRefreshTimer;
  final List<Worker> _workers = [];
  bool _selectionTransaction = false;
  int? _lastSyncedFavoriteSnapshot;
  int _refreshEpoch = 0;
  final Lock _refreshLock = Lock();
  DateTime? _lastFullRefreshAt;
  final isVerifyingFavorites = false.obs;
  Future<void>? _startupRefresh;
  FavoriteVerificationPreview? _verificationPreview;
  final Map<String, DateTime> _refreshFailureCooldown = {};
  final Map<String, DateTime> _refreshSuccessCooldown = {};
  // UNDONE: Maybe useful for future use.
  // === Pseudo live duration (disabled) ===
  // 用途：当平台接口不返回真实开播时间（如抖音）时，用"在线状态变化 + 当前时间"
  //       近似估算一个伪开播时间，供直播时长排序和 Header 显示使用。
  // 原因：无法可靠区分"真实的 offline→online"和"API 抖动/网络闪断造成的假状态切换"。
  //       后者会把伪时间写成接口恢复的时刻，误差可能差好几个小时；
  //       而 App 重启后持续在线的房间又永远拿不到伪时长（基线已包含它，不会被标记为 newlyOnline）。
  //       所以这套方案精度不可控，暂时整体停用。日后需要时取消下面的注释即可重新启用。
  // final Map<String, int> _fakeStartTime = {};
  // int? getFakeStartTime(String identityKey) => _fakeStartTime[identityKey];
  // final Set<String> _lastOnlineKeys = {};
  // bool _onlineBaselineCaptured = false;
  static const Duration _refreshFailureRetryAfter = Duration(minutes: 5);
  static const Duration _refreshSuccessInterval = Duration(seconds: 30);
  // Treat returning to the app as a fresh launch after a short debounce.  A
  // two-minute window left just-ended rooms visibly "live" when users reopened
  // the app from Recents; 15 seconds still suppresses duplicate lifecycle
  // events from rotation/PiP while keeping room state current.
  static const Duration _resumeRefreshStaleAfter = Duration(seconds: 15);
  static const Duration _roomRefreshTimeout = Duration(seconds: 10);

  final onlineRooms = <LiveRoom>[].obs;
  final offlineRooms = <LiveRoom>[].obs;
  final replayRooms = <LiveRoom>[].obs;
  final multiSelectMode = false.obs;
  final selectedTagIds = <String>{TagManagementController.allTagKey}.obs;
  final visibleTags = <LiveTag>[].obs;
  final visibleUntaggedCount = 0.obs;
  final searchKeyword = ''.obs;
  final enablePinned = true.obs;
  final onlineSortMode = OnlineSortMode.audience.obs;

  /// 排序方向：false = 降序（热度高/开播新/时长多在前），true = 升序。
  final onlineSortAscending = false.obs;

  static const String _pinnedPrefKey = 'fav_enable_pinned';
  static const String _sortModePrefKey = 'fav_online_sort_mode';
  static const String _sortAscendingPrefKey = 'fav_online_sort_ascending';

  final showRefreshShield = false.obs;
  final cancelRequested = false.obs;

  /// 当前遮罩对应的刷新范围，用于遮罩文案区分"全部关注"与"按当前筛选"。
  final refreshShieldScope = FavoriteRefreshScope.all.obs;

  FavoriteController() : super();

  @override
  void onInit() {
    super.onInit();

    final pinnedFromDisk = HivePrefUtil.getBool(_pinnedPrefKey);
    if (pinnedFromDisk != null) enablePinned.value = pinnedFromDisk;

    final sortFromDisk = HivePrefUtil.getString(_sortModePrefKey);
    if (sortFromDisk != null) {
      onlineSortMode.value = OnlineSortMode.values.firstWhere(
        (e) => e.name == sortFromDisk,
        orElse: () => OnlineSortMode.audience,
      );
    }

    final ascendingFromDisk = HivePrefUtil.getBool(_sortAscendingPrefKey);
    if (ascendingFromDisk != null) onlineSortAscending.value = ascendingFromDisk;

    tabController = TabController(
      length: 4,
      initialIndex: 1,
      vsync: this,
      animationDuration: pureLiveTabTransitionDuration,
    );
    WidgetsBinding.instance.addObserver(this);
    tagController.migrateLegacyRoomTagKeys(SettingsService.to.fav.favoriteRooms.v);

    _workers.add(
      debounce(SettingsService.to.fav.favoriteRooms, (_) {
        if (!isVerifyingFavorites.value && !_isCurrentFavoriteSnapshotSynced()) {
          applyLocalFilter();
        }
      }, time: const Duration(milliseconds: 1000)),
    );

    _workers.add(
      ever(selectedTagIds, (_) {
        if (!_selectionTransaction) applyLocalFilter();
      }),
    );
    _workers.add(
      ever(multiSelectMode, (enabled) {
        if (!enabled) {
          selectedTagIds.assignAll({TagManagementController.allTagKey});
        }
      }),
    );
    _workers.add(
      ever(tabSiteIndex, (_) {
        if (!_selectionTransaction) applyLocalFilter(resyncSource: false);
      }),
    );
    _workers.add(
      ever(tabOnlineIndex, (_) {
        if (!_selectionTransaction) applyLocalFilter(resyncSource: false);
      }),
    );
    _workers.add(ever(tagController.tags, (_) => applyLocalFilter()));
    _workers.add(ever(tagController.roomTagsMap, (_) => applyLocalFilter()));
    _workers.add(ever(SettingsService.to.app.preferRealOnlineCounts, (_) => applyLocalFilter()));
    _workers.add(ever(SettingsService.to.app.realOnlinePlatforms, (_) => applyLocalFilter()));
    _workers.add(
      ever(enablePinned, (value) {
        HivePrefUtil.setBool(_pinnedPrefKey, value);
        applyLocalFilter();
      }),
    );
    _workers.add(
      ever(onlineSortMode, (value) {
        HivePrefUtil.setString(_sortModePrefKey, value.name);
        applyLocalFilter();
      }),
    );
    _workers.add(
      ever(onlineSortAscending, (value) {
        HivePrefUtil.setBool(_sortAscendingPrefKey, value);
        applyLocalFilter();
      }),
    );
    _workers.add(
      debounce(searchKeyword, (_) {
        if (!_selectionTransaction) applyLocalFilter(resyncSource: false);
      }, time: const Duration(milliseconds: 200)),
    );

    // Begin verification during controller startup instead of waiting for the
    // first rendered frame. Persisted metadata remains useful, but its old
    // live/offline bit is invalidated synchronously so an ended stream is not
    // painted as live while requests are still in flight (or if one fails).
    unawaited(refreshPersistedRoomsOnStartup());

    tabController.addListener(_handleStatusTabChange);

    _setupRefreshStrategy();
    _configSubscription = refreshConfigController.configChanges.listen((config) {
      _setupRefreshStrategy();
    });

    listenFavorite();
    listenRoomChanged();
  }

  void _handleStatusTabChange() {
    if (tabController.indexIsChanging) return;
    final animationValue = tabController.animation?.value ?? tabController.index.toDouble();
    if ((animationValue - tabController.index).abs() > 0.001) return;
    selectStatusIndex(tabController.index);
  }

  void _setupRefreshStrategy() {
    _autoRefreshTimer?.cancel();
    final bool isEnabled = refreshConfigController.autoRefreshFavorite.value;
    final int interval = refreshConfigController.autoRefreshInterval.value;
    if (isEnabled && interval > 0) {
      _autoRefreshTimer = Timer.periodic(
        Duration(minutes: interval),
        (_) => unawaited(_fullRefreshRooms(showLoading: false, bypassFailureCooldown: true)),
      );
    }
  }

  void debounceRefresh() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_fullRefreshRooms(showLoading: false, bypassFailureCooldown: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _resumeRefreshTimer?.cancel();
      return;
    }
    if (!refreshConfigController.refreshFavoriteOnResume.value) {
      return;
    }
    final last = _lastFullRefreshAt;
    if (last == null || DateTime.now().difference(last) >= _resumeRefreshStaleAfter) {
      // Paint the retained snapshot first. JSON parsing and image URL updates
      // then land as one transaction instead of competing with the foreground
      // transition and producing several visibly different grids.
      _resumeRefreshTimer?.cancel();
      _resumeRefreshTimer = Timer(
        const Duration(milliseconds: 450),
        () => unawaited(
          _fullRefreshRooms(showLoading: true, emitFinish: false, bypassFailureCooldown: true),
        ),
      );
    }
  }

  @override
  void onClose() {
    _refreshEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    tabController.removeListener(_handleStatusTabChange);
    tabController.dispose();
    subscription?.cancel();
    roomChangedSubscription?.cancel();
    _watchTimeSubscription?.cancel();
    _configSubscription?.cancel();
    _autoRefreshTimer?.cancel();
    _debounceTimer?.cancel();
    _resumeRefreshTimer?.cancel();
    for (final worker in _workers) {
      worker.dispose();
    }
    super.onClose();
  }

  void listenFavorite() {
    subscription = EventBus.instance.listen('refresh_favorite_rooms', (data) {
      debounceRefresh();
    });
  }

  void listenRoomChanged() {
    roomChangedSubscription = EventBus.instance.listen('refresh_room_changed', (data) {
      applyLocalFilter();
    });
    // 按观看时长排序时，服务端防抖（3s）通知时长变化后重排列表。
    // applyLocalFilter 内部有快照比对，顺序未变化时不会触发 UI 重建。
    _watchTimeSubscription = EventBus.instance.listen(WatchTimeService.eventWatchTimeChanged, (
      data,
    ) {
      applyLocalFilter();
    });
  }

  bool _isUserOnFavoritePage() {
    try {
      final route = RouteObserverController.to.currentRoute.value;
      final onHome = route.isEmpty || route == RoutePath.kInitial || route == RoutePath.kFavorite;
      if (!onHome) return false;
      return tabBottomIndex.value == HomeMenu.favorites.index;
    } catch (_) {
      return false;
    }
  }

  void requestCancelRefresh() {
    if (!showRefreshShield.value) return;
    cancelRequested.value = true;
    _refreshEpoch++;
    _startupRefresh = null;
    showRefreshShield.value = false;
    loadding.value = false;
  }

  Set<String> _pruneSelectedTagsForRooms(List<LiveRoom> candidateRooms) {
    final selected = selectedTagIds;
    if (selected.contains(TagManagementController.allTagKey)) {
      return selected;
    }

    final hasUntagged = selected.contains(TagManagementController.untaggedTagKey);
    final realTags = selected.where((id) => id != TagManagementController.untaggedTagKey).toSet();

    final remaining = <String>{};
    if (hasUntagged) {
      final hasUntaggedRoom = candidateRooms.any(
        (room) => tagController.getTagsForRoom(room).isEmpty,
      );
      if (hasUntaggedRoom) remaining.add(TagManagementController.untaggedTagKey);
    }
    for (final tagId in realTags) {
      if (candidateRooms.any((room) => tagController.getTagsForRoom(room).contains(tagId))) {
        remaining.add(tagId);
      }
    }

    if (remaining.isEmpty) {
      return {TagManagementController.allTagKey};
    }
    return remaining;
  }

  /// Commits a settled platform page as one local filter transaction.
  ///
  /// The previous listener reset the tag and then changed the site in two Rx
  /// writes. Each write rebuilt and sorted the full favourites snapshot, so a
  /// single horizontal swipe could publish two different grids.
  void selectSiteIndex(int index) {
    final availableSites = Sites().availableSites(containsAll: true);
    if (index < 0 || index >= availableSites.length) return;
    final nextPlatformId = availableSites[index].id;
    final resetTag = !selectedTagIds.contains(TagManagementController.allTagKey);
    if (tabSiteIndex.value == index && selectedPlatformId == nextPlatformId && !resetTag) return;

    _selectionTransaction = true;
    tabSiteIndex.value = index;
    selectedPlatformId = nextPlatformId;
    if (resetTag) {
      final bucket = switch (tabOnlineIndex.value) {
        0 => <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms],
        1 => onlineRooms,
        2 => replayRooms,
        _ => offlineRooms,
      };
      final List<LiveRoom> candidateRooms;
      if (nextPlatformId == Sites.allSite) {
        candidateRooms = List<LiveRoom>.from(bucket);
      } else {
        final normalizedId = nextPlatformId.trim().toLowerCase();
        candidateRooms = bucket.where((r) => r.normalizedPlatformId == normalizedId).toList();
      }
      final pruned = _pruneSelectedTagsForRooms(candidateRooms);
      selectedTagIds.assignAll(pruned);
    }
    _selectionTransaction = false;
    currentPage = 1;
    applyLocalFilter(resyncSource: false);
  }

  void selectStatusIndex(int index) {
    if (index < 0 || index >= tabController.length) return;
    final resetTag = !selectedTagIds.contains(TagManagementController.allTagKey);
    if (tabOnlineIndex.value == index && !resetTag) return;

    _selectionTransaction = true;
    tabOnlineIndex.value = index;
    if (resetTag) {
      final currentAvailableSites = Sites().availableSites(containsAll: true);
      final siteId = (tabSiteIndex.value >= 0 && tabSiteIndex.value < currentAvailableSites.length)
          ? currentAvailableSites[tabSiteIndex.value].id
          : Sites.allSite;
      final bucket = switch (index) {
        0 => <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms],
        1 => onlineRooms,
        2 => replayRooms,
        _ => offlineRooms,
      };
      final List<LiveRoom> candidateRooms;
      if (siteId == Sites.allSite) {
        candidateRooms = List<LiveRoom>.from(bucket);
      } else {
        final normalizedId = siteId.trim().toLowerCase();
        candidateRooms = bucket.where((r) => r.normalizedPlatformId == normalizedId).toList();
      }
      final pruned = _pruneSelectedTagsForRooms(candidateRooms);
      selectedTagIds.assignAll(pruned);
    }
    _selectionTransaction = false;
    currentPage = 1;
    applyLocalFilter(resyncSource: false);
  }

  void animateToStatusIndex(int index) {
    if (index < 0 || index >= tabController.length) return;
    if (tabController.index == index) {
      selectStatusIndex(index);
      return;
    }
    tabController.animateTo(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void changeSelectedTag(String tagId) {
    currentPage = 1;
    final isAll = tagId == TagManagementController.allTagKey;
    final isUntagged = tagId == TagManagementController.untaggedTagKey;
    final isVirtual = isAll || isUntagged;

    if (multiSelectMode.value) {
      if (isVirtual) {
        selectedTagIds.assignAll({tagId});
      } else {
        final ids = <String>{...selectedTagIds};
        ids.remove(TagManagementController.allTagKey);
        ids.remove(TagManagementController.untaggedTagKey);
        if (ids.contains(tagId)) {
          ids.remove(tagId);
        } else {
          ids.add(tagId);
        }
        if (ids.isEmpty) {
          ids.add(TagManagementController.allTagKey);
        }
        selectedTagIds.assignAll(ids);
      }
    } else {
      if (selectedTagIds.length == 1 && selectedTagIds.first == tagId) return;
      selectedTagIds.assignAll({tagId});
    }
  }

  void updateRoomTags(LiveRoom room, List<String> newTagIds) {
    tagController.setRoomTags(room, newTagIds);
  }

  List<LiveRoom> getAllRooms() {
    return List<LiveRoom>.from(SettingsService.to.fav.favoriteRooms.v);
  }

  List<LiveRoom> getFilteredRoomsIgnoringLiveStatus() {
    final List<LiveRoom> source = List<LiveRoom>.from(SettingsService.to.fav.favoriteRooms.v);

    final currentAvailableSites = Sites().availableSites(containsAll: true);
    if (tabSiteIndex.value < 0 || tabSiteIndex.value >= currentAvailableSites.length) {
      return [];
    }

    final activeSite = currentAvailableSites[tabSiteIndex.value];
    List<LiveRoom> siteFiltered = source;

    if (activeSite.id != Sites.allSite) {
      final siteId = activeSite.id.trim().toLowerCase();
      siteFiltered = source.where((room) {
        return room.normalizedPlatformId == siteId;
      }).toList();
    }

    if (selectedTagIds.contains(TagManagementController.allTagKey)) {
      return siteFiltered.where(_matchesSearchKeyword).toList();
    }

    // 与 filteredSyncedRoomsForSite 的标签语义保持一致：
    // "未分组"是虚拟标签（getTagsForRoom 永远不会返回该 key），
    // 需要按"房间没有任何标签"判断，否则选中未分组时刷新范围为空集。
    final hasUntagged = selectedTagIds.contains(TagManagementController.untaggedTagKey);
    final realTagIds = selectedTagIds.where((id) => id != TagManagementController.untaggedTagKey);

    return siteFiltered
        .where((room) {
          final List<String> ids = tagController.getTagsForRoom(room);
          if (hasUntagged && ids.isNotEmpty) return false;
          if (hasUntagged && realTagIds.isEmpty) return true;
          return realTagIds.every((requiredTag) => ids.contains(requiredTag));
        })
        .where(_matchesSearchKeyword)
        .toList();
  }

  List<LiveRoom> getFilteredRooms({Iterable<LiveRoom>? roomSnapshot, bool resyncSource = true}) {
    if (resyncSource) syncRooms(roomSnapshot: roomSnapshot);

    return _filterSyncedRooms();
  }

  List<LiveRoom> _filterSyncedRooms() {
    final currentAvailableSites = Sites().availableSites(containsAll: true);
    if (tabSiteIndex.value < 0 || tabSiteIndex.value >= currentAvailableSites.length) {
      return [];
    }
    return filteredSyncedRoomsForSite(currentAvailableSites[tabSiteIndex.value].id);
  }

  List<LiveRoom> filteredSyncedRoomsForSite(String siteId) {
    List<LiveRoom> source;

    switch (tabOnlineIndex.value) {
      case 0:
        final merged = <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms];
        // 观看时长排序在"全部"页签跨状态统一排序，而不是按桶序拼接。
        if (onlineSortMode.value == OnlineSortMode.watchTime) {
          merged.sort(_compareOnlineRooms);
        }
        source = merged;
        break;

      case 1:
        source = onlineRooms;
        break;

      case 2:
        source = replayRooms;
        break;

      case 3:
        source = offlineRooms;
        break;

      default:
        source = onlineRooms;
    }

    List<LiveRoom> siteFiltered = source;

    if (siteId != Sites.allSite) {
      final normalizedSiteId = siteId.trim().toLowerCase();
      siteFiltered = source.where((room) {
        return room.normalizedPlatformId == normalizedSiteId;
      }).toList();
    }

    if (selectedTagIds.contains(TagManagementController.allTagKey)) {
      return siteFiltered.where(_matchesSearchKeyword).toList();
    }

    final hasUntagged = selectedTagIds.contains(TagManagementController.untaggedTagKey);
    final realTagIds = selectedTagIds.where((id) => id != TagManagementController.untaggedTagKey);

    return siteFiltered
        .where((room) {
          final List<String> ids = tagController.getTagsForRoom(room);
          if (hasUntagged && ids.isNotEmpty) return false;
          if (hasUntagged && realTagIds.isEmpty) return true;
          return realTagIds.every((requiredTag) => ids.contains(requiredTag));
        })
        .where(_matchesSearchKeyword)
        .toList();
  }

  int favoriteCountForSite(String siteId, {int? statusIndex}) {
    final Iterable<LiveRoom> source = statusIndex == null
        ? SettingsService.to.fav.favoriteRooms.v
        : switch (statusIndex) {
            0 => <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms],
            1 => onlineRooms,
            2 => replayRooms,
            3 => offlineRooms,
            _ => const <LiveRoom>[],
          };
    if (siteId == Sites.allSite) return source.length;
    final normalizedSite = siteId.trim().toLowerCase();
    return source.where((room) => room.platform?.trim().toLowerCase() == normalizedSite).length;
  }

  void syncRooms({Iterable<LiveRoom>? roomSnapshot}) {
    final preview = roomSnapshot == null ? _verificationPreview : null;
    final List<LiveRoom> roomsBase = List<LiveRoom>.from(
      roomSnapshot ?? preview?.rooms ?? SettingsService.to.fav.favoriteRooms.v,
    );
    _lastSyncedFavoriteSnapshot = _favoriteSnapshotSignature(roomsBase);
    final nextOnline = preview != null
        ? List<LiveRoom>.from(preview.onlineRooms)
        : roomsBase.where((r) => r.isLiveNow && r.isRecord == false).toList();
    final nextOffline = preview != null
        ? List<LiveRoom>.from(preview.offlineRooms)
        : roomsBase.where((r) => !r.isPlayableNow).toList();
    final nextReplay = preview != null
        ? List<LiveRoom>.from(preview.replayRooms)
        : roomsBase.where((r) => r.effectiveLiveStatus == LiveStatus.replay).toList();

    final currentAvailableSites = Sites().availableSites(containsAll: true);
    var nextVisibleTags = <LiveTag>[];

    if (tabSiteIndex.value >= 0 && tabSiteIndex.value < currentAvailableSites.length) {
      final activeSite = currentAvailableSites[tabSiteIndex.value];
      List<LiveRoom> target;

      switch (tabOnlineIndex.value) {
        case 0:
          target = <LiveRoom>[...nextOnline, ...nextReplay, ...nextOffline];
          break;

        case 1:
          target = nextOnline;
          break;

        case 2:
          target = nextReplay;
          break;

        case 3:
          target = nextOffline;
          break;

        default:
          target = nextOnline;
      }
      final Set<String> tagIds = {};
      final normalizedSiteId = activeSite.id.trim().toLowerCase();

      for (var room in target) {
        if (activeSite.id == Sites.allSite || room.normalizedPlatformId == normalizedSiteId) {
          tagIds.addAll(tagController.getTagsForRoom(room));
        }
      }

      nextVisibleTags = tagController.tags.where((t) => tagIds.contains(t.id)).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
    }

    // --- Pseudo live duration (disabled, see field declarations above) ---
    // final currentOnlineKeys = nextOnline.map((r) => r.identityKey).toSet();
    // if (_onlineBaselineCaptured) {
    //   final newlyOnline = currentOnlineKeys.difference(_lastOnlineKeys);
    //   final endedOnline = _lastOnlineKeys.difference(currentOnlineKeys);
    //   if (newlyOnline.isNotEmpty) {
    //     final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    //     for (final room in nextOnline) {
    //       if (newlyOnline.contains(room.identityKey) && room.startTime == null) {
    //         _fakeStartTime[room.identityKey] = now;
    //       }
    //     }
    //   }
    //   if (endedOnline.isNotEmpty) {
    //     _fakeStartTime.removeWhere((key, _) => endedOnline.contains(key));
    //   }
    // } else {
    //   _onlineBaselineCaptured = true;
    // }
    // _lastOnlineKeys
    //   ..clear()
    //   ..addAll(currentOnlineKeys);

    nextOnline.sort(_compareOnlineRooms);
    if (onlineSortMode.value == OnlineSortMode.watchTime) {
      // 观看时长排序对所有状态的直播间生效：三个桶按同一规则排序。
      nextReplay.sort(_compareOnlineRooms);
      nextOffline.sort(_compareOnlineRooms);
    } else {
      nextReplay.sort(_compareAudience);
    }

    _assignIfSnapshotChanged(onlineRooms, nextOnline);
    _assignIfSnapshotChanged(offlineRooms, nextOffline);
    _assignIfSnapshotChanged(replayRooms, nextReplay);
    _assignIfSnapshotChanged(visibleTags, nextVisibleTags);
  }

  bool _isCurrentFavoriteSnapshotSynced() {
    return _lastSyncedFavoriteSnapshot ==
        _favoriteSnapshotSignature(SettingsService.to.fav.favoriteRooms.v);
  }

  int _favoriteSnapshotSignature(Iterable<LiveRoom> rooms) {
    return Object.hashAll(
      rooms.map(
        (room) => Object.hash(
          room.identityKey,
          room.effectiveLiveStatus,
          room.isRecord,
          room.title,
          room.nick,
          room.avatar,
          room.cover,
          room.area,
          room.watching,
          room.popularity,
          room.onlineViewers,
          room.totalViewers,
          room.followers,
          Object.hashAll(room.tagIds),
        ),
      ),
    );
  }

  void _refreshVisibleTagsFromSyncedRooms() {
    final sites = Sites().availableSites(containsAll: true);
    if (tabSiteIndex.value < 0 || tabSiteIndex.value >= sites.length) {
      _assignIfSnapshotChanged(visibleTags, const <LiveTag>[]);
      return;
    }
    final source = switch (tabOnlineIndex.value) {
      0 => <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms],
      1 => onlineRooms,
      2 => replayRooms,
      3 => offlineRooms,
      _ => onlineRooms,
    };
    final siteId = sites[tabSiteIndex.value].id;
    final tagIds = <String>{};
    for (final room in source) {
      if (siteId != Sites.allSite && room.normalizedPlatformId != siteId) continue;
      tagIds.addAll(tagController.getTagsForRoom(room));
    }
    final next = tagController.tags.where((tag) => tagIds.contains(tag.id)).toList(growable: false)
      ..sort((left, right) => left.order.compareTo(right.order));
    _assignIfSnapshotChanged(visibleTags, next);
  }

  void _assignIfSnapshotChanged<T>(RxList<T> target, List<T> next) {
    if (target.length == next.length) {
      var identicalSnapshot = true;
      for (var index = 0; index < next.length; index++) {
        if (!identical(target[index], next[index])) {
          identicalSnapshot = false;
          break;
        }
      }
      if (identicalSnapshot) return;
    }
    target.assignAll(next);
  }

  int _compareAudience(LiveRoom left, LiveRoom right) {
    final app = SettingsService.to.app;
    return LiveRoom.compareAudienceRanking(
      left,
      right,
      preferRealOnline: app.preferRealOnlineCounts.v,
      platformEnabled: app.isRealOnlineEnabledFor,
    );
  }

  int _compareOnlineRooms(LiveRoom a, LiveRoom b) {
    if (enablePinned.value) {
      final aPinned = tagController.isPinRoom(a);
      final bPinned = tagController.isPinRoom(b);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
    }

    if (!selectedTagIds.contains(TagManagementController.allTagKey)) {
      final sa = _getRoomTagScore(a);
      final sb = _getRoomTagScore(b);
      if (sa != sb) return sb.compareTo(sa);
    }

    final primary = switch (onlineSortMode.value) {
      OnlineSortMode.startTime => _compareStartTime(a, b),
      OnlineSortMode.watchTime => _compareWatchTime(a, b),
      _ => _compareAudience(a, b),
    };
    // 置顶/标签分是优先级排序，不随方向翻转；仅模式比较结果受升降序控制。
    return onlineSortAscending.value ? -primary : primary;
  }

  int _compareWatchTime(LiveRoom a, LiveRoom b) {
    final aSeconds = WatchTimeService.secondsFor(a.identityKey);
    final bSeconds = WatchTimeService.secondsFor(b.identityKey);
    if (aSeconds != bSeconds) return bSeconds.compareTo(aSeconds);
    return _compareAudience(a, b);
  }

  int _compareStartTime(LiveRoom a, LiveRoom b) {
    // Pseudo fallback disabled — use real startTime only (see field declarations above)
    final aTime = a.startTime; // ?? _fakeStartTime[a.identityKey]
    final bTime = b.startTime; // ?? _fakeStartTime[b.identityKey]
    if (aTime != null && bTime != null) return bTime.compareTo(aTime);
    if (aTime != null) return -1;
    if (bTime != null) return 1;
    return _compareAudience(a, b);
  }

  int _getRoomTagScore(LiveRoom room) {
    final ids = tagController.getTagsForRoom(room);
    if (ids.isEmpty) return 0;
    final requiredIds = selectedTagIds;

    int highest = 0;
    const maxScore = 1000000;

    for (var id in ids) {
      if (!requiredIds.contains(id)) continue;
      final idx = tagController.tags.indexWhere((t) => id == t.id);
      if (idx != -1) {
        final tag = tagController.tags[idx];
        final score = maxScore - tag.order * 100;
        if (score > highest) highest = score;
      }
    }
    return highest;
  }

  bool _matchesSearchKeyword(LiveRoom room) {
    final raw = searchKeyword.value.trim();
    if (raw.isEmpty) return true;

    final keywords = raw
        .split(RegExp(r'\s+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
    if (keywords.isEmpty) return true;

    final title = room.title?.trim().toLowerCase() ?? '';
    final nick = room.nick?.trim().toLowerCase() ?? '';
    final roomId = room.roomId?.trim().toLowerCase() ?? '';
    final tagNames = tagController
        .getTagsForRoom(room)
        .map(
          (id) => tagController.tags
              .firstWhere(
                (t) => t.id == id,
                orElse: () => LiveTag(id: '', name: ''),
              )
              .name
              .toLowerCase(),
        )
        .toList();

    return keywords.any((kw) {
      if (title.contains(kw)) return true;
      if (nick.contains(kw)) return true;
      if (roomId.contains(kw)) return true;
      if (tagNames.any((name) => name.contains(kw))) return true;
      return false;
    });
  }

  void _recalculateUntaggedCount() {
    final sites = Sites().availableSites(containsAll: true);
    if (tabSiteIndex.value < 0 || tabSiteIndex.value >= sites.length) {
      if (visibleUntaggedCount.value != 0) visibleUntaggedCount.value = 0;
      return;
    }
    final source = switch (tabOnlineIndex.value) {
      0 => <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms],
      1 => onlineRooms,
      2 => replayRooms,
      3 => offlineRooms,
      _ => onlineRooms,
    };
    final siteId = sites[tabSiteIndex.value].id;
    int count = 0;
    for (final room in source) {
      if (siteId != Sites.allSite && room.normalizedPlatformId != siteId) continue;
      if (tagController.getTagsForRoom(room).isEmpty) count++;
    }
    if (visibleUntaggedCount.value != count) {
      visibleUntaggedCount.value = count;
    }
  }

  void applyLocalFilter({bool resyncSource = true}) {
    if (!resyncSource) _refreshVisibleTagsFromSyncedRooms();
    final filtered = getFilteredRooms(resyncSource: resyncSource);
    updateLocalReactivePool(filtered);
    _recalculateUntaggedCount();
  }

  @override
  Future<void> refreshData() async {
    final startup = _startupRefresh;
    if (startup != null) {
      // BasePageView performs a one-time mobile/desktop layout notification.
      // Coalesce that request with the cold-start verification instead of
      // incrementing _refreshEpoch and cancelling the authoritative refresh.
      await startup;
      return;
    }
    currentPage = 1;
    cancelRequested.value = false;
    showRefreshShield.value = true;
    await _fullRefreshFilterRooms(showLoading: true, bypassFailureCooldown: true);
  }

  Future<void> _fullRefreshFilterRooms({
    required bool showLoading,
    bool bypassFailureCooldown = false,
  }) async {
    // 全部平台 + 全部标签 + 无搜索 = 筛选是 no-op，刷新范围就是全部收藏，
    // 遮罩语义保持"全部"而不是误导性的"当前筛选"。
    final sites = Sites().availableSites(containsAll: true);
    final isUnfiltered =
        tabSiteIndex.value >= 0 &&
        tabSiteIndex.value < sites.length &&
        sites[tabSiteIndex.value].id == Sites.allSite &&
        selectedTagIds.contains(TagManagementController.allTagKey) &&
        searchKeyword.value.trim().isEmpty;
    refreshShieldScope.value = isUnfiltered
        ? FavoriteRefreshScope.all
        : FavoriteRefreshScope.filtered;
    final roomsToRefresh = getFilteredRoomsIgnoringLiveStatus();
    await _runRoomRefresh(
      roomsToRefresh,
      showLoading: showLoading,
      markFullRefresh: true,
      invalidateUnverified: true,
      bypassFailureCooldown: bypassFailureCooldown,
    );
  }

  Future<void> _fullRefreshRooms({
    required bool showLoading,
    bool emitFinish = true,
    bool bypassFailureCooldown = false,
  }) async {
    final startup = _startupRefresh;
    if (startup != null) {
      // Cold-start verification already covers every favourite. Coalescing
      // lifecycle/timer events here prevents a second refresh from invalidating
      // the authoritative startup result halfway through its network pass.
      await startup;
      return;
    }
    final roomsToRefresh = getAllRooms();
    cancelRequested.value = false;
    refreshShieldScope.value = FavoriteRefreshScope.all;
    showRefreshShield.value = _isUserOnFavoritePage();
    await _runRoomRefresh(
      roomsToRefresh,
      showLoading: showLoading,
      emitFinish: emitFinish,
      markFullRefresh: true,
      invalidateUnverified: true,
      bypassFailureCooldown: bypassFailureCooldown,
    );
  }

  Future<void> refreshPersistedRoomsOnStartup() {
    final current = _startupRefresh;
    if (current != null) return current;

    late final Future<void> operation;
    operation = _refreshPersistedRoomsOnStartupInternal().whenComplete(() {
      if (identical(_startupRefresh, operation)) _startupRefresh = null;
    });
    _startupRefresh = operation;
    return operation;
  }

  Future<void> _refreshPersistedRoomsOnStartupInternal() async {
    final persisted = List<LiveRoom>.from(SettingsService.to.fav.favoriteRooms.v);
    _verificationPreview = buildFavoriteVerificationPreview(persisted);
    isVerifyingFavorites.value = true;
    cancelRequested.value = false;
    refreshShieldScope.value = FavoriteRefreshScope.all;
    showRefreshShield.value = true;
    if (persisted.isNotEmpty) {
      // Keep cached metadata and bucket positions, but publish every status as
      // unknown. This avoids both stale "live" claims and the clear/reorder/
      // reappear sequence that made launch feel visually unstable.
      applyLocalFilter();
      pageEmpty.value = false;
    } else {
      applyLocalFilter();
    }
    try {
      await _runRoomRefresh(
        persisted,
        showLoading: true,
        emitFinish: false,
        markFullRefresh: true,
        invalidateUnverified: true,
        bypassFailureCooldown: true,
      );
      // 启动校验延伸到历史记录：复用收藏校验结果，未覆盖的房间增量轻量刷新。
      await _refreshHistoryAfterStartupVerification();
    } finally {
      _verificationPreview = null;
      isVerifyingFavorites.value = false;
      // Also restores a useful offline/unknown view if a controller-level
      // exception interrupted the refresh before its normal final publish.
      applyLocalFilter();
    }
  }

  /// 启动校验的历史记录部分（受历史最大保留数量限制）。
  ///
  /// 身份与收藏一致的房间直接复用收藏校验结果（不重复发请求）；
  /// 其余房间（不在收藏中，或收藏校验失败标为 unknown）走历史轻量刷新，
  /// 失败保留旧数据。写回前重读当前历史列表，刷新期间新增/删除的条目不受影响。
  Future<void> _refreshHistoryAfterStartupVerification() async {
    try {
      final history = SettingsService.to.history;
      final limited = applyHistoryLimit(history.historyRooms.v, history.historyLimit.v);
      if (limited.isEmpty) return;

      final refreshEpoch = _refreshEpoch;
      final favMap = <String, LiveRoom>{
        for (final room in SettingsService.to.fav.favoriteRooms.v) room.identityKey: room,
      };
      final settled = List<LiveRoom>.from(limited);
      final pending = <LiveRoom>[];
      for (var index = 0; index < limited.length; index++) {
        final room = limited[index];
        final fav = favMap[room.identityKey];
        // 只复用收藏校验成功的数据；unknown 表示该房间请求失败，不能作为数据源。
        if (fav != null && fav.effectiveLiveStatus != LiveStatus.unknown) {
          settled[index] = preserveHistoryMetadata(fav, room);
        } else {
          pending.add(room);
        }
      }

      if (pending.isNotEmpty) {
        final result = await history.refreshRoomDetails(
          pending,
          shouldCancel: () => isClosed || refreshEpoch != _refreshEpoch,
        );
        if (result == null) return;
        final refreshedByIdentity = <String, LiveRoom>{
          for (final room in result.rooms) room.identityKey: room,
        };
        for (var index = 0; index < settled.length; index++) {
          final refreshed = refreshedByIdentity[settled[index].identityKey];
          if (refreshed != null) settled[index] = refreshed;
        }
      }

      final byIdentity = <String, LiveRoom>{for (final room in settled) room.identityKey: room};
      final current = history.historyRooms.v;
      final next = [
        for (final room in current)
          byIdentity.containsKey(room.identityKey)
              ? preserveHistoryMetadata(byIdentity[room.identityKey]!, room)
              : room,
      ];
      var changed = current.length != next.length;
      if (!changed) {
        for (var index = 0; index < next.length; index++) {
          if (!identical(current[index], next[index])) {
            changed = true;
            break;
          }
        }
      }
      if (changed) history.historyRooms.v = next;
    } catch (_) {
      // 历史校验是非关键路径，任何异常都不影响启动流程。
    }
  }

  Future<void> _runRoomRefresh(
    List<LiveRoom> rooms, {
    required bool showLoading,
    bool emitFinish = true,
    bool markFullRefresh = false,
    bool invalidateUnverified = false,
    bool bypassFailureCooldown = false,
  }) {
    // One refresh owns the snapshot transaction at a time. The former epoch
    // scheme cancelled whichever pass happened to finish second; a lifecycle
    // resume 450 ms after launch could therefore discard startup verification
    // and leave failed rooms with yesterday's live bit.
    return _refreshLock.synchronized(() async {
      if (isClosed) return;
      final refreshEpoch = _refreshEpoch;
      if (showLoading) loadding.value = true;
      try {
        final updates = await _refreshRoomDetails(
          rooms,
          refreshEpoch: refreshEpoch,
          bypassFailureCooldown: bypassFailureCooldown,
        );
        if (refreshEpoch != _refreshEpoch || isClosed) return;

        final latest = List<LiveRoom>.from(SettingsService.to.fav.favoriteRooms.v);
        final merged = invalidateUnverified
            ? mergeAuthoritativeFavoriteRefresh(latest, rooms.map(favoriteRoomIdentity), updates)
            : mergeFavoriteRoomUpdates(latest, updates);
        if (merged.changed) {
          // One Hive write and one visible publication. A failed startup request
          // remains unknown instead of carrying the previous process's live bit.
          SettingsService.to.fav.favoriteRooms.v = merged.rooms;
        }
        if (markFullRefresh) _lastFullRefreshAt = DateTime.now();
        applyLocalFilter();
        if (emitFinish) EventBus.instance.emit('refresh_favorite_finish', true);
      } finally {
        showRefreshShield.value = false;
        cancelRequested.value = false;
        if (showLoading && refreshEpoch == _refreshEpoch && !isClosed) {
          loadding.value = false;
        }
      }
    });
  }

  Future<Map<String, LiveRoom>> _refreshRoomDetails(
    List<LiveRoom> rooms, {
    required int refreshEpoch,
    required bool bypassFailureCooldown,
  }) async {
    // Platforms hidden in the display settings never enter the refresh flow:
    // their cards are invisible, so refreshing them is pure traffic waste and
    // only raises per-host rate-limit exposure.
    final enabledPlatforms = Sites()
        .availableSites()
        .map((site) => site.id.trim().toLowerCase())
        .toSet();
    final valid = rooms
        .where(
          (r) =>
              (r.platform?.isNotEmpty ?? false) &&
              (r.roomId?.isNotEmpty ?? false) &&
              enabledPlatforms.contains(r.normalizedPlatformId),
        )
        .toList(growable: false);
    if (valid.isEmpty) return const <String, LiveRoom>{};

    // Rate limits are enforced per host, so run one bounded pool per platform.
    // A mixed list parallelises across hosts while each single platform stays
    // within its own configured burst ceiling.
    final groups = <String, List<LiveRoom>>{};
    for (final room in valid) {
      groups.putIfAbsent(room.normalizedPlatformId, () => []).add(room);
    }

    // Reuse one adapter per platform inside a refresh pass. Besides reducing
    // allocation, this lets cookie/device/bootstrap requests use single-flight
    // state while the bounded I/O workers refresh several cards concurrently.
    final siteCache = <String, LiveSite>{};
    final groupResults = await Future.wait(
      groups.entries.map((entry) {
        return boundedAsyncMap<LiveRoom, ({String key, LiveRoom room})>(
          entry.value,
          maxConcurrent: refreshConfigController.platformConcurrencyOf(entry.key),
          task: (room) async {
            final updated = await _refreshOneRoom(
              room,
              siteCache,
              bypassFailureCooldown: bypassFailureCooldown,
            );
            if (updated == null) return null;
            // Match by the requested favourite identity, not a canonical id that a
            // platform may return (Douyin room ids, for example, can change to the
            // stable web rid). Keep the stored identity stable for tags and keys.
            return (key: _roomKey(room), room: bindFavoriteRefreshResultToRequest(room, updated));
          },
          shouldCancel: () => refreshEpoch != _refreshEpoch || isClosed,
        );
      }),
    );
    if (refreshEpoch != _refreshEpoch || isClosed) return const <String, LiveRoom>{};
    final pendingUpdates = <String, LiveRoom>{};
    for (final results in groupResults) {
      for (final update in results.whereType<({String key, LiveRoom room})>()) {
        pendingUpdates[update.key] = update.room;
      }
    }
    return pendingUpdates;
  }

  Future<LiveRoom?> _refreshOneRoom(
    LiveRoom room,
    Map<String, LiveSite> siteCache, {
    required bool bypassFailureCooldown,
  }) async {
    final key = _roomKey(room);

    final failedAt = _refreshFailureCooldown[key];
    if (!bypassFailureCooldown &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < _refreshFailureRetryAfter) {
      return null;
    }

    final succeededAt = _refreshSuccessCooldown[key];
    if (succeededAt != null && DateTime.now().difference(succeededAt) < _refreshSuccessInterval) {
      return room;
    }

    try {
      final platform = room.normalizedPlatformId;
      final roomId = room.normalizedRoomId;

      final liveSite = siteCache.putIfAbsent(platform, () => Sites.of(platform).liveSite);

      final operation = liveSite is LiveSiteRoomRefresher
          ? (liveSite as LiveSiteRoomRefresher).getRoomDetailForRefresh(
              roomId: roomId,
              platform: platform,
            )
          : liveSite.getRoomDetail(roomId: roomId, platform: platform);

      final result = await operation.timeout(_roomRefreshTimeout);

      _refreshFailureCooldown.remove(key);
      _refreshSuccessCooldown[key] = DateTime.now();

      return result;
    } on TimeoutException {
      _refreshFailureCooldown[key] = DateTime.now();
      _refreshSuccessCooldown.remove(key);

      developer.log('Favorite room refresh timeout: $key', name: 'FavoriteController');

      return null;
    } catch (error) {
      _refreshFailureCooldown[key] = DateTime.now();
      _refreshSuccessCooldown.remove(key);

      developer.log(
        'Favorite room refresh failed: $key (${error.runtimeType})',
        name: 'FavoriteController',
      );

      return null;
    }
  }

  String _roomKey(LiveRoom room) => favoriteRoomIdentity(room);

  String _mainCategoryOf(String rawArea) {
    final trimmed = rawArea.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split('/');
    for (final part in parts) {
      final p = part.trim();
      if (p.isNotEmpty) return p;
    }
    return '';
  }

  Future<
    ({int totalRooms, int noAreaRooms, int successRooms, int skippedExistingTag, int createdTags})
  >
  autoMatchAreaTags({void Function(int current, int total, String? status)? onProgress}) async {
    final allRooms = List<LiveRoom>.from(SettingsService.to.fav.favoriteRooms.v);
    final total = allRooms.length;

    onProgress?.call(0, total, null);

    final mainCategories = <String>{};
    int noAreaRooms = 0;

    for (final room in allRooms) {
      final category = _mainCategoryOf(room.area ?? '');
      if (category.isEmpty) {
        noAreaRooms++;
        continue;
      }
      mainCategories.add(category);
    }

    onProgress?.call(total ~/ 3, total, null);

    int createdTags = 0;
    final categoryTagIds = <String, String>{};
    for (final name in mainCategories) {
      final before = tagController.findTagByName(name);
      final tag = tagController.ensureTagByName(name);
      if (before == null) createdTags++;
      categoryTagIds[name] = tag.id;
      await Future.microtask(() {});
    }

    int successRooms = 0;
    int skippedExistingTag = 0;
    int processed = 0;

    for (final room in allRooms) {
      processed++;
      final category = _mainCategoryOf(room.area ?? '');
      if (category.isEmpty) {
        onProgress?.call(processed, total, null);
        await Future.microtask(() {});
        continue;
      }
      final targetTagId = categoryTagIds[category];
      if (targetTagId == null) {
        onProgress?.call(processed, total, null);
        await Future.microtask(() {});
        continue;
      }

      final existingIds = List<String>.from(tagController.getTagsForRoom(room));
      if (existingIds.contains(targetTagId)) {
        skippedExistingTag++;
      } else {
        existingIds.add(targetTagId);
        tagController.setRoomTags(room, existingIds);
        successRooms++;
      }

      onProgress?.call(processed, total, null);
      await Future.microtask(() {});
    }

    applyLocalFilter();

    return (
      totalRooms: total,
      noAreaRooms: noAreaRooms,
      successRooms: successRooms,
      skippedExistingTag: skippedExistingTag,
      createdTags: createdTags,
    );
  }
}
