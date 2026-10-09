import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pure_live/common/index.dart';

class WallpaperVideoPlayer extends StatefulWidget {
  final String source;
  final bool isLocal;
  final BoxFit fit;

  const WallpaperVideoPlayer({super.key, required this.source, required this.isLocal, required this.fit});

  @override
  State<WallpaperVideoPlayer> createState() => _WallpaperVideoPlayerState();
}

class _WallpaperVideoPlayerState extends State<WallpaperVideoPlayer> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSub;
  Worker? _volumeWorker;
  Worker? _pauseOnLiveWorker;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  @override
  void didUpdateWidget(WallpaperVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _openSource();
    }
  }

  Future<void> _initPlayer() async {
    MediaKit.ensureInitialized();

    final player = Player();
    _player = player;

    final controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    _controller = controller;

    final wallpaper = SettingsService.to.wallpaper;

    // 初始音量
    await player.setVolume(wallpaper.videoVolume.v * 100);

    // 循环播放
    await player.setPlaylistMode(PlaylistMode.loop);

    await _openSource();

    // 监听音量变化
    _volumeWorker = ever(wallpaper.videoVolume, (double v) {
      if (!_disposed && _player != null) {
        _player!.setVolume(v * 100);
      }
    });

    // 监听"直播时暂停"开关变化
    _pauseOnLiveWorker = ever(wallpaper.pauseVideoWhenLivePlaying, (bool pauseOnLive) {
      if (_disposed || _player == null) return;
      if (!GlobalPlayerService.instance.initialized) return;
      final isLivePlaying = GlobalPlayerService.instance.playerManager.isPlayingNow;
      if (pauseOnLive && isLivePlaying) {
        _player!.pause();
      } else {
        _player!.play();
      }
    });

    // 监听直播播放状态：直播播放时暂停壁纸视频
    if (GlobalPlayerService.instance.initialized) {
      _playingSub = GlobalPlayerService.instance.playerManager.onPlaying.listen((playing) {
        if (_disposed || _player == null) return;
        if (wallpaper.pauseVideoWhenLivePlaying.v) {
          if (playing) {
            _player!.pause();
          } else {
            _player!.play();
          }
        }
      });
    }
  }

  Future<void> _openSource() async {
    final player = _player;
    if (player == null || _disposed) return;

    final media = widget.isLocal ? Media(widget.source) : Media(widget.source);
    await player.open(media, play: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _playingSub?.cancel();
    _volumeWorker?.dispose();
    _pauseOnLiveWorker?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(color: Colors.transparent);
    }
    return Video(
      controller: controller,
      controls: NoVideoControls,
      fit: widget.fit,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }
}
