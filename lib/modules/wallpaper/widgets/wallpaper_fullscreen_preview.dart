import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/saved_wallpapers_controller.dart';

/// 壁纸全屏预览层
///
/// 右键点击壁纸卡片时弹出，覆盖整个页面。
/// - 图片：等比包含显示（BoxFit.contain）
/// - 视频：自动播放、循环、静音
/// 点击任意位置关闭。
class WallpaperFullscreenPreview extends StatefulWidget {
  const WallpaperFullscreenPreview({super.key, required this.item, required this.onClose});

  final SavedWallpaperItem item;
  final VoidCallback onClose;

  @override
  State<WallpaperFullscreenPreview> createState() => _WallpaperFullscreenPreviewState();
}

class _WallpaperFullscreenPreviewState extends State<WallpaperFullscreenPreview> {
  Player? _player;
  VideoController? _videoController;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo) _initVideoPlayer();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _initVideoPlayer() async {
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    await player.setVolume(0);
    await player.setPlaylistMode(PlaylistMode.loop);
    await player.open(Media(widget.item.path), play: true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Container(
          color: Colors.black,
          child: Center(child: _buildContent()),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (widget.item.isVideo) {
      final vc = _videoController;
      if (vc == null) {
        return const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
        );
      }
      return Video(
        controller: vc,
        controls: NoVideoControls,
        fit: BoxFit.contain,
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
      );
    }
    final file = File(widget.item.path);
    if (!file.existsSync()) {
      return const Icon(Remix.image_line, color: Colors.white38, size: 64);
    }
    return Image.file(
      file,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => const Icon(Remix.image_line, color: Colors.white38, size: 64),
    );
  }
}
