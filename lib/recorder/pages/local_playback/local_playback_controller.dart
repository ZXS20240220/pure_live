import 'dart:io';
import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as mk_video;
import 'package:path/path.dart' as p;
import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/file_utils.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/player/utils/window_helper.dart';
import 'package:pure_live/recorder/models/recording_group.dart';
import 'package:pure_live/recorder/services/cache_service.dart';
import 'package:pure_live/recorder/services/local_danmaku_parser.dart';

class LocalPlaybackController extends GetxController {
  final Rx<HostRecordingGroup> group = Rx<HostRecordingGroup>(HostRecordingGroup(platform: '', safeNick: ''));

  final RxInt currentIndex = (-1).obs;
  final RxBool isPlaying = false.obs;
  final RxBool isBuffering = false.obs;
  final Rx<Duration> currentPosition = Duration.zero.obs;
  final Rx<Duration> totalDuration = Duration.zero.obs;
  final RxDouble volume = 1.0.obs;
  final RxDouble playbackSpeed = 1.0.obs;
  final RxBool danmakuEnabled = false.obs;

  final RxBool showController = true.obs;
  final RxBool showLocked = false.obs;
  final RxBool isMenuOpen = false.obs;

  final RxBool isFullscreen = false.obs;
  final RxBool isWindowFullscreen = false.obs;
  final RxBool isAudioOnly = false.obs;
  final RxBool isAlwaysOnTop = false.obs;
  final RxBool isPipMode = false.obs;

  final RxBool isSpeedHudVisible = false.obs;

  final RxBool isPipHovered = false.obs;
  final RxBool isPipAlwaysOnTop = false.obs;

  final RxInt videoWidth = RxInt(0);
  final RxInt videoHeight = RxInt(0);

  late final Player _player;
  late final mk_video.VideoController _videoController;

  final BarrageController barrageController = BarrageController();
  List<LocalDanmakuEntry> _danmakuEntries = const [];
  int _danmakuCursor = 0;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<int?>? _videoWidthSub;
  StreamSubscription<int?>? _videoHeightSub;

  bool _switching = false;
  bool _suppressDanmakuDispatch = false;
  Timer? _hideTimer;
  Timer? _speedHudHideTimer;

  /// 真实鼠标设备持有的控件 hover owner 集合。
  ///
  /// ControlHoverRegion 的 didUpdateWidget/dispose 也会调用 onExit，
  /// 但 Set.remove 返回 false 时表示没有真实设备在持锁——此时 arm
  /// auto-hide Timer 会导致控件抖动。只有真实 MouseRegion.onEnter/onExit
  /// 才会让 Set 的 add/remove 返回 true。（参考 live_play 的 video_controller）
  final _controlHoverOwners = <Object>{};
  bool get _isMouseOverController => _controlHoverOwners.isNotEmpty;

  bool? _alwaysOnTopBeforePlay;
  bool? _isFullscreenBeforePlay;

  final EasyRefreshController playlistRefreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: false,
  );

  static const _controllerHideDelay = Duration(milliseconds: 2500);
  static const _speedHudHideDelay = Duration(milliseconds: 1000);

  Player get mediaKitPlayer => _player;
  mk_video.VideoController get videoController => _videoController;

  String? get currentMp4Path {
    if (currentIndex.value < 0 || currentIndex.value >= group.value.mp4s.length) return null;
    return group.value.mp4s[currentIndex.value].path;
  }

  String? get currentDanmakuPath {
    final mp4 = currentMp4Path;
    if (mp4 == null) return null;
    final xml = p.setExtension(mp4, '.xml');
    return File(xml).existsSync() ? xml : null;
  }

  Mp4Entry? get currentEntry {
    if (currentIndex.value < 0 || currentIndex.value >= group.value.mp4s.length) return null;
    return group.value.mp4s[currentIndex.value];
  }

  @override
  void onInit() {
    super.onInit();
    MediaKit.ensureInitialized();

    _player = Player();
    _videoController = mk_video.VideoController(_player);
    _setupStreams();

    final args = Get.arguments;
    if (args is HostRecordingGroup) {
      group.value = args;
      if (args.mp4s.isNotEmpty) {
        playAt(0);
      }
    }

    volume.value = SettingsService.to.vol.currentPlatformDefaultVolume;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isClosed) {
        await _captureWindowState();
        enableController();
      }
    });
  }

  Future<void> _captureWindowState() async {
    try {
      _alwaysOnTopBeforePlay = await windowManager.isAlwaysOnTop();
      _isFullscreenBeforePlay = await windowManager.isFullScreen();
    } catch (_) {}
  }

  Future<void> _restoreWindowState() async {
    try {
      if (_alwaysOnTopBeforePlay != null) {
        await windowManager.setAlwaysOnTop(_alwaysOnTopBeforePlay!);
      }
      if (_isFullscreenBeforePlay != null && await windowManager.isFullScreen() != _isFullscreenBeforePlay) {
        await windowManager.setFullScreen(_isFullscreenBeforePlay!);
      }
    } catch (_) {}
  }

  void _setupStreams() {
    _playingSub = _player.stream.playing.listen((playing) {
      isPlaying.value = playing;
    });

    _posSub = _player.stream.position.listen((pos) {
      currentPosition.value = pos;
      if (_suppressDanmakuDispatch) return;
      _dispatchDanmaku(pos.inMilliseconds / 1000.0);
    });

    _durSub = _player.stream.duration.listen((dur) {
      totalDuration.value = dur;
      if (dur > Duration.zero && isBuffering.value) {
        isBuffering.value = false;
      }
    });

    _completedSub = _player.stream.completed.listen((completed) {
      if (completed && !_switching) {
        if (currentIndex.value < group.value.mp4s.length - 1) {
          playAt(currentIndex.value + 1);
        }
      }
    });

    _videoWidthSub = _player.stream.width.listen((w) {
      if (w != null && w > 0) {
        videoWidth.value = w;
        if (WindowHelper.instance.currentMode == WindowLayoutMode.pip &&
            videoWidth.value > 0 &&
            videoHeight.value > 0) {
          WindowHelper.instance.updatePiPAspectRatio(videoWidth.value / videoHeight.value);
        }
      }
    });

    _videoHeightSub = _player.stream.height.listen((h) {
      if (h != null && h > 0) {
        videoHeight.value = h;
        if (WindowHelper.instance.currentMode == WindowLayoutMode.pip &&
            videoWidth.value > 0 &&
            videoHeight.value > 0) {
          WindowHelper.instance.updatePiPAspectRatio(videoWidth.value / videoHeight.value);
        }
      }
    });
  }

  String _toFileUrl(String path) {
    final normalized = path.replaceAll('\\', '/');
    return 'file:///$normalized';
  }

  void _loadDanmaku(String? xmlPath) {
    if (xmlPath == null) {
      _danmakuEntries = const [];
    } else {
      _danmakuEntries = LocalDanmakuParser.parseFile(xmlPath);
    }
    _danmakuCursor = 0;
    barrageController.clear();
  }

  void _dispatchDanmaku(double seconds) {
    if (!danmakuEnabled.value || _danmakuEntries.isEmpty) return;
    while (_danmakuCursor < _danmakuEntries.length) {
      final entry = _danmakuEntries[_danmakuCursor];
      if (entry.time > seconds) break;
      barrageController.send(
        BarrageItem(
          content: entry.text,
          userId: entry.userName,
          userName: entry.userName,
          textColor: Color.fromARGB(255, entry.r, entry.g, entry.b),
        ),
      );
      _danmakuCursor++;
    }
  }

  Future<void> playAt(int index) async {
    if (_switching) return;
    if (index < 0 || index >= group.value.mp4s.length) return;
    if (index == currentIndex.value) return;
    _switching = true;
    try {
      currentIndex.value = index;
      final entry = group.value.mp4s[index];
      isBuffering.value = true;
      currentPosition.value = Duration.zero;
      totalDuration.value = Duration.zero;
      danmakuEnabled.value = currentDanmakuPath != null;
      _suppressDanmakuDispatch = true;
      barrageController.clear();
      _loadDanmaku(currentDanmakuPath);

      await _player.open(Media(_toFileUrl(entry.path)));
      await _player.setVolume(volume.value * 100);
      await _player.setRate(playbackSpeed.value);
      barrageController.setClockScale(playbackSpeed.value);
      _suppressDanmakuDispatch = false;
    } catch (e) {
      debugPrint('LocalPlaybackController.playAt error: $e');
      _suppressDanmakuDispatch = false;
    } finally {
      _switching = false;
    }
  }

  Future<void> togglePlayPause() async {
    await _player.playOrPause();
  }

  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
    _resetDanmakuCursor();
  }

  Future<void> seekRelative(Duration offset) async {
    final pos = _player.state.position;
    final dur = _player.state.duration;
    final rawTarget = pos + offset;
    final target = rawTarget < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && rawTarget > dur ? dur : rawTarget);
    await _player.seek(target);
    _resetDanmakuCursor();
  }

  void _resetDanmakuCursor() {
    barrageController.clear();
    final pos = _player.state.position.inMilliseconds / 1000.0;
    int lo = 0, hi = _danmakuEntries.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_danmakuEntries[mid].time <= pos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _danmakuCursor = lo;
  }

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value * 100);
  }

  double? _preMuteVolume;
  Future<void> toggleMute() async {
    if (volume.value > 0) {
      _preMuteVolume = volume.value;
      await setVolume(0);
    } else {
      await setVolume(_preMuteVolume ?? 1.0);
    }
  }

  Future<void> setSpeed(double speed) async {
    final v = speed.clamp(0.25, 16.0);
    playbackSpeed.value = v;
    await _player.setRate(v);
    barrageController.setClockScale(v);
    showSpeedHud();
  }

  void showSpeedHud() {
    _speedHudHideTimer?.cancel();
    isSpeedHudVisible.value = true;
    _speedHudHideTimer = Timer(_speedHudHideDelay, () {
      isSpeedHudVisible.value = false;
    });
  }

  Future<void> nextFile() async {
    if (currentIndex.value < group.value.mp4s.length - 1) {
      await playAt(currentIndex.value + 1);
    }
  }

  Future<void> prevFile() async {
    if (currentIndex.value > 0) {
      await playAt(currentIndex.value - 1);
    }
  }

  void toggleDanmaku() {
    if (currentDanmakuPath == null) return;
    danmakuEnabled.value = !danmakuEnabled.value;
    if (!danmakuEnabled.value) {
      barrageController.clear();
    }
  }

  Future<void> deleteEntryAt(int index) async {
    if (index < 0 || index >= group.value.mp4s.length) return;

    final entry = group.value.mp4s[index];
    final wasPlayingThis = (index == currentIndex.value);

    if (wasPlayingThis) {
      _switching = true;
      await _player.stop();
      barrageController.clear();
      _danmakuEntries = const [];
      _danmakuCursor = 0;
    }

    try {
      final mp4File = File(entry.path);
      if (await mp4File.exists()) await mp4File.delete();
      final xmlPath = p.setExtension(entry.path, '.xml');
      final xmlFile = File(xmlPath);
      if (await xmlFile.exists()) await xmlFile.delete();
    } catch (e) {
      debugPrint('LocalPlaybackController.deleteEntryAt error: $e');
    }

    group.value.mp4s.removeAt(index);

    if (group.value.mp4s.isEmpty) {
      _switching = false;
      currentIndex.value = -1;
      isPlaying.value = false;
      isBuffering.value = false;
      currentPosition.value = Duration.zero;
      totalDuration.value = Duration.zero;
      danmakuEnabled.value = false;
    } else if (wasPlayingThis) {
      final nextIndex = index < group.value.mp4s.length ? index : group.value.mp4s.length - 1;
      await playAt(nextIndex);
    } else if (index < currentIndex.value) {
      currentIndex.value = currentIndex.value - 1;
    }

    group.refresh();
  }

  Future<void> openCurrentDirectory() async {
    final path = currentMp4Path;
    if (path == null) return;
    final dir = p.dirname(path);
    try {
      await FileUtils.openFileOrUrl(dir);
    } catch (e) {
      debugPrint('LocalPlaybackController.openCurrentDirectory error: $e');
    }
  }

  Future<void> refreshPlaylist() async {
    final sw = Stopwatch()..start();
    final currentDirPath = currentMp4Path != null
        ? p.dirname(currentMp4Path!)
        : p.join((await CacheService.to.getRecordDir()).path, group.value.platform, group.value.safeNick);
    final dir = Directory(currentDirPath);
    final mp4Map = <String, Mp4Entry>{};

    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: false, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.mp4')) continue;
        try {
          final stat = await entity.stat();
          mp4Map[entity.path] = Mp4Entry(
            path: entity.path,
            platform: group.value.platform,
            safeNick: group.value.safeNick,
            modified: stat.modified,
            size: stat.size,
          );
        } catch (_) {}
      }
    }

    for (final mp4 in mp4Map.values) {
      await mp4.mergeSidecar();
    }

    final newList = mp4Map.values.toList()..sort((a, b) => b.modified.compareTo(a.modified));

    final wasPlayingPath = currentMp4Path;
    group.value.mp4s
      ..clear()
      ..addAll(newList);

    if (newList.isEmpty) {
      currentIndex.value = -1;
    } else if (wasPlayingPath != null) {
      final idx = newList.indexWhere((e) => e.path == wasPlayingPath);
      currentIndex.value = idx >= 0 ? idx : 0;
    } else {
      currentIndex.value = 0;
    }

    group.refresh();

    final elapsed = sw.elapsedMilliseconds;
    if (elapsed < 600) {
      await Future<void>.delayed(Duration(milliseconds: 600 - elapsed));
    }
    playlistRefreshController.finishRefresh(IndicatorResult.success);
  }

  void enableController() {
    _hideTimer?.cancel();
    _hideTimer = null;
    showController.value = true;
    _armHideTimer();
  }

  /// 重新 arm auto-hide Timer；鼠标仍在控件区时跳过。
  ///
  /// 与 [enableController] 分离：后者用于用户主动操作后（切换全屏等），
  /// 需要先强制 showController=true 再 arm；本方法仅用于鼠标离场，
  /// 或 synthetic onExit（由 BottomControlSurface visible=false 触发
  /// 的 ControlHoverRegion.didUpdateWidget → _relinquish → onMouseExitController），
  /// 此时不能改 visible，也不能在鼠标仍在场时 arm。
  void _armHideTimer() {
    if (_isMouseOverController) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(_controllerHideDelay, _doHideController);
  }

  void stopHideController() {
    _hideTimer?.cancel();
    _hideTimer = null;
    showController.value = true;
  }

  void holdController() {
    _hideTimer?.cancel();
    _hideTimer = null;
    showController.value = true;
  }

  void releaseController() {
    enableController();
  }

  void _doHideController() {
    _hideTimer = null;
    // Timer 触发时再检查一次——如果鼠标在 Timer 等待期间又移回控件区，
    // 不能真正隐藏。这与 live_play 的 _handleControllerHideDeadline 双重守卫一致。
    if (_isMouseOverController) return;
    if (isMenuOpen.value) {
      enableController();
      return;
    }
    if (showLocked.value) return;
    showController.value = false;
  }

  void onMouseEnterController(Object owner) {
    // Set.add 返回 false 表示同一 owner 已经 add 过（重复 onEnter），
    // 跳过避免 holdController 重复执行。
    if (!_controlHoverOwners.add(owner)) return;
    holdController();
  }

  void onMouseExitController(Object owner) {
    // Set.remove 返回 false 表示没有真实设备持有该 owner：
    // 要么 ControlHoverRegion.didUpdateWidget/dispose 触发了 synthetic exit，
    // 要么同一 owner 已经被 remove 过。两种情况都不应 arm auto-hide Timer。
    if (!_controlHoverOwners.remove(owner)) return;
    _armHideTimer();
  }

  Future<void> toggleFullScreen() async {
    showLocked.value = false;
    stopHideController();
    try {
      if (!await windowManager.isFullScreen()) {
        isWindowFullscreen.value = false;
        GlobalPlayerState.to.isWindowFullscreen.value = false;
        await windowManager.setFullScreen(true);
        isFullscreen.value = true;
        GlobalPlayerState.to.isFullscreen.value = true;
      } else {
        await windowManager.setFullScreen(false);
        isFullscreen.value = false;
        GlobalPlayerState.to.isFullscreen.value = false;
      }
    } finally {
      enableController();
    }
  }

  void toggleWindowFullScreen() {
    showLocked.value = false;
    stopHideController();
    isWindowFullscreen.value = !isWindowFullscreen.value;
    GlobalPlayerState.to.isWindowFullscreen.value = isWindowFullscreen.value;
    if (isWindowFullscreen.value) {
      isFullscreen.value = false;
      GlobalPlayerState.to.isFullscreen.value = false;
    }
    enableController();
  }

  Future<void> toggleAlwaysOnTop() async {
    final onTop = !isAlwaysOnTop.value;
    isAlwaysOnTop.value = onTop;
    await windowManager.setAlwaysOnTop(onTop);
    enableController();
  }

  void toggleAudioOnly() {
    isAudioOnly.value = !isAudioOnly.value;
    enableController();
  }

  Future<void> togglePiP() async {
    showLocked.value = false;
    stopHideController();
    try {
      final ratio = (videoWidth.value > 0 && videoHeight.value > 0) ? videoWidth.value / videoHeight.value : 16.0 / 9.0;
      await WindowHelper.instance.togglePiP(ratio);
      isPipMode.value = WindowHelper.instance.currentMode == WindowLayoutMode.pip;
      GlobalPlayerState.to.isPipMode.value = isPipMode.value;
      if (isPipMode.value) {
        isPipAlwaysOnTop.value = true;
        await windowManager.setAlwaysOnTop(true);
        // 进入小窗时窗口可能在静止鼠标下移动缩放，MouseRegion 的悬停状态会滞留
        // （指针不移动就不再触发 onExit），导致悬浮控件常驻不消。重置为未悬停，
        // 此后指针在窗内的任意移动会通过 onHover 重新显示控件。
        isPipHovered.value = false;
      } else {
        isPipAlwaysOnTop.value = false;
      }
    } catch (e) {
      debugPrint('LocalPlaybackController.togglePiP error: $e');
      ToastUtil.show(i18n('mini_pip_play_failed'));
    } finally {
      enableController();
    }
  }

  Future<void> exitPiP() async {
    if (WindowHelper.instance.currentMode != WindowLayoutMode.pip) return;
    isPipAlwaysOnTop.value = false;
    await WindowHelper.instance.exitPiP();
    isPipMode.value = false;
    GlobalPlayerState.to.isPipMode.value = false;
    enableController();
  }

  Future<void> togglePipAlwaysOnTop() async {
    final next = !isPipAlwaysOnTop.value;
    isPipAlwaysOnTop.value = next;
    await windowManager.setAlwaysOnTop(next);
  }

  Future<void> takeScreenshot() async {
    try {
      final directory = SettingsService.to.app.screenshotDirectory.v;
      if (directory.isEmpty) {
        ToastUtil.show(i18n('please_set_screenshot_directory'));
        return;
      }
      final dir = Directory(directory);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final bytes = await _player.screenshot();
      if (bytes == null || bytes.isEmpty) {
        ToastUtil.show(i18n('screenshot_failed'));
        return;
      }
      final now = DateTime.now();
      final ts =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final name = currentEntry != null
          ? '${p.basenameWithoutExtension(currentEntry!.path)}_$ts.png'
          : 'screenshot_$ts.png';
      final file = File('$directory${p.separator}$name');
      await file.writeAsBytes(bytes, flush: true);
      ToastUtil.show(i18n('screenshot_saved'));
    } catch (e) {
      debugPrint('LocalPlaybackController.takeScreenshot error: $e');
      ToastUtil.show(i18n('screenshot_failed'));
    }
  }

  @override
  void onClose() {
    _switching = true;
    _hideTimer?.cancel();
    _speedHudHideTimer?.cancel();
    playlistRefreshController.dispose();
    _posSub?.cancel();
    _playingSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _videoWidthSub?.cancel();
    _videoHeightSub?.cancel();
    if (WindowHelper.instance.currentMode == WindowLayoutMode.pip) {
      try {
        WindowHelper.instance.exitPiP();
      } catch (_) {}
    }
    GlobalPlayerState.to
      ..isFullscreen.value = false
      ..isWindowFullscreen.value = false
      ..isPipMode.value = false;
    unawaited(_restoreWindowState());
    _player.dispose();
    super.onClose();
  }
}
