import 'dart:async';
import 'dart:developer' as developer;

import 'package:pure_live/common/index.dart';
import 'package:synchronized/synchronized.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/modules/tags/live_tag.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';
import 'package:pure_live/modules/favorite/favorite_startup_policy.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/consts/app_consts.dart';
import 'package:pure_live/routes/route_observer_controller.dart';

/// 收藏页排序策略（5.2）：观众数 / 开播时间 / 累计观看时长。
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
  Timer? _favoriteSnapshotTimer;
  final List<Worker> _workers = [];
  bool _selectionTransaction = false;
  int? _lastSyncedFavoriteSnapshot;
  int _refreshEpoch = 0;
  final Lock _refreshLock = Lock();
  final lastFullRefreshAt = Rx<DateTime?>(null);
  final isVerifyingFavorites = false.obs;
  Future<void>? _startupRefresh;
  Future<void>? _activeRoomRefresh;
  FavoriteVerificationPreview? _verificationPreview;
  final Map<String, DateTime> _refreshFailureCooldown = {};
  final Map<String, DateTime> _refreshSuccessCooldown = {};

  /// 刷新成功保护（请求节流）：所有刷新入口生效。冷却期内不再重复发起请求，
  /// 直接把当前房间数据当作本次结果返回（对齐开发版的特别处理），保证权威合并
  /// （invalidateUnverified）不会把未请求的房间误标为失效而清空内容。
  Duration get _refreshSuccessInterval => Duration(seconds: refreshConfigController.successCooldownSeconds.v);

  /// 刷新失败保护（失败退避）：仅后台自动刷新定时器生效；手动刷新、启动刷新、
  /// 前台恢复与事件触发的刷新均绕过（bypassFailureCooldown），保证用户主动
  /// 触发的刷新总是真实重试。
  Duration get _refreshFailureRetryAfter => Duration(minutes: refreshConfigController.failureRetryMinutes.v);
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

  /// 关注页卡片布局模式：'standard'（封面+信息栏）/ 'compact'（列表式，仅头像+信息栏）。
  final cardLayoutMode = 'standard'.obs;

  /// 紧凑布局是否正在覆盖每页数量（用于切回标准布局时恢复）。
  bool _compactPageOverride = false;
  Timer? _compactPageDebounce;

  /// 紧凑布局的动态分页：每页数量 = 视口可容纳的完整卡片数，下限 10。
  /// [capacity] 传 null 表示离开紧凑布局，恢复设置中的每页数量。
  /// 房间总数不足一页时由分页切片自然显示全部。
  void applyCompactPageSize(int? capacity) {
    if (isClosed) return;
    if (capacity != null) {
      _compactPageOverride = true;
      final target = capacity < 10 ? 10 : capacity;
      _compactPageDebounce?.cancel();
      // 防抖：窗口拖动过程中高度连续变化，避免频繁重切分页。
      _compactPageDebounce = Timer(const Duration(milliseconds: 150), () {
        if (isClosed) return;
        setPageSize(target);
      });
    } else if (_compactPageOverride) {
      _compactPageOverride = false;
      _compactPageDebounce?.cancel();
      setPageSize(SettingsService.to.page.defaultPageSize.v);
    }
  }

  // 这三个 Hive key 需要公开：备份导入 favoriteCtrl 段时若控制器尚未实例化
  // （lazyPut），直接写 key 等其创建时恢复，避免 Get.find 触发工厂副作用。
  static const String pinnedPrefKey = 'fav_enable_pinned';
  static const String sortModePrefKey = 'fav_online_sort_mode';
  static const String sortAscendingPrefKey = 'fav_online_sort_ascending';
  static const String layoutModePrefKey = 'fav_card_layout_mode';

  final showRefreshShield = false.obs;
  final cancelRequested = false.obs;

  /// 当前遮罩对应的刷新范围，用于遮罩文案区分"全部关注"与"按当前筛选"。
  final refreshShieldScope = FavoriteRefreshScope.all.obs;

  final DateTime Function() _now;

  FavoriteController({DateTime Function()? now}) : _now = now ?? DateTime.now, super();

  /// Resolves the adapter once per platform in each refresh pass. Keep adapter
  /// construction separate from snapshot ownership and persistence.
  LiveSite createRoomRefreshSite(String platform) => Sites.of(platform).liveSite;

  @override
  Future<void>? get activePageOperation => _startupRefresh ?? _activeRoomRefresh ?? super.activePageOperation;

  @override
  void onInit() {
    super.onInit();

    // 持久化恢复（5.2）：置顶开关 / 排序模式 / 升降序。
    final pinnedFromDisk = HivePrefUtil.getBool(pinnedPrefKey);
    if (pinnedFromDisk != null) enablePinned.value = pinnedFromDisk;

    final sortFromDisk = HivePrefUtil.getString(sortModePrefKey);
    if (sortFromDisk != null) {
      onlineSortMode.value = OnlineSortMode.values.firstWhere(
        (e) => e.name == sortFromDisk,
        orElse: () => OnlineSortMode.audience,
      );
    }

    final ascendingFromDisk = HivePrefUtil.getBool(sortAscendingPrefKey);
    if (ascendingFromDisk != null) onlineSortAscending.value = ascendingFromDisk;

    // 布局模式：默认 standard，兼容值缺失时回退。
    final layoutFromDisk = HivePrefUtil.getString(layoutModePrefKey);
    if (layoutFromDisk == 'compact' || layoutFromDisk == 'standard') {
      cardLayoutMode.value = layoutFromDisk!;
    }

    // 5.3："全部"页签（0）+ 在线（1，默认）/ 录播（2）/ 离线（3）。
    tabController = TabController(
      length: 4,
      initialIndex: 1,
      vsync: this,
      animationDuration: pureLiveTabTransitionDuration,
    );
    WidgetsBinding.instance.addObserver(this);
    tagController.migrateLegacyRoomTagKeys(SettingsService.to.fav.favoriteRooms.v);

    _workers.add(
      ever(SettingsService.to.fav.favoriteRooms, (_) {
        if (isClosed) return;
        _favoriteSnapshotTimer?.cancel();
        // Own the delayed action as well as its subscription: disposing a
        // debounce Worker alone leaves its existing Timer alive.
        _favoriteSnapshotTimer = Timer(const Duration(milliseconds: 1000), () {
          if (isClosed || isVerifyingFavorites.value) return;
          if (!_isCurrentFavoriteSnapshotSynced()) applyLocalFilter();
        });
      }),
    );

    _workers.add(
      ever(selectedTagIds, (_) {
        if (!_selectionTransaction) applyLocalFilter();
      }),
    );
    _workers.add(
      ever(multiSelectMode, (enabled) {
        // 关闭多选时回到"全部"单选语义（5.5）。
        if (!enabled) selectedTagIds.assignAll({TagManagementController.allTagKey});
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
    _workers.add(ever(tagController.tags, _handleTagsChanged));
    _workers.add(ever(tagController.roomTagsMap, (_) => applyLocalFilter()));
    _workers.add(ever(SettingsService.to.app.preferRealOnlineCounts, (_) => applyLocalFilter()));
    _workers.add(ever(SettingsService.to.app.realOnlinePlatforms, (_) => applyLocalFilter()));
    _workers.add(
      ever(enablePinned, (value) {
        HivePrefUtil.setBool(pinnedPrefKey, value);
        applyLocalFilter();
      }),
    );
    _workers.add(
      ever(onlineSortMode, (value) {
        HivePrefUtil.setString(sortModePrefKey, value.name);
        applyLocalFilter();
      }),
    );
    _workers.add(
      ever(onlineSortAscending, (value) {
        HivePrefUtil.setBool(sortAscendingPrefKey, value);
        applyLocalFilter();
      }),
    );
    _workers.add(
      ever(cardLayoutMode, (value) {
        HivePrefUtil.setString(layoutModePrefKey, value);
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
      if (!config.refreshFavoriteOnResume) _cancelPendingResumeRefresh();
      _setupRefreshStrategy();
    });

    listenFavorite();
    listenRoomChanged();
  }

  void _handleTagsChanged(List<LiveTag> tags) {
    if (isClosed) return;
    if (!selectedTagIds.contains(TagManagementController.allTagKey)) {
      final selected = selectedTagIds
          .where((id) => id != TagManagementController.untaggedTagKey && tags.any((tag) => tag.id == id))
          .toSet();
      if (selected.isEmpty) selected.add(TagManagementController.allTagKey);
      if (!_roomTagSetsEqual(selectedTagIds, selected)) {
        _selectionTransaction = true;
        selectedTagIds.assignAll(selected);
        _selectionTransaction = false;
        currentPage = 1;
      }
    }
    applyLocalFilter();
  }

  bool _roomTagSetsEqual(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }

  void _handleStatusTabChange() {
    if (isClosed) return;
    if (tabController.indexIsChanging) return;
    final animationValue = tabController.animation?.value ?? tabController.index.toDouble();
    if ((animationValue - tabController.index).abs() > 0.001) return;
    selectStatusIndex(tabController.index);
  }

  void _setupRefreshStrategy() {
    if (isClosed) return;
    _autoRefreshTimer?.cancel();
    final bool isEnabled = refreshConfigController.autoRefreshFavorite.value;
    final int interval = refreshConfigController.autoRefreshInterval.value;
    if (isEnabled && interval > 0) {
      _autoRefreshTimer = Timer.periodic(
        Duration(minutes: interval),
        // 后台周期任务不绕过失败保护：近期失败的房间保持现状等下一轮重试，
        // 避免反复轰炸故障平台（失败保护唯一生效入口，有意与开发版不同）。
        (_) => unawaited(_fullRefreshRooms(showLoading: false)),
      );
    }
  }

  void debounceRefresh() {
    if (isClosed) return;
    // A local favourite change already schedules a complete refresh sooner
    // than the delayed resume pass. Keep only the user-owned trigger so one
    // change cannot publish two consecutive network snapshots.
    _cancelPendingResumeRefresh();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      // 事件由用户操作（关注变更/换台面板刷新）触发，必须真实重试，
      // 绕过失败保护（对齐开发版）。
      unawaited(_fullRefreshRooms(showLoading: false, bypassFailureCooldown: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (isClosed) return;
    if (state != AppLifecycleState.resumed) {
      _cancelPendingResumeRefresh();
      return;
    }
    if (!refreshConfigController.refreshFavoriteOnResume.value) {
      _cancelPendingResumeRefresh();
      return;
    }
    final last = lastFullRefreshAt.value;
    if (last == null || _now().difference(last) >= _resumeRefreshStaleAfter) {
      // Paint the retained snapshot first. JSON parsing and image URL updates
      // then land as one transaction instead of competing with the foreground
      // transition and producing several visibly different grids.
      _cancelPendingResumeRefresh();
      _resumeRefreshTimer = Timer(const Duration(milliseconds: 450), () {
        _resumeRefreshTimer = null;
        unawaited(_fullRefreshRooms(showLoading: true, emitFinish: false, bypassFailureCooldown: true));
      });
    } else {
      // A full refresh may have completed after an earlier resumed event but
      // before its debounce expired. Do not let the older timer run anyway.
      _cancelPendingResumeRefresh();
    }
  }

  void _cancelPendingResumeRefresh() {
    _resumeRefreshTimer?.cancel();
    _resumeRefreshTimer = null;
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
    _cancelPendingResumeRefresh();
    _favoriteSnapshotTimer?.cancel();
    for (final worker in _workers) {
      worker.dispose();
    }
    super.onClose();
  }

  void listenFavorite() {
    if (isClosed) return;
    subscription = EventBus.instance.listen('refresh_favorite_rooms', (data) {
      debounceRefresh();
    });
  }

  void listenRoomChanged() {
    if (isClosed) return;
    roomChangedSubscription = EventBus.instance.listen('refresh_room_changed', (data) {
      applyLocalFilter();
    });
    // 按观看时长排序时，服务端防抖（3s）通知时长变化后重排列表（5.2）。
    // applyLocalFilter 内部有快照比对，顺序未变化时不会触发 UI 重建。
    _watchTimeSubscription = EventBus.instance.listen(WatchTimeService.eventWatchTimeChanged, (data) {
      applyLocalFilter();
    });
  }

  /// 判断用户是否正停留在首页收藏页签（决定后台刷新是否弹遮罩）。
  bool _isUserOnFavoritePage() {
    try {
      final route = Get.isRegistered<RouteObserverController>() ? RouteObserverController.to.currentRoute.value : '';
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
      final hasUntaggedRoom = candidateRooms.any((room) => tagController.getTagsForRoom(room).isEmpty);
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
    if (isClosed) return;
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
      selectedTagIds.assignAll(_pruneSelectedTagsForRooms(candidateRooms));
    }
    _selectionTransaction = false;
    currentPage = 1;
    applyLocalFilter(resyncSource: false);
  }

  void selectStatusIndex(int index) {
    if (isClosed) return;
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
      selectedTagIds.assignAll(_pruneSelectedTagsForRooms(candidateRooms));
    }
    _selectionTransaction = false;
    currentPage = 1;
    applyLocalFilter(resyncSource: false);
  }

  void animateToStatusIndex(int index) {
    if (isClosed) return;
    if (index < 0 || index >= tabController.length) return;
    if (tabController.index == index) {
      selectStatusIndex(index);
      return;
    }
    tabController.animateTo(index, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  void changeSelectedTag(String tagId) {
    if (isClosed) return;
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

  void resetFilters() {
    if (isClosed) return;
    final availableSites = Sites().availableSites(containsAll: true);
    final allSiteId = availableSites.isNotEmpty ? availableSites[0].id : Sites.allSite;
    _selectionTransaction = true;
    tabSiteIndex.value = 0;
    selectedPlatformId = allSiteId;
    tabOnlineIndex.value = 1;
    if (tabController.index != 1 && tabController.length > 1) {
      tabController.animateTo(1, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    }
    selectedTagIds.assignAll({TagManagementController.allTagKey});
    searchKeyword.value = '';
    currentPage = 1;
    _selectionTransaction = false;
    applyLocalFilter(resyncSource: false);
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

    // 标签多选并集语义（5.5）；"未分组"是虚拟标签（getTagsForRoom 永远
    // 不会返回该 key），需要按"房间没有任何标签"判断，否则选中未分组时
    // 刷新范围为空集。
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
        // "全部"页签（5.3）：三个状态桶合并展示。
        final merged = <LiveRoom>[...onlineRooms, ...replayRooms, ...offlineRooms];
        // 观看时长排序在"全部"页签跨状态统一排序，而不是按桶序拼接（5.2）。
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
    if (isClosed) return;
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
          final ids = tagController.getTagsForRoom(room);
          tagIds.addAll(ids);
        }
      }

      nextVisibleTags = tagController.tags.where((t) => tagIds.contains(t.id)).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
    }

    nextOnline.sort(_compareOnlineRooms);
    if (onlineSortMode.value == OnlineSortMode.watchTime) {
      // 观看时长排序对所有状态生效：三个桶按同一规则排序（5.2）。
      nextReplay.sort(_compareOnlineRooms);
      nextOffline.sort(_compareOnlineRooms);
    } else {
      nextReplay.sort(_compareAudience);
    }

    // Build and sort plain lists first, then publish each result once. The old
    // clear/addAll/sort sequence notified every Obx grid several times for one
    // background refresh, causing visible hitches with many favourites.
    _assignIfSnapshotChanged(onlineRooms, nextOnline);
    _assignIfSnapshotChanged(offlineRooms, nextOffline);
    _assignIfSnapshotChanged(replayRooms, nextReplay);
    _assignIfSnapshotChanged(visibleTags, nextVisibleTags);
  }

  bool _isCurrentFavoriteSnapshotSynced() {
    return _lastSyncedFavoriteSnapshot == _favoriteSnapshotSignature(SettingsService.to.fav.favoriteRooms.v);
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
      if (siteId == Sites.allSite || room.normalizedPlatformId == siteId) {
        tagIds.addAll(tagController.getTagsForRoom(room));
      }
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

  /// 收藏页统一排序比较器（5.1/5.2）：
  /// 置顶优先（受开关控制）→ 标签匹配分 → 主排序模式（受升降序控制）。
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
    final aTime = a.startTime;
    final bTime = b.startTime;
    if (aTime != null && bTime != null) return bTime.compareTo(aTime);
    if (aTime != null) return -1; // 有开播时间的排前面
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

  /// 收藏页搜索（5.4）：多关键字空格分隔 OR 匹配，
  /// 范围 = 标题 / 昵称 / 房间号 / 标签名。
  bool _matchesSearchKeyword(LiveRoom room) {
    final raw = searchKeyword.value.trim();
    if (raw.isEmpty) return true;

    final keywords = raw.split(RegExp(r'\s+')).map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList();
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

  /// "无标签"虚拟标签计数徽章（5.5）：按当前页签与平台统计无标签房间数。
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
    if (isClosed) return;
    if (!resyncSource) _refreshVisibleTagsFromSyncedRooms();
    final filtered = getFilteredRooms(resyncSource: resyncSource);
    updateLocalReactivePool(filtered);
    _recalculateUntaggedCount();
  }

  @override
  Future<void> refreshData() async {
    if (isClosed) return;
    // Pull-to-refresh is authoritative for this interaction. A resume event
    // queued just before the gesture must not follow it with another pass.
    _cancelPendingResumeRefresh();
    final startup = _startupRefresh;
    if (startup != null) {
      // BasePageView performs a one-time mobile/desktop layout notification.
      // Coalesce that request with the cold-start verification instead of
      // incrementing _refreshEpoch and cancelling the authoritative refresh.
      await startup;
      return;
    }
    currentPage = 1;
    // 刷新屏蔽层（5.9-(3)）：遮罩范围由 _fullRefreshFilterRooms 按
    // "全部平台+全部标签+无搜索" 判定为 all，否则 filtered（对齐开发版）。
    cancelRequested.value = false;
    showRefreshShield.value = true;
    await _fullRefreshFilterRooms(showLoading: true, bypassFailureCooldown: true);
  }

  Future<void> _fullRefreshFilterRooms({required bool showLoading, bool bypassFailureCooldown = false}) async {
    if (isClosed) return;
    // 全部平台 + 全部标签 + 无搜索 = 筛选是 no-op，刷新范围就是全部收藏，
    // 遮罩语义保持"全部"而不是误导性的"当前筛选"（对齐开发版）。
    final sites = Sites().availableSites(containsAll: true);
    final isUnfiltered =
        tabSiteIndex.value >= 0 &&
        tabSiteIndex.value < sites.length &&
        sites[tabSiteIndex.value].id == Sites.allSite &&
        selectedTagIds.contains(TagManagementController.allTagKey) &&
        searchKeyword.value.trim().isEmpty;
    refreshShieldScope.value = isUnfiltered ? FavoriteRefreshScope.all : FavoriteRefreshScope.filtered;
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
    if (isClosed) return;
    _cancelPendingResumeRefresh();
    final startup = _startupRefresh;
    if (startup != null) {
      // Cold-start verification already covers every favourite. Coalescing
      // lifecycle/timer events here prevents a second refresh from invalidating
      // the authoritative startup result halfway through its network pass.
      await startup;
      return;
    }
    final roomsToRefresh = getAllRooms();
    // 刷新屏蔽层（5.9-(3)）：全量刷新仅当用户停留在收藏页时展示遮罩，
    // 后台自动刷新/防抖刷新不打扰其他页面。
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
    if (isClosed) return Future<void>.value();
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
    // 刷新屏蔽层（5.9-(3)）：启动核验文案由遮罩的 isVerifyingFavorites 分支显示。
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
        ownsRefreshShield: false,
      );
      await _refreshHistoryAfterStartupVerification();
    } finally {
      _verificationPreview = null;
      if (!isClosed) {
        isVerifyingFavorites.value = false;
        showRefreshShield.value = false;
        loadding.value = false;
        applyLocalFilter();
      }
    }
  }

  Future<void> _runRoomRefresh(
    List<LiveRoom> rooms, {
    required bool showLoading,
    bool emitFinish = true,
    bool markFullRefresh = false,
    bool invalidateUnverified = false,
    bool bypassFailureCooldown = false,
    bool ownsRefreshShield = true,
  }) {
    if (isClosed) return Future<void>.value();
    final completion = Completer<void>();
    final operation = completion.future;
    // The latest queued pass includes the lock wait as well as its own work.
    // An older completion must not clear ownership of a newer queued pass.
    _activeRoomRefresh = operation;
    // One refresh owns the snapshot transaction at a time. The former epoch
    // scheme cancelled whichever pass happened to finish second; a lifecycle
    // resume 450 ms after launch could therefore discard startup verification
    // and leave failed rooms with yesterday's live bit.
    final pending = _refreshLock.synchronized<void>(() async {
      if (isClosed) return;
      final refreshEpoch = _refreshEpoch;
      if (ownsRefreshShield && showLoading) loadding.value = true;
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
          SettingsService.to.fav.favoriteRooms.v = merged.rooms;
        }
        if (markFullRefresh) {
          lastFullRefreshAt.value = _now();
          _cancelPendingResumeRefresh();
        }
        applyLocalFilter();
        if (emitFinish) EventBus.instance.emit('refresh_favorite_finish', true);
      } finally {
        if (ownsRefreshShield) {
          showRefreshShield.value = false;
          cancelRequested.value = false;
          if (showLoading && refreshEpoch == _refreshEpoch && !isClosed) {
            loadding.value = false;
          }
        }
      }
    });
    unawaited(
      pending.then(
        (_) {
          if (identical(_activeRoomRefresh, operation)) _activeRoomRefresh = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_activeRoomRefresh, operation)) _activeRoomRefresh = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return operation;
  }

  Future<Map<String, LiveRoom>> _refreshRoomDetails(
    List<LiveRoom> rooms, {
    required int refreshEpoch,
    required bool bypassFailureCooldown,
  }) async {
    final enabledPlatforms = Sites().availableSites().map((site) => site.id.trim().toLowerCase()).toSet();
    final valid = rooms
        .where(
          (r) =>
              (r.platform?.isNotEmpty ?? false) &&
              (r.roomId?.isNotEmpty ?? false) &&
              enabledPlatforms.contains(r.normalizedPlatformId),
        )
        .toList(growable: false);
    if (valid.isEmpty) return const <String, LiveRoom>{};

    final groups = <String, List<LiveRoom>>{};
    for (final room in valid) {
      groups.putIfAbsent(room.normalizedPlatformId, () => []).add(room);
    }

    final siteCache = <String, LiveSite>{};
    final groupResults = await Future.wait(
      groups.entries.map((entry) {
        return boundedAsyncMap<LiveRoom, ({String key, LiveRoom room})>(
          entry.value,
          maxConcurrent: refreshConfigController.platformConcurrencyOf(entry.key),
          task: (room) async {
            final updated = await _refreshOneRoom(room, siteCache, bypassFailureCooldown: bypassFailureCooldown);
            if (updated == null) return null;
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
    final now = _now();
    final failedAt = _refreshFailureCooldown[key];
    if (!bypassFailureCooldown && failedAt != null && now.difference(failedAt) < _refreshFailureRetryAfter) {
      return null;
    }
    final succeededAt = _refreshSuccessCooldown[key];
    if (succeededAt != null && now.difference(succeededAt) < _refreshSuccessInterval) {
      // 成功保护期内数据仍然新鲜：返回当前房间而不是 null。返回 null 会被
      // 权威合并视为"未验证"而整体失效化，连续短时间两次刷新就会把内容
      // 清空——开发版特意做过此处理。
      return room;
    }

    try {
      final platform = room.normalizedPlatformId;
      final roomId = room.normalizedRoomId;
      final liveSite = siteCache.putIfAbsent(platform, () => createRoomRefreshSite(platform));
      final operation = liveSite is LiveSiteRoomRefresher
          ? (liveSite as LiveSiteRoomRefresher).getRoomDetailForRefresh(roomId: roomId, platform: platform)
          : liveSite.getRoomDetail(roomId: roomId, platform: platform);
      final result = await operation.timeout(_roomRefreshTimeout);
      if (isClosed) return null;
      _refreshFailureCooldown.remove(key);
      _refreshSuccessCooldown[key] = _now();
      return result;
    } catch (error, stackTrace) {
      if (isClosed) return null;
      _refreshFailureCooldown[key] = _now();
      _refreshSuccessCooldown.remove(key);

      if (error is FormatException && error.message == 'Huya room metadata is unavailable') {
        developer.log('Favorite room unavailable: $key', name: 'FavoriteController');
      } else if (error is TimeoutException) {
        developer.log('Favorite room refresh timeout: $key', name: 'FavoriteController', error: error);
      } else {
        developer.log(
          'Favorite room refresh failed: $key',
          name: 'FavoriteController',
          error: error,
          stackTrace: stackTrace,
        );
      }

      return null;
    }
  }

  Future<void> _refreshHistoryAfterStartupVerification() async {
    try {
      if (isClosed) return;
      final history = SettingsService.to.history;
      final limited = applyHistoryLimit(history.historyRooms.v, history.historyLimit.v);
      if (limited.isEmpty) return;

      final favMap = {for (final room in SettingsService.to.fav.favoriteRooms.v) room.identityKey: room};
      final settled = <int, LiveRoom>{};
      final pending = <LiveRoom>[];
      for (var index = 0; index < limited.length; index++) {
        final room = limited[index];
        final fav = favMap[room.identityKey];
        if (fav != null && fav.effectiveLiveStatus != LiveStatus.unknown) {
          settled[index] = preserveHistoryMetadata(fav, room);
        } else {
          pending.add(room);
        }
      }

      final Map<String, LiveRoom> byIdentity;
      if (pending.isEmpty) {
        byIdentity = {};
      } else {
        final capturedEpoch = _refreshEpoch;
        final result = await history.refreshRoomDetails(
          pending,
          shouldCancel: () => isClosed || _refreshEpoch != capturedEpoch,
        );
        if (result == null || isClosed) return;
        byIdentity = {for (final r in result.rooms) r.identityKey: r};
      }

      final current = history.historyRooms.v;
      var changed = false;
      final next = <LiveRoom>[
        for (final room in current)
          byIdentity.containsKey(room.identityKey)
              ? preserveHistoryMetadata(byIdentity[room.identityKey]!, room)
              : room,
      ];
      for (final entry in settled.entries) {
        if (entry.key < next.length && next[entry.key].identityKey == limited[entry.key].identityKey) {
          if (next[entry.key] != entry.value) {
            changed = true;
          }
          next[entry.key] = entry.value;
        }
      }
      if (!changed) {
        for (var i = 0; i < current.length && i < next.length; i++) {
          if (current[i] != next[i]) {
            changed = true;
            break;
          }
        }
      }
      if (changed && !isClosed) {
        history.historyRooms.v = next;
      }
    } catch (_) {}
  }

  String _roomKey(LiveRoom room) => favoriteRoomIdentity(room);

  /// 取分区字段的主分类（第一段），如"网游/英雄联盟"→"网游"。
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

  /// 5.6 一键匹配分类标签：扫描关注列表所有房间，按主分类自动建标签并绑定。
  /// 与开发版差异：建标签使用基础版的 ensureTagByNameSafe（保留名安全返回 null，
  /// 匹配到保留名的主分类会被跳过而不是强制建标签）。
  Future<({int totalRooms, int noAreaRooms, int successRooms, int skippedExistingTag, int createdTags})>
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
      final tag = tagController.ensureTagByNameSafe(name);
      if (tag == null) continue; // 保留名/空名安全跳过
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
        await tagController.setRoomTags(room, existingIds);
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
