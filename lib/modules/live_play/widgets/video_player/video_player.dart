import 'package:pure_live/modules/live_play/widgets/video_player/playback_failure_overlay.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_loading.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller_panel.dart';

class VideoPlayer extends StatefulWidget {
  final VideoController controller;
  final Color surfaceColor;
  const VideoPlayer({super.key, required this.controller, this.surfaceColor = Colors.black});

  @override
  State<VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayer> {
  VideoController get controller => widget.controller;
  Widget _buildVideo() {
    return Obx(() {
      final audioOnly = controller.audioOnlyState.value;
      final state = controller.livePlayController.state.value;
      final displayVideo = state.ui.displayVideoLayer;
      final hasError = controller.hasPlaybackError;

      return StableVideoLayer(
        visible: displayVideo,
        // Android SurfaceProducer instances are expensive and historically
        // failed to recover when a covered route rebuilt the video subtree.
        // Windows uses a native media_kit texture with different lifetime
        // rules: leaving it mounted while another Flutter route animates over
        // it can race the compositor and crash flutter_windows.dll.  Tear the
        // texture widget down only on Windows; the Player itself stays alive.
        preserveMountedVideo: !PlatformUtils.isWindows,
        placeholder: const VideoLoading(),
        // The controller panel must sit as a Stack sibling ABOVE the video
        // (dev-version structure). Its full-surface hit-test layer absorbs
        // pointer events before PureLivePipWidget/DragToResizeArea's 8px
        // window-resize bands around the video, so the play page no longer
        // shows the OS-style resize cursor/resize-window drag around the
        // video area; only the real window borders resize the window.
        video: Stack(
          fit: StackFit.expand,
          children: [
            // 桌面端 Ctrl+滚轮缩放 / Ctrl+拖拽平移只作用于视频纹理层，
            // 弹幕、控制栏等 UI 不受影响；ClipRect 防止放大后的纹理
            // 绘制到视频表面之外（例如盖住沉浸模式右侧弹幕面板）。
            VideoZoomTransform(
              controller: controller,
              child: PlaybackFailureOverlay(
                hasError: hasError,
                onRetry: controller.refresh,
                child: GlobalPlayerService.instance.player.getVideoWidget(
                  SettingsService.to.player.videoFitIndex.v,
                  fitList: SettingsService.to.player.videoFitArray,
                  trackPipSource: true,
                  audioOnlyOverride: audioOnly,
                  surfaceColor: widget.surfaceColor,
                ),
              ),
            ),
            VideoControllerPanel(controller: controller),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _buildVideo();
  }
}

/// Controls native-texture ownership while another route temporarily covers it.
///
/// Replacing the texture with a loading widget used to tear down and recreate
/// the Flutter video subtree around the recording page. On Android that races
/// SurfaceProducer cleanup/availability callbacks and can leave a black frame,
/// paused decoder or stale portrait geometry after returning, so Android keeps
/// it offstage. Windows detaches it until the covering route has fully popped
/// to avoid a native-texture teardown race.
class StableVideoLayer extends StatelessWidget {
  const StableVideoLayer({
    super.key,
    required this.visible,
    required this.video,
    required this.placeholder,
    this.preserveMountedVideo = true,
  });

  final bool visible;
  final Widget video;
  final Widget placeholder;
  final bool preserveMountedVideo;

  @override
  Widget build(BuildContext context) {
    if (!visible && !preserveMountedVideo) {
      return placeholder;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: !visible, child: video),
        if (!visible) placeholder,
      ],
    );
  }
}

/// 桌面端画面缩放/平移变换层：仅变换视频纹理（mpv 输出），
/// 不影响弹幕、控制栏与截图（截图取的是 mpv 原始解码帧）。
///
/// 变换矩阵约定：映射点 p -> scale * p + pan（原点为左上角），
/// 与 [VideoController.zoomVideoAt] 的锚点计算公式保持一致。
class VideoZoomTransform extends StatefulWidget {
  const VideoZoomTransform({super.key, required this.controller, required this.child});

  final VideoController controller;
  final Widget child;

  @override
  State<VideoZoomTransform> createState() => _VideoZoomTransformState();
}

class _VideoZoomTransformState extends State<VideoZoomTransform> {
  Size? _reportedSize;

  @override
  void didUpdateWidget(covariant VideoZoomTransform oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 刷新/切换房间会更换 VideoController：新控制器的表面尺寸为 zero，
    // 必须丢弃旧缓存重新上报，否则缩放会因尺寸未知而被永久拦截。
    if (oldWidget.controller != widget.controller) {
      _reportedSize = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isFinite && !size.isEmpty && size != _reportedSize) {
          _reportedSize = size;
          // 布局期间不能直接触发 Rx 刷新，延后到帧后同步给控制器。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.controller.applyVideoViewSize(size);
          });
        }
        return Obx(() {
          final scale = widget.controller.videoScale.value;
          final pan = widget.controller.videoPan.value;
          // 列优先矩阵：缩放对角项 + 第 4 列平移，映射 p -> scale * p + pan。
          final matrix = Matrix4(scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0, pan.dx, pan.dy, 0, 1);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 缩小画面时纹理外露出的区域统一填充黑色。
                const ColoredBox(color: Colors.black),
                Transform(transform: matrix, child: widget.child),
              ],
            ),
          );
        });
      },
    );
  }
}
