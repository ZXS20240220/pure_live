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

class _WallpaperVideoPlayerState extends State<WallpaperVideoPlayer> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSub;
  Worker? _volumeWorker;
  Worker? _pauseOnLiveWorker;
  Worker? _loopWorker;
  bool _disposed = false;

  /// 窗口最小化/不可见时置 true，恢复可见后清除。
  bool _windowHidden = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPlayer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _windowHidden = true;
        _syncPlayback();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        if (_windowHidden) {
          _windowHidden = false;
          _syncPlayback();
        }
      default:
        break;
    }
  }

  /// 统一计算“当前是否应当播放”：
  /// 窗口不可见，或设置了“直播时暂停”且直播正在播放时暂停，其余情况播放。
  /// 合并可见性与直播两个暂停来源，避免恢复时相互覆盖。
  void _syncPlayback() {
    if (_disposed || _player == null) return;
    final wallpaper = SettingsService.to.wallpaper;
    final livePlaying =
        GlobalPlayerService.instance.initialized && GlobalPlayerService.instance.playerManager.isPlayingNow;
    final shouldPlay = !_windowHidden && !(wallpaper.pauseVideoWhenLivePlaying.v && livePlaying);
    if (shouldPlay) {
      _player!.play();
    } else {
      _player!.pause();
    }
  }

  static PlaylistMode _resolveLoopMode(bool loop) => loop ? PlaylistMode.loop : PlaylistMode.none;

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

    // 循环模式跟随设置
    await player.setPlaylistMode(_resolveLoopMode(wallpaper.videoLoop.v));

    await _openSource();

    // 监听音量变化
    _volumeWorker = ever(wallpaper.videoVolume, (double v) {
      if (!_disposed && _player != null) {
        _player!.setVolume(v * 100);
      }
    });

    // 监听“直播时暂停”开关变化
    _pauseOnLiveWorker = ever(wallpaper.pauseVideoWhenLivePlaying, (bool pauseOnLive) {
      _syncPlayback();
    });

    // 监听循环开关变化
    _loopWorker = ever(wallpaper.videoLoop, (bool loop) {
      if (!_disposed && _player != null) {
        _player!.setPlaylistMode(_resolveLoopMode(loop));
      }
    });

    // 监听直播播放状态：直播播放时暂停壁纸视频
    if (GlobalPlayerService.instance.initialized) {
      _playingSub = GlobalPlayerService.instance.playerManager.onPlaying.listen((playing) {
        _syncPlayback();
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
    WidgetsBinding.instance.removeObserver(this);
    _playingSub?.cancel();
    _volumeWorker?.dispose();
    _pauseOnLiveWorker?.dispose();
    _loopWorker?.dispose();
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
