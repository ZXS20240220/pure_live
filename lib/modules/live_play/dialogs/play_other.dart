import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/plugins/cache_manager.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/content_first_panel_layout.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

/// A reusable panel widget that shows online/recording/history rooms.
/// Can be embedded as a right-side tab or wrapped in a dialog ([PlayOther]).
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
    final layout = resolveContentFirstPanelLayout(
      MediaQuery.sizeOf(context),
      ContentFirstPanelKind.roomHistory,
    );
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

  final _onlineRefreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: true,
  );
  final _historyRefreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: true,
  );

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
    final ids = onlineRooms.map((r) => r.normalizedPlatformId).toSet()
      ..removeWhere((id) => !siteById.containsKey(id));
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

    tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: pureLiveTabTransitionDuration,
    );

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
      ..sort((a, b) => _compareOnlineRooms(a, b));
    onlineRooms.assignAll(liveList);

    final favMap = <String, LiveRoom>{};
    for (final fav in allRooms) {
      favMap[fav.identityKey] = fav;
    }
    final syncedHistory = SettingsService.to.history.historyRooms.v.map((room) {
      final fav = favMap[room.identityKey];
      if (fav != null) {
        return preserveHistoryMetadata(fav, room);
      }
      return room;
    }).toList();
    historyRooms.assignAll(syncedHistory.where((room) => room.isLiveNow).toList());

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

  OnlineSortMode _sortMode() {
    try {
      return Get.find<FavoriteController>().onlineSortMode.value;
    } catch (_) {
      return OnlineSortMode.audience;
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

  int _compareOnlineRooms(LiveRoom a, LiveRoom b) {
    final tagController = Get.find<TagManagementController>();
    if (_pinnedEnabled()) {
      final aPinned = tagController.isPinRoom(a);
      final bPinned = tagController.isPinRoom(b);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
    }
    return switch (_sortMode()) {
      OnlineSortMode.startTime => _compareStartTime(a, b),
      _ => _compareAudience(a, b),
    };
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
    bool result = true;
    final list = List<LiveRoom>.from(SettingsService.to.history.historyRooms.v);
    final concurrency = RefreshConfigController.normalizeMaxConcurrentRefresh(
      SettingsService.to.refreshConfig.maxConcurrentRefresh.v,
    );
    final refreshed = await boundedAsyncMap<LiveRoom, LiveRoom>(
      list,
      maxConcurrent: concurrency,
      task: (room) async {
        final platform = room.platform;
        final roomId = room.roomId;
        if (platform == null || platform.isEmpty || roomId == null || roomId.isEmpty) {
          result = false;
          return room;
        }
        try {
          final newRoom = await Sites.of(platform).liveSite
              .getRoomDetail(roomId: roomId, platform: platform)
              .timeout(const Duration(seconds: 12));
          return preserveHistoryMetadata(newRoom, room);
        } catch (_) {
          result = false;
          return room;
        }
      },
      shouldCancel: () => !mounted,
    );
    if (!mounted) return;
    SettingsService.to.history.historyRooms.v = refreshed.whereType<LiveRoom>().toList(
      growable: true,
    );
    _updateRooms();
    if (result) {
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
    for (final w in _workers) {
      w.dispose();
    }
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
                        widget.controller.sidePanelPlatformFilter =
                            TagManagementController.allTagKey;
                        widget.controller.sidePanelTagFilter = TagManagementController.allTagKey;
                        setState(() {});
                      },
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    ),
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
              TabBar(
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
              const Spacer(),
              Obx(
                () => _FilterDropdown(
                  currentLabel: _resolveFilterLabel(_platformFilter, _platformFilterOptions()),
                  options: _platformFilterOptions(),
                  onSelect: (id) {
                    setState(() {
                      _platformFilter = id;
                    });
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
                    setState(() {
                      _tagFilter = id;
                    });
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
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: Colors.transparent,
                        ),
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
    if (rooms.isEmpty) {
      return const AppStatusView(type: AppStatusType.empty);
    }
    final controller = history ? _historyRefreshController : _onlineRefreshController;
    final onRefresh = history ? _refreshHistory : _refreshOnline;
    return EasyRefresh(
      controller: controller,
      onRefresh: onRefresh,
      onLoad: () => controller.finishLoad(IndicatorResult.noMore),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const padding = 10.0;
          const spacing = 8.0;
          final availableWidth = constraints.maxWidth - padding * 2;
          final isLargeScreen = availableWidth >= 320;
          final columns = isLargeScreen ? 2 : 1;
          late final double cardHeight;
          if (isLargeScreen) {
            final cardWidth = (availableWidth - spacing * (columns - 1)) / columns;
            final coverHeight = cardWidth * 7 / 16;
            const infoHeight = 48.0;
            cardHeight = coverHeight + infoHeight;
          } else {
            cardHeight = 72;
          }
          return GridView.builder(
            key: ValueKey(history ? 'watch-history-grid' : 'live-room-grid'),
            padding: const EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
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
                largeScreen: isLargeScreen,
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

/// Backward-compatible dialog wrapper kept so existing call sites are untouched.
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
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterDropdown extends StatefulWidget {
  const _FilterDropdown({
    required this.currentLabel,
    required this.options,
    required this.onSelect,
  });

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
    }
    if (mounted) setState(() => _open = false);
  }

  void _openMenu() {
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
                                    child: Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                      color: colors.primary,
                                    ),
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
    return Tooltip(
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
              color: _open
                  ? colors.primary.withValues(alpha: 0.5)
                  : colors.outlineVariant.withValues(alpha: 0.4),
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
    );
  }
}

class _RoomSwitchCard extends StatelessWidget {
  const _RoomSwitchCard({
    required this.room,
    required this.history,
    required this.largeScreen,
    required this.onTap,
    this.onRemoveFromHistory,
  });
  final LiveRoom room;
  final bool history;
  final bool largeScreen;
  final VoidCallback onTap;
  final VoidCallback? onRemoveFromHistory;

  String _historyLabel() {
    final value = room.lastWatchedAt;

    if (value == null || value <= 0) {
      return i18n('history_earlier');
    }

    return i18n('watched_at', args: {'time': formatHistoryWatchedAt(value)});
  }

  bool get _themeShowDelete {
    final config = SettingsService.to.roomCardConfig;
    return config.isMobileViewport ? config.mobileShowDelete : config.desktopShowDelete;
  }

  bool get _effectiveShowDelete => history && onRemoveFromHistory != null && _themeShowDelete;

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
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: largeScreen
                ? _buildLargeLayout(context, title, nick, meta)
                : _buildMobileLayout(context, title, nick, meta, audience),
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
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.person_outline_rounded, size: 12, color: colors.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        nick.isEmpty ? i18n('unknown') : nick,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.1,
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

  Widget _buildMobileLayout(
    BuildContext context,
    String title,
    String nick,
    String meta,
    String audience,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          CommonAvatar(avatarUrl: room.avatar, fallbackName: nick, dense: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  nick.isEmpty ? i18n('unknown') : nick,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              context.buildPlatformTag(room.platform!, mini: true),
              if (!history)
                Text(meta, style: TextStyle(fontSize: 12, color: Colors.orange.shade700)),
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
            child: Icon(
              Icons.live_tv_rounded,
              size: 34,
              color: colors.onSurfaceVariant.withValues(alpha: .35),
            ),
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
                    child: Icon(
                      Icons.live_tv_rounded,
                      color: colors.onSurfaceVariant.withValues(alpha: .25),
                    ),
                  );
                },
                errorWidget: (_, _, _) {
                  return ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: colors.onSurfaceVariant.withValues(alpha: .35),
                    ),
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
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
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
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                height: 1.1,
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
