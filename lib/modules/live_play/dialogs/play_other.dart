import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:pure_live/common/services/settings/panel_size_controller.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/plugins/cache_manager.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/content_first_panel_layout.dart';
import 'package:pure_live/modules/live_play/widgets/layout/panel_popup_scope.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

/// 6.5 可复用换台面板（已开播/观看记录两页签）：可嵌入播放页侧栏页签，
/// 也可由 [PlayOther] 包成右侧对话框。
/// 与开发版完全对齐：不再包含录播页签。
class PlayOtherPanel extends StatefulWidget {
  const PlayOtherPanel({
    required this.controller,
    required this.onSelectRoom,
    super.key,
    this.showHeader = true,
    this.showCloseButton = true,
    this.isPersistent = false,
  });

  final LivePlayController controller;
  final void Function(LiveRoom room) onSelectRoom;
  final bool showHeader;
  final bool showCloseButton;
  final bool isPersistent;

  static Widget buildDialog(BuildContext context, LivePlayController controller) {
    final layout = resolveContentFirstPanelLayout(MediaQuery.sizeOf(context), ContentFirstPanelKind.roomHistory);
    return Dialog(
      key: const ValueKey('fullscreen-room-history-dialog'),
      alignment: Alignment.centerRight,
      insetPadding: layout.insetPadding,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: layout.size.width.clamp(200, 400),
        height: layout.size.height,
        child: PlayOtherPanel(
          controller: controller,
          showHeader: true,
          showCloseButton: true,
          isPersistent: false,
          onSelectRoom: (room) {
            Navigator.of(context).pop();
            controller.switchRoom(room);
          },
        ),
      ),
    );
  }

  @override
  State<PlayOtherPanel> createState() => _PlayOtherPanelState();
}

class _PlayOtherPanelState extends State<PlayOtherPanel> with SingleTickerProviderStateMixin {
  late final TabController tabController;
  final onlineRooms = <LiveRoom>[].obs;
  final historyRooms = <LiveRoom>[].obs;
  final loadingFinish = false.obs;
  final refreshing = false.obs;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<Worker> _workers = [];

  final _onlineRefreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);
  final _historyRefreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);

  // 6.5-(2) 平台/标签筛选；6.5-(6) isPersistent 时与 controller 侧栏状态互相同步。
  String _platformFilter = TagManagementController.allTagKey;
  String _tagFilter = TagManagementController.allTagKey;

  List<LiveRoom> get _filteredOnlineRooms => _applyFilters(onlineRooms);
  List<LiveRoom> get _filteredHistoryRooms => _applyFilters(historyRooms);

  List<LiveRoom> _applyFilters(List<LiveRoom> source) {
    final tagController = Get.find<TagManagementController>();
    return source.where((room) {
      if (_platformFilter != TagManagementController.allTagKey) {
        if (room.normalizedPlatformId != _platformFilter) return false;
      }
      if (_tagFilter != TagManagementController.allTagKey) {
        final tagIds = tagController.getTagsForRoom(room);
        if (!tagIds.contains(_tagFilter)) return false;
      }
      return true;
    }).toList();
  }

  List<({String id, String label})> _platformFilterOptions() {
    final siteById = {for (final s in Sites.supportSites) s.id: s};
    final ids = onlineRooms.map((r) => r.normalizedPlatformId).toSet()..removeWhere((id) => !siteById.containsKey(id));
    final result = <({String id, String label})>[
      (id: TagManagementController.allTagKey, label: TagManagementController.allTagLabel),
    ];
    for (final id in ids) {
      final site = siteById[id]!;
      result.add((id: id, label: site.name));
    }
    return result;
  }

  List<({String id, String label})> _tagFilterOptions() {
    final tagController = Get.find<TagManagementController>();
    final tagIds = <String>{};
    for (final room in onlineRooms) {
      tagIds.addAll(tagController.getTagsForRoom(room));
    }
    final tags = tagController.tags.where((t) => tagIds.contains(t.id)).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final result = <({String id, String label})>[
      (id: TagManagementController.allTagKey, label: TagManagementController.allTagLabel),
    ];
    for (final tag in tags) {
      result.add((id: tag.id, label: tag.name));
    }
    return result;
  }

  @override
  void initState() {
    super.initState();

    tabController = TabController(length: 2, vsync: this, animationDuration: pureLiveTabTransitionDuration);

    // 6.5-(6) 持久面板：恢复上次的页签与筛选，并实时写回。
    if (widget.isPersistent) {
      tabController.index = widget.controller.sidePanelTabIndex.clamp(0, 1);
      _platformFilter = widget.controller.sidePanelPlatformFilter;
      _tagFilter = widget.controller.sidePanelTagFilter;
      tabController.addListener(_onTabChanged);
    }

    _updateRooms();
    _subscriptions.add(EventBus.instance.listen('refresh_favorite_finish', (_) => _updateRooms()));
    _subscriptions.add(EventBus.instance.listen('refresh_room_changed', (_) => _updateRooms()));
    _subscriptions.add(EventBus.instance.listen('history_changed', (_) => _updateRooms()));

    // 6.5-(4) 排序/置顶状态跟随关注页（FavoriteController 未注册时静默回退）。
    try {
      final fav = Get.find<FavoriteController>();
      _workers.add(ever(fav.enablePinned, (_) => _updateRooms()));
      _workers.add(ever(fav.onlineSortMode, (_) => _updateRooms()));
    } catch (_) {}
  }

  void _onTabChanged() {
    if (widget.isPersistent && !tabController.indexIsChanging) {
      widget.controller.sidePanelTabIndex = tabController.index;
    }
  }

  void _updateRooms() {
    final allRooms = SettingsService.to.fav.favoriteRooms.v;

    final liveList = allRooms.where((room) => room.isLiveNow && room.isRecord == false).toList()
      ..sort(_compareOnlineRooms);
    onlineRooms.assignAll(liveList);

    final favMap = {for (final fav in allRooms) fav.identityKey: fav};
    final syncedHistory = SettingsService.to.history.historyRooms.v.map((room) {
      final fav = favMap[room.identityKey];
      if (fav != null) {
        return preserveHistoryMetadata(fav, room);
      }
      return room;
    }).toList();
    historyRooms.assignAll(syncedHistory.where((room) => room.isLiveNow).toList());

    // 6.5-(2) 自愈：当前选中项不在选项集中（标签被删、平台下线）时回退"全部"。
    if (!_platformFilterOptions().any((o) => o.id == _platformFilter)) {
      _platformFilter = TagManagementController.allTagKey;
    }
    if (!_tagFilterOptions().any((o) => o.id == _tagFilter)) {
      _tagFilter = TagManagementController.allTagKey;
    }

    loadingFinish.value = true;
    refreshing.value = false;
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n('clear_history')),
        content: Text(i18n('clear_history_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(i18n('cancel'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(i18n('confirm'))),
        ],
      ),
    );
    if (confirmed == true) {
      SettingsService.to.history.clearHistory();
      _updateRooms();
    }
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

  // 6.5-(4) 排序复用关注页策略：置顶优先 → 主排序（三模式）→ 升降序翻转。
  OnlineSortMode _sortMode() {
    try {
      return Get.find<FavoriteController>().onlineSortMode.value;
    } catch (_) {
      return OnlineSortMode.audience;
    }
  }

  bool _ascendingEnabled() {
    try {
      return Get.find<FavoriteController>().onlineSortAscending.value;
    } catch (_) {
      return false;
    }
  }

  bool _pinnedEnabled() {
    try {
      return Get.find<FavoriteController>().enablePinned.value;
    } catch (_) {
      return true;
    }
  }

  int _compareStartTime(LiveRoom a, LiveRoom b) {
    final aTime = a.startTime;
    final bTime = b.startTime;
    if (aTime != null && bTime != null) return bTime.compareTo(aTime);
    if (aTime != null) return -1;
    if (bTime != null) return 1;
    return _compareAudience(a, b);
  }

  int _compareWatchTime(LiveRoom a, LiveRoom b) {
    final aSeconds = WatchTimeService.secondsFor(a.identityKey);
    final bSeconds = WatchTimeService.secondsFor(b.identityKey);
    if (aSeconds != bSeconds) return bSeconds.compareTo(aSeconds);
    return _compareAudience(a, b);
  }

  int _compareOnlineRooms(LiveRoom a, LiveRoom b) {
    final tagController = Get.find<TagManagementController>();
    if (_pinnedEnabled()) {
      final aPinned = tagController.isPinRoom(a);
      final bPinned = tagController.isPinRoom(b);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
    }
    final primary = switch (_sortMode()) {
      OnlineSortMode.startTime => _compareStartTime(a, b),
      OnlineSortMode.watchTime => _compareWatchTime(a, b),
      _ => _compareAudience(a, b),
    };
    return _ascendingEnabled() ? -primary : primary;
  }

  String _resolveFilterLabel(String selectedId, List<({String id, String label})> options) {
    for (final opt in options) {
      if (opt.id == selectedId) return opt.label;
    }
    return TagManagementController.allTagLabel;
  }

  Future<void> _refreshOnline() async {
    refreshing.value = true;
    EventBus.instance.emit('refresh_favorite_rooms', true);
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    _onlineRefreshController.finishRefresh(IndicatorResult.success);
    _onlineRefreshController.resetFooter();
    refreshing.value = false;
  }

  Future<void> _refreshHistory() async {
    final history = SettingsService.to.history;
    final list = applyHistoryLimit(history.historyRooms.v, history.historyLimit.v);
    final result = await history.refreshRoomDetails(list, shouldCancel: () => !mounted);
    if (!mounted || result == null) return;
    // 基础版差异：开发版此处直接 historyRooms.v = result.rooms，会在刷新期间
    // 复活被用户清空的条目；沿用基础版 6.3 的快照安全合并（identity 映射替换）。
    history.applyRefreshedRooms(list, result.rooms);
    _updateRooms();
    if (result.allSuccess) {
      _historyRefreshController.finishRefresh(IndicatorResult.success);
      _historyRefreshController.resetFooter();
    } else {
      _historyRefreshController.finishRefresh(IndicatorResult.fail);
    }
  }

  @override
  void dispose() {
    tabController.dispose();
    _onlineRefreshController.dispose();
    _historyRefreshController.dispose();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (widget.showHeader)
          SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Icon(Icons.video_library_rounded, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      i18n('switch_live_room'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.isPersistent)
                    IconButton(
                      tooltip: i18n('reset'),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        tabController.index = 0;
                        _platformFilter = TagManagementController.allTagKey;
                        _tagFilter = TagManagementController.allTagKey;
                        widget.controller.sidePanelTabIndex = 0;
                        widget.controller.sidePanelPlatformFilter = TagManagementController.allTagKey;
                        widget.controller.sidePanelTagFilter = TagManagementController.allTagKey;
                        setState(() {});
                      },
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    ),
                  // 布局切换按钮：封面卡片网格 ↔ 紧凑列表（与关注页一致，偏好持久化）。
                  Obx(() {
                    final isCompact = PanelSizeController.to.isRoomSwitchCompact;
                    return IconButton(
                      tooltip: isCompact ? '切换为卡片布局' : '切换为列表布局',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                      padding: EdgeInsets.zero,
                      onPressed: PanelSizeController.to.toggleRoomSwitchLayout,
                      icon: Icon(isCompact ? Icons.grid_view_rounded : Icons.view_list_rounded, size: 18),
                    );
                  }),
                  Obx(
                    () => IconButton(
                      tooltip: i18n('refresh'),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                      padding: EdgeInsets.zero,
                      onPressed: refreshing.value
                          ? null
                          : () {
                              refreshing.value = true;
                              EventBus.instance.emit('refresh_favorite_rooms', true);
                              _refreshHistory().whenComplete(() {
                                if (mounted) refreshing.value = false;
                              });
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                  ),
                  Obx(
                    () => IconButton(
                      tooltip: i18n('clear_history'),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                      padding: EdgeInsets.zero,
                      onPressed: historyRooms.isEmpty ? null : () => _confirmClearHistory(context),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    ),
                  ),
                  if (widget.showCloseButton)
                    IconButton(
                      tooltip: i18n('close'),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ),
          ),
        SizedBox(
          height: 38,
          child: Row(
            children: [
              Listener(
                onPointerSignal: (event) {
                  if (event is! PointerScrollEvent) return;
                  if (tabController.length == 0) return;
                  final dir = event.scrollDelta.dy > 0 ? 1 : -1;
                  final next = (tabController.index + dir) % tabController.length;
                  tabController.animateTo(next);
                },
                child: TabBar(
                  controller: tabController,
                  physics: const PureLiveBoundedScrollPhysics(),
                  tabAlignment: TabAlignment.start,
                  labelColor: theme.colorScheme.primary,
                  unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 0,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10),
                  tabs: [
                    _CompactTab(icon: Icons.sensors_rounded, label: i18n('online_room_title')),
                    _CompactTab(icon: Icons.history_rounded, label: i18n('watch_history')),
                  ],
                ),
              ),
              const Spacer(),
              Obx(
                () => _FilterDropdown(
                  currentLabel: _resolveFilterLabel(_platformFilter, _platformFilterOptions()),
                  options: _platformFilterOptions(),
                  onSelect: (id) {
                    setState(() => _platformFilter = id);
                    if (widget.isPersistent) {
                      widget.controller.sidePanelPlatformFilter = id;
                    }
                  },
                ),
              ),
              const SizedBox(width: 4),
              Obx(
                () => _FilterDropdown(
                  currentLabel: _resolveFilterLabel(_tagFilter, _tagFilterOptions()),
                  options: _tagFilterOptions(),
                  onSelect: (id) {
                    setState(() => _tagFilter = id);
                    if (widget.isPersistent) {
                      widget.controller.sidePanelTagFilter = id;
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              Obx(
                () => loadingFinish.value
                    ? TabBarView(
                        controller: tabController,
                        physics: const PureLiveBoundedScrollPhysics(),
                        children: [
                          _buildRoomGrid(_filteredOnlineRooms, history: false),
                          _buildRoomGrid(_filteredHistoryRooms, history: true),
                        ],
                      )
                    : const AppStatusView(type: AppStatusType.loading, title: '', subtitle: ''),
              ),
              Obx(
                () => refreshing.value
                    ? const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRoomGrid(List<LiveRoom> rooms, {required bool history}) {
    final refreshController = history ? _historyRefreshController : _onlineRefreshController;
    final onRefresh = history ? _refreshHistory : _refreshOnline;
    // 在外层 Obx 构建期读取布局模式：点击头部按钮时整个网格自动重建。
    final isCompact = PanelSizeController.to.isRoomSwitchCompact;
    return EasyRefresh(
      controller: refreshController,
      onRefresh: onRefresh,
      onLoad: () => refreshController.finishLoad(IndicatorResult.noMore),
      child: rooms.isEmpty
          ? const CustomScrollView(
              slivers: [SliverFillRemaining(hasScrollBody: false, child: AppStatusView(type: AppStatusType.empty))],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                const padding = 6.0;
                const spacing = 4.0;
                final availableWidth = constraints.maxWidth - padding * 2;
                // 紧凑列表：宽度够时可多列（每列下限约 280px，与关注页一致）。
                // 标准卡片：卡片最大宽度 280px，随侧栏宽度自动增加列数。
                const maxStandardCardWidth = 160.0;
                final columns = isCompact
                    ? (availableWidth >= 1000 ? 4 : (availableWidth >= 700 ? 3 : (availableWidth >= 400 ? 2 : 1)))
                    : (availableWidth + spacing) ~/ (maxStandardCardWidth + spacing).clamp(1, 1 << 31);
                final effectiveColumns = columns.clamp(1, 5);
                final double cardHeight;
                if (isCompact) {
                  cardHeight = _RoomSwitchCard.compactHeight;
                } else {
                  final cardWidth = (availableWidth - spacing * (effectiveColumns - 1)) / effectiveColumns;
                  cardHeight = (cardWidth * 7 / 16 + 48.0).clamp(118.0, 320.0);
                }
                // 鼠标拖拽滚动依赖全局 MyCustomScrollBehavior 的 dragDevices（已含 mouse），
                // 与开发版一致不覆写 physics。
                return GridView.builder(
                  key: ValueKey(
                    '${history ? 'watch-history' : 'live-room'}-grid-${isCompact ? 'compact' : 'standard'}',
                  ),
                  padding: const EdgeInsets.all(padding),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: effectiveColumns,
                    mainAxisExtent: cardHeight,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                  ),
                  itemCount: rooms.length,
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    return _RoomSwitchCard(
                      room: room,
                      history: history,
                      compact: isCompact,
                      onTap: () => widget.onSelectRoom(room),
                      onRemoveFromHistory: history
                          ? () {
                              SettingsService.to.history.removeRoomFromHistory(room);
                              _updateRooms();
                            }
                          : null,
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 兼容壳：既有调用点（Get.dialog(PlayOther(...))）不需要改动。
class PlayOther extends StatelessWidget {
  const PlayOther({required this.controller, super.key});
  final LivePlayController controller;

  @override
  Widget build(BuildContext context) {
    return PlayOtherPanel.buildDialog(context, controller);
  }
}

class _CompactTab extends StatelessWidget {
  const _CompactTab({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 36,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// 6.5-(2) 面板筛选下拉：Overlay 弹层；弹层打开期间通知 PanelPopupScope
/// 挂起悬浮面板自动隐藏，保持指针同步。
class _FilterDropdown extends StatefulWidget {
  const _FilterDropdown({required this.currentLabel, required this.options, required this.onSelect});

  final String currentLabel;
  final List<({String id, String label})> options;
  final ValueChanged<String> onSelect;

  @override
  State<_FilterDropdown> createState() => _FilterDropdownState();
}

class _FilterDropdownState extends State<_FilterDropdown> {
  static const double _kTriggerWidth = 80;
  static const double _kPopupMaxHeight = 260;

  bool _open = false;
  OverlayEntry? _entry;
  PanelPopupScopeState? _popupScope;

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _openMenu();
    }
  }

  void _close() {
    if (_entry != null) {
      _entry!.remove();
      _entry = null;
      // Report only on the balanced close so the panel auto-hide gate stays
      // in sync with the popup lifetime.
      _popupScope?.notifyPopupClosed();
      _popupScope = null;
    }
    if (mounted) setState(() => _open = false);
  }

  void _openMenu() {
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox;
    final renderBox = context.findRenderObject() as RenderBox;
    final triggerSize = renderBox.size;
    final triggerPos = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    _entry = OverlayEntry(
      builder: (overlayContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _close),
            ),
            Positioned(
              left: triggerPos.dx,
              top: triggerPos.dy + triggerSize.height + 4,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: _kTriggerWidth,
                  constraints: const BoxConstraints(maxHeight: _kPopupMaxHeight),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: widget.options.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, thickness: 0.5),
                    itemBuilder: (_, index) {
                      final opt = widget.options[index];
                      final isSelected = opt.label == widget.currentLabel;
                      return Tooltip(
                        message: opt.label,
                        waitDuration: const Duration(milliseconds: 400),
                        child: InkWell(
                          onTap: () {
                            _close();
                            widget.onSelect(opt.id);
                          },
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    opt.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurface,
                                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Icon(Icons.check_rounded, size: 16, color: colors.primary),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    // Suspend the floating panel auto-hide while the menu holds the pointer.
    // The scope is captured eagerly so dispose-time close does not need an
    // inherited lookup.
    _popupScope = PanelPopupScope.maybeOf(context);
    _popupScope?.notifyPopupOpened();

    overlay.insert(_entry!);
    setState(() => _open = true);
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final options = widget.options;
        if (options.isEmpty) return;
        final curIdx = options.indexWhere((o) => o.label == widget.currentLabel);
        final dir = event.scrollDelta.dy > 0 ? 1 : -1;
        final base = curIdx >= 0 ? curIdx : 0;
        final next = (base + dir) % options.length;
        widget.onSelect(options[next].id);
      },
      child: Tooltip(
        message: widget.currentLabel,
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _kTriggerWidth,
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: (_open
                  ? colors.primaryContainer.withValues(alpha: 0.55)
                  : colors.surfaceContainerHighest.withValues(alpha: 0.45)),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _open ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.4),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Text(
                    widget.currentLabel,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _open ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoomSwitchCard extends StatelessWidget {
  const _RoomSwitchCard({
    required this.room,
    required this.history,
    required this.compact,
    required this.onTap,
    this.onRemoveFromHistory,
  });

  /// 紧凑列表布局下的固定卡片高度（大头像 + 两行文字）。
  static const double compactHeight = 54.0;

  final LiveRoom room;
  final bool history;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback? onRemoveFromHistory;

  String _historyLabel() {
    final value = room.lastWatchedAt;

    if (value == null || value <= 0) {
      return i18n('history_earlier');
    }

    return i18n('watched_at', args: {'time': formatHistoryWatchedAt(value)});
  }

  // 基础版差异：开发版此处读取 roomCardConfig 的 mobileShowDelete/desktopShowDelete
  // 配置项；基础版房间卡片配置无"删除按钮"显示项（与历史页 showDelete: true 约定一致），
  // 故不做配置门控，历史卡片有移除回调即显示。
  bool get _effectiveShowDelete => history && onRemoveFromHistory != null;

  // 置顶徽章跟随关注页规则：enablePinned 开启且房间被判定为置顶。
  bool get _isPinned {
    if (history) return false;
    final tagController = Get.find<TagManagementController>();
    try {
      final favController = Get.find<FavoriteController>();
      return favController.enablePinned.value && tagController.isPinRoom(room);
    } catch (_) {
      return tagController.isPinRoom(room);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final audience = room.audienceValue(
      preferRealOnline: SettingsService.to.app.preferRealOnlineCounts.v,
      platformEnabled: SettingsService.to.app.isRealOnlineEnabledFor(room.platform),
    );
    final title = room.title?.trim().isNotEmpty == true ? room.title! : i18n('untitled_room');
    final nick = room.nick?.trim() ?? '';
    final meta = history
        ? _historyLabel()
        : audience.isEmpty
        ? i18n('audience_unknown')
        : readableCount(audience);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => RoomCard.showRoomInfoDialog(context, room),
        onSecondaryTap: () => RoomCard.showRoomInfoDialog(context, room),
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: compact
                ? _buildCompactLayout(context, title, nick, meta)
                : _buildLargeLayout(context, title, nick, meta),
          ),
        ),
      ),
    );
  }

  Widget _buildLargeLayout(BuildContext context, String title, String nick, String meta) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      children: [
        Expanded(
          child: _RoomSwitchCover(
            room: room,
            meta: meta,
            isPinned: _isPinned,
            showDelete: _effectiveShowDelete,
            onDelete: onRemoveFromHistory,
          ),
        ),
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 5, 7, 5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: title,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.person_outline_rounded, size: 12, color: colors.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Tooltip(
                        message: nick.isEmpty ? i18n('unknown') : nick,
                        waitDuration: const Duration(milliseconds: 400),
                        child: Text(
                          nick.isEmpty ? i18n('unknown') : nick,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant, height: 1.1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 15, color: colors.onSurfaceVariant),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 紧凑列表行：左侧大头像，中间两行文字，右侧徽章列。
  /// 在线 tab：中间主播名 + 直播间标题，右侧 pin 徽章 + 平台胶囊 / 橙色人气；
  /// 历史 tab：中间主播名 + 观看时间（不显示标题），右侧平台徽章居上、
  /// 删除按钮居下，两者靠右对齐。
  /// 所有文本统一渐隐截断（TextOverflow.fade）。不受房间卡片设置控制，样式固定。
  Widget _buildCompactLayout(BuildContext context, String title, String nick, String meta) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final nickText = nick.isEmpty ? i18n('unknown') : nick;
    final showPin = _isPinned && !history;
    final showPlatform = room.platform != null;

    // 中间第二行：历史 tab 显示观看时间（替代标题），在线 tab 显示直播间标题。
    final Widget secondLine = history
        ? Tooltip(
            message: meta,
            waitDuration: const Duration(milliseconds: 400),
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.1),
            ),
          )
        : Tooltip(
            message: title,
            waitDuration: const Duration(milliseconds: 400),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: theme.textTheme.bodyMedium?.copyWith(fontSize: 10, color: colors.onSurfaceVariant, height: 1.1),
            ),
          );

    // 在线 tab 右侧上行徽章：pin（仅在线可置顶）+ 平台胶囊。
    final Widget badgesRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showPin) ...[
          Tooltip(
            message: i18n('favorite_pinned_badge'),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(6)),
              child: Icon(RemixIcons.pushpin_fill, color: colors.onPrimary, size: 12),
            ),
          ),
          const SizedBox(width: 4),
        ],
        if (showPlatform) context.buildPlatformTag(room.platform!, mini: true),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          CommonAvatar(avatarUrl: room.avatar, fallbackName: nick, radius: 22),
          const SizedBox(width: 6),
          // 中间两行：主播名 + （历史=观看时间 / 在线=直播间标题），截断时悬浮显示全文。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Tooltip(
                  message: nickText,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    nickText,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                secondLine,
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 右侧：历史 tab 平台徽章居上、删除按钮居下（均靠右对齐）；
          // 在线 tab 上行 pin/平台徽章 + 下行人气。
          if (history)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showPlatform) context.buildPlatformTag(room.platform!, mini: true),
                if (_effectiveShowDelete) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: onRemoveFromHistory,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(RemixIcons.delete_bin_line, size: 14, color: colors.error),
                    ),
                  ),
                ],
              ],
            )
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                badgesRow,
                const SizedBox(height: 6),
                Tooltip(
                  message: meta,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.orange.shade500,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RoomSwitchCover extends StatelessWidget {
  const _RoomSwitchCover({
    required this.room,
    required this.meta,
    this.isPinned = false,
    this.showDelete = false,
    this.onDelete,
  });
  final LiveRoom room;
  final String meta;
  final bool isPinned;
  final bool showDelete;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final url = normalizeNetworkImageUrl(room.cover);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url.isEmpty)
          ColoredBox(
            color: colors.surfaceContainerHighest,
            child: Icon(Icons.live_tv_rounded, size: 34, color: colors.onSurfaceVariant.withValues(alpha: .35)),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final cacheWidth = (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                  .round()
                  .clamp(240, 360)
                  .toInt();
              return CachedNetworkImage(
                imageUrl: url,
                httpHeaders: networkImageHeaders(url),
                cacheManager: CustomImageCacheManager.instance,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                memCacheWidth: cacheWidth,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                useOldImageOnUrlChange: true,
                placeholder: (_, _) {
                  return ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Icon(Icons.live_tv_rounded, color: colors.onSurfaceVariant.withValues(alpha: .25)),
                  );
                },
                errorWidget: (_, _, _) {
                  return ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Icon(Icons.broken_image_outlined, color: colors.onSurfaceVariant.withValues(alpha: .35)),
                  );
                },
              );
            },
          ),
        Positioned(top: 7, right: 7, child: context.buildPlatformTag(room.platform!, mini: true)),
        if (isPinned)
          Positioned(
            top: 7,
            left: 7,
            child: Tooltip(
              message: i18n('favorite_pinned_badge'),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4, offset: const Offset(0, 1)),
                  ],
                ),
                child: Icon(RemixIcons.pushpin_fill, color: colors.onPrimary, size: 16),
              ),
            ),
          ),
        if (showDelete)
          Positioned(
            top: 7,
            left: 7,
            child: GestureDetector(
              onTap: onDelete,
              behavior: HitTestBehavior.opaque,
              child: Tooltip(
                message: i18n('history_remove_room'),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(RemixIcons.delete_bin_line, color: Colors.white, size: 16),
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 22, 8, 8),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            child: Tooltip(
              message: meta,
              waitDuration: const Duration(milliseconds: 400),
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
String formatHistoryWatchedAt(int millisecondsSinceEpoch) {
  final watched = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${watched.year.toString().padLeft(4, '0')}-'
      '${twoDigits(watched.month)}-${twoDigits(watched.day)} '
      '${twoDigits(watched.hour)}:${twoDigits(watched.minute)}';
}
