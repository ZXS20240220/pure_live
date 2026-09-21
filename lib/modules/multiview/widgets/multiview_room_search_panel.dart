import 'dart:async';

import 'package:remixicon/remixicon.dart';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/multiview/multiview_room_search_controller.dart';
import 'package:pure_live/modules/multiview/widgets/multiview_room_picker.dart';

class MultiviewRoomSearchPanel extends StatefulWidget {
  const MultiviewRoomSearchPanel({
    super.key,
    required this.cellIndex,
    required this.onPicked,
    this.onDragUpdate,
    this.onClose,
    this.embedded = false,
    this.search,
    this.title,
  });

  final int cellIndex;
  final ValueChanged<LiveRoom> onPicked;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onClose;
  final bool embedded;
  final MultiviewRoomSearchController? search;
  final String? title;

  @override
  State<MultiviewRoomSearchPanel> createState() => _MultiviewRoomSearchPanelState();
}

class _MultiviewRoomSearchPanelState extends State<MultiviewRoomSearchPanel> {
  late final MultiviewRoomSearchController _search;
  final TextEditingController _keyword = TextEditingController();
  final TextEditingController _direct = TextEditingController();
  String _platformId = '';
  late final bool _ownsSearch = widget.search == null;

  @override
  void initState() {
    super.initState();
    _search = widget.search ?? MultiviewRoomSearchController();
  }

  @override
  void dispose() {
    _keyword.dispose();
    _direct.dispose();
    if (_ownsSearch) _search.clear();
    super.dispose();
  }

  Future<void> _runSearch() => _search.search(_keyword.text, platformId: _platformId);

  Future<void> _addDirect() async {
    final room = await _search.resolveDirect(_direct.text, platformId: _platformId);
    if (room != null && mounted) widget.onPicked(room);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: widget.embedded ? 0 : 6,
      color: theme.colorScheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _buildHeader(theme),
          _buildKeywordRow(theme),
          _buildDirectRow(theme),
          _buildMessage(theme),
          Expanded(child: _buildResults(theme)),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final titleText =
        widget.title ?? '${i18n('multiview_search_rooms')} · ${i18n('multiview_cell')} ${widget.cellIndex + 1}';
    return GestureDetector(
      onPanUpdate: widget.onDragUpdate == null ? null : (event) => widget.onDragUpdate!(event.delta),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(Remix.search_line, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(titleText, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.t13Medium),
            ),
            if (!widget.embedded && widget.onDragUpdate != null)
              Tooltip(
                message: i18n('multiview_panel_drag_hint'),
                child: Icon(Remix.drag_move_line, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: i18n('multiview_close_panel'),
              icon: const Icon(Remix.close_line, size: 18),
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeywordRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keyword,
              style: AppTextStyles.t13,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_runSearch()),
              decoration: InputDecoration(
                isDense: true,
                hintText: i18n('multiview_search_placeholder'),
                prefixIcon: const Icon(Remix.search_line, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _PlatformDropdown(
            platforms: _search.selectablePlatforms,
            value: _platformId,
            onChanged: (value) => setState(() => _platformId = value),
          ),
          const SizedBox(width: 6),
          FilledButton(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            onPressed: () => unawaited(_runSearch()),
            child: Text(i18n('multiview_search_start'), style: AppTextStyles.t13),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _direct,
              style: AppTextStyles.t13,
              onSubmitted: (_) => unawaited(_addDirect()),
              decoration: InputDecoration(
                isDense: true,
                hintText: i18n('multiview_room_id_or_link'),
                prefixIcon: const Icon(Remix.tv_2_line, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: i18n('multiview_room_id_or_link'),
            onPressed: () => unawaited(_addDirect()),
            icon: const Icon(Remix.add_line, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(ThemeData theme) {
    return Obx(() {
      final message = _search.message.value;
      if (message.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Text(message, style: AppTextStyles.t12.copyWith(color: theme.colorScheme.error)),
      );
    });
  }

  Widget _buildResults(ThemeData theme) {
    return Obx(() {
      if (_search.loading.value) {
        return const AppStatusView(type: AppStatusType.loading, isMini: true);
      }
      final rooms = _search.results.toList(growable: false);
      if (rooms.isEmpty) {
        return AppStatusView(
          type: AppStatusType.empty,
          icon: Remix.tv_2_line,
          title: i18n('multiview_search_no_result'),
          subtitle: i18n('multiview_search_placeholder'),
          isMini: true,
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        itemCount: rooms.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, index) {
          final room = rooms[index];
          return ListTile(
            dense: true,
            leading: MultiviewRoomTileLeading(room: room),
            title: Text(room.nick ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.t13Medium),
            subtitle: Text(
              room.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.t12Muted,
            ),
            trailing: MultiviewLiveStatusBadge(room: room),
            onTap: () => widget.onPicked(room),
          );
        },
      );
    });
  }
}

class _PlatformDropdown extends StatefulWidget {
  const _PlatformDropdown({required this.platforms, required this.value, required this.onChanged});

  final List<Site> platforms;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_PlatformDropdown> createState() => _PlatformDropdownState();
}

class _PlatformDropdownState extends State<_PlatformDropdown> {
  static const double _kItemHeight = 36;
  static const double _kPopupMaxHeight = 240;

  bool _open = false;
  OverlayEntry? _entry;

  void _toggle() => _open ? _close() : _openMenu();

  void _close() {
    _entry?.remove();
    _entry = null;
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

    final items = <_PlatformItem>[
      _PlatformItem(id: '', label: i18n('site_all'), icon: null),
      ...widget.platforms.map((s) => _PlatformItem(id: s.id, label: s.name, icon: s.logo)),
    ];

    final itemCount = items.length;
    final popupHeight = (itemCount * _kItemHeight).clamp(_kItemHeight, _kPopupMaxHeight);
    final popupWidth = triggerSize.width.clamp(120.0, 220.0);

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
                  width: popupWidth,
                  height: popupHeight,
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
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: itemCount,
                    itemBuilder: (_, index) {
                      final item = items[index];
                      final isSelected = item.id == widget.value;
                      return InkWell(
                        onTap: () {
                          _close();
                          widget.onChanged(item.id);
                        },
                        child: Container(
                          height: _kItemHeight,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              if (item.icon != null) ...[
                                Image.asset(item.icon!, width: 16, height: 16),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colors.onSurface,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isSelected) Icon(Icons.check_rounded, size: 16, color: colors.primary),
                            ],
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
    final selected = widget.platforms.where((site) => site.id == widget.value).firstOrNull;
    final label = selected?.name ?? i18n('site_all');

    return Tooltip(
      message: i18n('prefer_platform'),
      child: GestureDetector(
        onTap: _toggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: _open
                ? colors.primaryContainer.withValues(alpha: 0.55)
                : colors.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _open ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.fade, style: AppTextStyles.t13),
              ),
              Icon(_open ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlatformItem {
  const _PlatformItem({required this.id, required this.label, required this.icon});
  final String id;
  final String label;
  final String? icon;
}
