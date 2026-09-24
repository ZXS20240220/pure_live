import 'package:flutter/gestures.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/routes/app_navigation.dart';
import 'package:pure_live/common/consts/app_consts.dart';

class HomeTabletView extends StatefulWidget {
  final Widget body;
  final int index;
  final List<String> activeMenuIds;
  final bool showRecord;
  final void Function(int) onDestinationSelected;

  const HomeTabletView({
    super.key,
    required this.body,
    required this.index,
    required this.activeMenuIds,
    required this.showRecord,
    required this.onDestinationSelected,
  });

  @override
  State<HomeTabletView> createState() => _HomeTabletViewState();
}

class _HomeTabletViewState extends State<HomeTabletView> {
  /// 顶部工具按钮区（菜单/多视/工具箱/搜索/录制）的测量锚点。
  /// 滚轮翻页只作用于下方的页面目的地：指针位于该区域内（或其上方）时不触发，
  /// 避免影响侧栏上方的其他入口。
  final GlobalKey _leadingKey = GlobalKey();

  void _handleRailPointerSignal(PointerSignalEvent event, List<int> virtualToRealMap) {
    if (event is! PointerScrollEvent) return;
    if (virtualToRealMap.isEmpty) return;

    final leadingBox = _leadingKey.currentContext?.findRenderObject() as RenderBox?;
    if (leadingBox != null && leadingBox.hasSize) {
      final local = leadingBox.globalToLocal(event.position);
      if (local.dy >= 0 && local.dy <= leadingBox.size.height) return;
    }

    var pos = virtualToRealMap.indexOf(widget.index);
    if (pos < 0) pos = 0;
    final dir = event.scrollDelta.dy > 0 ? 1 : -1;
    final next = (pos + dir) % virtualToRealMap.length;
    widget.onDestinationSelected(virtualToRealMap[next]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Builder(
          builder: (context) {
            final List<NavigationRailDestination> destinations = [];
            final List<int> virtualToRealMap = [];

            for (String id in widget.activeMenuIds) {
              final menu = HomeMenu.fromId(id);
              if (menu != null) {
                virtualToRealMap.add(menu.index);

                switch (menu) {
                  case HomeMenu.favorites:
                    destinations.add(
                      NavigationRailDestination(
                        icon: const Icon(Remix.heart_3_line),
                        selectedIcon: const Icon(Remix.heart_3_fill),
                        label: Text(i18n('favorites_title')),
                      ),
                    );
                    break;
                  case HomeMenu.popular:
                    destinations.add(
                      NavigationRailDestination(
                        icon: const Icon(Remix.fire_line),
                        selectedIcon: const Icon(Remix.fire_fill),
                        label: Text(i18n('popular_title')),
                      ),
                    );
                    break;
                  case HomeMenu.areas:
                    destinations.add(
                      NavigationRailDestination(
                        icon: const Icon(Remix.apps_2_line),
                        selectedIcon: const Icon(Remix.apps_2_fill),
                        label: Text(i18n('areas_title')),
                      ),
                    );
                    break;
                  case HomeMenu.record:
                    destinations.add(
                      NavigationRailDestination(
                        icon: const Icon(Remix.download_2_line),
                        selectedIcon: const Icon(Remix.download_2_fill),
                        label: Text(i18n('record_center')),
                      ),
                    );
                    break;
                }
              }
            }

            int? activeSelectedIndex;
            final pos = virtualToRealMap.indexOf(widget.index);
            if (pos >= 0 && pos < destinations.length) {
              activeSelectedIndex = pos;
            } else {
              activeSelectedIndex = null;
            }

            return Row(
              children: [
                Listener(
                  onPointerSignal: (event) => _handleRailPointerSignal(event, virtualToRealMap),
                  child: NavigationRail(
                    groupAlignment: 0.9,
                    labelType: NavigationRailLabelType.all,
                    leading: Column(
                      key: _leadingKey,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(padding: EdgeInsets.all(12), child: MenuButton()),
                        Obx(
                          () => SettingsService.to.app.enableMultiView.v
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 0, bottom: 12, left: 12, right: 12),
                                  child: IconButton(
                                    onPressed: AppNavigator.toMultiview,
                                    tooltip: i18n('multiview_title'),
                                    icon: const Icon(Remix.layout_grid_line),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 0, bottom: 12, left: 12, right: 12),
                          child: IconButton(
                            onPressed: () => Get.toNamed(RoutePath.kToolbox),
                            icon: const Icon(Remix.link),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 0, bottom: 12, left: 12, right: 12),
                          child: IconButton(
                            onPressed: () => Get.toNamed(RoutePath.kSearch),
                            icon: const Icon(CustomIcons.search),
                          ),
                        ),
                        if (widget.showRecord)
                          Padding(
                            padding: const EdgeInsets.only(top: 0, bottom: 12, left: 12, right: 12),
                            child: IconButton(
                              onPressed: () => Get.toNamed(RoutePath.kRecordPage),
                              icon: const Icon(Remix.download_2_line),
                            ),
                          ),
                      ],
                    ),
                    destinations: destinations,
                    selectedIndex: activeSelectedIndex,
                    onDestinationSelected: (int virtualIndex) {
                      if (virtualIndex >= 0 && virtualIndex < virtualToRealMap.length) {
                        widget.onDestinationSelected(virtualToRealMap[virtualIndex]);
                      }
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: destinations.isEmpty
                      ? AppStatusView(
                          type: AppStatusType.empty,
                          icon: Remix.menu_2_fill,
                          title: i18n('no_menu_title'),
                          subtitle: i18n('no_menu_subtitle'),
                        )
                      : widget.body,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
