import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/states/ui_state.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_tab.dart';
import 'package:pure_live/modules/live_play/widgets/layout/live_play_shell.dart';
import 'package:pure_live/modules/live_play/widgets/layout/live_play_video.dart';
import 'package:pure_live/modules/live_play/widgets/layout/live_play_header.dart';
import 'package:pure_live/modules/live_play/widgets/layout/panel_resize_divider.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/resolution_selector/resolutions_row.dart';

enum LivePlayNormalLayoutKind { portraitStack, desktopSplit }

LivePlayNormalLayoutKind resolveLivePlayNormalLayout(double width) {
  return width <= 680 ? LivePlayNormalLayoutKind.portraitStack : LivePlayNormalLayoutKind.desktopSplit;
}

/// Stable normal-room composition shared by production and widget tests.
///
/// The video, quality selector and danmaku list must remain simultaneously
/// visible on a phone. Hiding them behind a full-surface flip/drawer makes a
/// normal room indistinguishable from fullscreen and leaves no discoverable
/// interaction surface.
class LivePlayNormalLayout extends StatefulWidget {
  const LivePlayNormalLayout({
    super.key,
    required this.video,
    required this.resolution,
    required this.danmaku,
    this.showPanel = true,
  });

  final Widget video;
  final Widget resolution;
  final Widget danmaku;
  final bool showPanel;

  @override
  State<LivePlayNormalLayout> createState() => _LivePlayNormalLayoutState();
}

class _LivePlayNormalLayoutState extends State<LivePlayNormalLayout> {
  late final ValueNotifier<double> _panelWidthNotifier;

  @override
  void initState() {
    super.initState();
    final screenWidth = MediaQuery.sizeOf(context).width;
    _panelWidthNotifier = ValueNotifier<double>(
      SettingsService.to.panel.clampWidth(SettingsService.to.panel.panelWidth, screenWidth),
    );
  }

  @override
  void dispose() {
    _panelWidthNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!widget.showPanel) {
          return Align(
            key: const ValueKey('live-play-video-only-layout'),
            alignment: Alignment.topCenter,
            child: widget.video,
          );
        }
        if (resolveLivePlayNormalLayout(constraints.maxWidth) == LivePlayNormalLayoutKind.portraitStack) {
          return Column(
            key: const ValueKey('live-play-portrait-stack'),
            children: [
              widget.video,
              widget.resolution,
              const Divider(height: 1),
              Expanded(
                key: const ValueKey('live-play-portrait-danmaku'),
                child: ColoredBox(color: Theme.of(context).colorScheme.surface, child: widget.danmaku),
              ),
            ],
          );
        }

        return ValueListenableBuilder<double>(
          valueListenable: _panelWidthNotifier,
          builder: (context, panelWidth, _) {
            final panelColor = Theme.of(context).colorScheme.surface;
            final screenWidth = MediaQuery.sizeOf(context).width;
            return Row(
              key: const ValueKey('live-play-desktop-split'),
              children: [
                Expanded(child: widget.video),
                PanelResizeDivider(
                  currentWidth: panelWidth,
                  clampWidth: (width, screenWidth) => SettingsService.to.panel.clampWidth(width, screenWidth),
                  onResize: (newWidth) {
                    _panelWidthNotifier.value = newWidth;
                  },
                  onDragEnd: (finalWidth) {
                    SettingsService.to.panel.setPanelWidth(finalWidth, screenWidth);
                  },
                ),
                SizedBox(
                  key: const ValueKey('live-play-desktop-panel'),
                  width: panelWidth,
                  child: ColoredBox(
                    color: panelColor,
                    child: Column(
                      children: [
                        widget.resolution,
                        const Divider(height: 1),
                        Expanded(child: widget.danmaku),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class LivePlayContent extends StatelessWidget {
  const LivePlayContent({super.key, required this.controller, required this.isInPip, required this.mode});

  final LivePlayController controller;
  final bool isInPip;
  final VideoMode mode;

  @override
  Widget build(BuildContext context) {
    final manager = GlobalPlayerService.instance.player;

    if (isInPip) {
      return Theme(
        data: ThemeData.dark(),
        child: Container(key: const ValueKey('pip'), color: Colors.transparent, child: manager.buildPiPOverlay()),
      );
    }

    if (mode == VideoMode.normal) {
      return ColoredBox(
        key: const ValueKey('normal'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: _buildNormalView(context),
      );
    }

    return Container(
      key: const ValueKey('fullscreen-standard-video'),
      color: Colors.black,
      child: LivePlayVideo(controller: controller, expandToParent: true),
    );
  }

  Widget _buildNormalView(BuildContext context) {
    final compactHeader = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: LivePlayHeader(controller: controller, compactHeader: compactHeader),
      body: SafeArea(
        child: Obx(() {
          // 沉浸模式：视频铺满播放区，侧栏悬停右缘自动展开（live_play_shell）。
          if (SettingsService.to.player.enableImmersiveLayout.v) {
            return LivePlayShell(
              controller: controller,
              resolution: const ResolutionsRow(),
              danmaku: _buildDanmaku(),
              showPanel: controller.site != Sites.iptvSite,
            );
          }
          return LivePlayNormalLayout(
            video: LivePlayVideo(controller: controller),
            resolution: const ResolutionsRow(),
            danmaku: _buildDanmaku(),
            showPanel: controller.site != Sites.iptvSite,
          );
        }),
      ),
    );
  }

  Widget _buildDanmaku() {
    return Obx(() {
      final state = controller.state.value;
      if (state.room.detail == null || controller.site == Sites.iptvSite) {
        return const SizedBox.shrink();
      }
      final globalState = GlobalPlayerState.to;
      if (globalState.isFullscreen.value || globalState.isWindowFullscreen.value) {
        return const SizedBox.shrink();
      }
      return const DanmakuTabView();
    });
  }
}
