import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final refreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: true,
  );

  @override
  void dispose() {
    refreshController.dispose();
    super.dispose();
  }

  Future<void> onRefresh() async {
    final history = SettingsService.to.history;
    final list = applyHistoryLimit(history.historyRooms.v, history.historyLimit.v);
    final result = await history.refreshRoomDetails(list, shouldCancel: () => !mounted);
    if (!mounted || result == null) return;
    history.historyRooms.v = result.rooms;
    if (result.allSuccess) {
      refreshController.finishRefresh(IndicatorResult.success);
      refreshController.resetFooter();
    } else {
      refreshController.finishRefresh(IndicatorResult.fail);
    }
  }

  void _showHistoryLimitDialog(BuildContext context) {
    final controller = SettingsService.to.history;
    int draftLimit = controller.historyLimit.v;
    final customController = TextEditingController();
    const presetOptions = <int>[20, 50, 100, 200, 500];
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(i18n('history_limit'), style: AppTextStyles.t16Bold),
          content: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setDialogState) {
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(i18n('current_options'), style: AppTextStyles.t12Muted),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...presetOptions.map(
                            (value) => ChoiceChip(
                              label: Text('$value', style: AppTextStyles.t12),
                              selected: draftLimit == value,
                              onSelected: (_) => setDialogState(() => draftLimit = value),
                            ),
                          ),
                          ChoiceChip(
                            label: Text(i18n('history_unlimited'), style: AppTextStyles.t12),
                            selected: draftLimit == unlimitedHistoryLimit,
                            onSelected: (_) =>
                                setDialogState(() => draftLimit = unlimitedHistoryLimit),
                          ),
                          if (!presetOptions.contains(draftLimit) &&
                              draftLimit != unlimitedHistoryLimit)
                            ChoiceChip(
                              label: Text('$draftLimit', style: AppTextStyles.t12),
                              selected: true,
                              onSelected: (_) {},
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(i18n('custom_input'), style: AppTextStyles.t13Medium),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: customController,
                              keyboardType: TextInputType.number,
                              style: AppTextStyles.t14,
                              decoration: InputDecoration(
                                hintText: '50',
                                suffixText: i18n('items'),
                                suffixStyle: AppTextStyles.t12Muted,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () {
                              final value = int.tryParse(customController.text.trim());
                              if (value == null) return;
                              setDialogState(() => draftLimit = normalizeHistoryLimit(value));
                              customController.clear();
                            },
                            child: Text(
                              i18n('apply'),
                              style: AppTextStyles.t13Medium.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${i18n("current_value")}: ${_historyLimitLabel(draftLimit)}',
                        style: AppTextStyles.t12Muted,
                      ),
                      const SizedBox(height: 6),
                      Text(i18n('history_limit_desc'), style: AppTextStyles.t12Muted),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(i18n('cancel'), style: AppTextStyles.t14Muted),
            ),
            TextButton(
              onPressed: () {
                controller.setHistoryLimit(draftLimit);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(i18n('confirm'), style: AppTextStyles.t14Primary),
            ),
          ],
        );
      },
    ).whenComplete(customController.dispose);
  }

  Future<void> _clearHistory() async {
    final controller = SettingsService.to.history;
    if (controller.historyRooms.v.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n('clear_history'), style: AppTextStyles.t16Bold),
        content: Text(i18n('clear_history_confirm'), style: AppTextStyles.t14),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(i18n('cancel'), style: AppTextStyles.t14Muted),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(i18n('confirm'), style: AppTextStyles.t14Primary),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Obx(() {
          final controller = SettingsService.to.history;
          return Text(
            '${i18n("history")} '
            '(${controller.historyRooms.v.length}/${_historyLimitLabel(controller.historyLimit.v)})',
          );
        }),
        actions: [
          IconButton(
            tooltip: i18n('history_limit'),
            icon: const Icon(Icons.settings_rounded),
            onPressed: () => _showHistoryLimitDialog(context),
          ),
          Obx(() {
            if (SettingsService.to.history.historyRooms.v.isEmpty) return const SizedBox.shrink();
            return IconButton(
              tooltip: i18n('clear_history'),
              icon: const Icon(Icons.delete_forever),
              onPressed: _clearHistory,
            );
          }),
        ],
      ),
      body: Obx(() {
        const dense = true;
        final allRooms = SettingsService.to.history.historyRooms.v;
        // 同步收藏夹最新状态 + 过滤：只显示正在直播的房间
        final favoriteMap = {
          for (final fav in SettingsService.to.fav.favoriteRooms.v) fav.identityKey: fav,
        };
        final rooms = allRooms
            .map((room) {
              final fav = favoriteMap[room.identityKey];
              return fav != null ? preserveHistoryMetadata(fav, room) : room;
            })
            .where((room) => room.isLiveNow)
            .toList();
        return LayoutBuilder(
          builder: (context, constraint) {
            final width = constraint.maxWidth;
            int crossAxisCount = width > 1280 ? 4 : (width > 960 ? 3 : (width > 640 ? 2 : 1));
            if (dense) {
              crossAxisCount = width > 1280 ? 5 : (width > 960 ? 4 : (width > 640 ? 3 : 2));
            }
            return EasyRefresh(
              controller: refreshController,
              onRefresh: onRefresh,
              onLoad: () => refreshController.finishLoad(IndicatorResult.noMore),
              child: rooms.isEmpty
                  ? EmptyView(
                      icon: Icons.history_rounded,
                      title: i18n('empty_history'),
                      subtitle: '',
                    )
                  : WaterfallFlow.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      gridDelegate: SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
                        lastChildLayoutTypeBuilder: (index) => LastChildLayoutType.none,
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: SettingsService.to.theme.crossAxisSpacing.v,
                        mainAxisSpacing: SettingsService.to.theme.mainAxisSpacing.v,
                      ),
                      itemCount: rooms.length,
                      itemBuilder: (context, index) => RoomCard(
                        room: rooms[index],
                        dense: dense,
                        showDelete: true,
                        onDelete: () {
                          SettingsService.to.history.removeRoomFromHistory(rooms[index]);
                        },
                      ),
                    ),
            );
          },
        );
      }),
    );
  }

  String _historyLimitLabel(int limit) {
    return limit == unlimitedHistoryLimit ? i18n('history_unlimited') : '$limit';
  }
}
