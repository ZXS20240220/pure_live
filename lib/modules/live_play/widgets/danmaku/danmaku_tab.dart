import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/pages/super_chat_page.dart';
import 'package:pure_live/modules/live_play/pages/keyword_block_page.dart';
import 'package:pure_live/modules/live_play/pages/danmaku_settings_page.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/dialogs/play_other.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_list_view.dart';
import 'package:pure_live/modules/multiview/danmaku/multiview_danmaku_settings_binding.dart';

class DanmakuTabView extends GetView<LivePlayController> {
  const DanmakuTabView({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final state = controller.state.value;
      if (state.room.detail == null) {
        return const AppStatusView(type: AppStatusType.loading, title: '', subtitle: '');
      }

      // 无 VideoController 的场景(画中画/多画面)也能打开弹幕设置。
      final settingsBinding = state.player.videoController ?? MultiviewDanmakuSettingsBinding();

      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            DanmakuSectionTabBar(controller: controller.tabController, tabs: controller.tabs),
            Expanded(
              child: TabBarView(
                controller: controller.tabController,
                physics: const PureLiveBoundedScrollPhysics(),
                children: [
                  SettingsService.to.danmaku.enableDanmakuDisplay.v
                      ? DanmakuListView(room: state.room.detail!)
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(i18n('danmaku_display_disabled_hint'), textAlign: TextAlign.center),
                          ),
                        ),
                  const SuperChatPage(),
                  DanmakuSettingsPage(controller: settingsBinding),
                  const KeywordBlockPage(),
                  // 3.1/6.5 换台页签：持久面板，页签与筛选状态记忆在 controller。
                  PlayOtherPanel(
                    controller: controller,
                    showHeader: true,
                    showCloseButton: false,
                    isPersistent: true,
                    onSelectRoom: (room) => controller.switchRoom(room),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// The four portrait room sections are navigation, not a free-scrolling chip
/// strip. Giving them equal bounded widths keeps the row fixed while the
/// associated [TabBarView] remains swipeable between its first and last page.
class DanmakuSectionTabBar extends StatelessWidget {
  const DanmakuSectionTabBar({super.key, required this.tabs, this.controller});

  final List<String> tabs;
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: TabBar(
        key: const ValueKey('live-danmaku-section-tabs'),
        isScrollable: false,
        tabAlignment: TabAlignment.fill,
        physics: const PureLiveBoundedScrollPhysics(),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        controller: controller,
        tabs: tabs.map((name) => Tab(text: name)).toList(growable: false),
      ),
    );
  }
}
