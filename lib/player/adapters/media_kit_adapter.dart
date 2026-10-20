import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

import '../models/player_state.dart';
import '../models/player_exception.dart';
import '../models/player_error_type.dart';

import 'package:pure_live/common/index.dart';

import '../interface/unified_player_interface.dart';

import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:pure_live/player/models/player_engine.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/player/utils/live_buffer_policy.dart';
import 'package:pure_live/player/utils/anime4k_shader_manager.dart';
import 'package:pure_live/player/utils/mpv_platform_profile.dart';
import 'package:pure_live/common/utils/latest_async_value_queue.dart';
import 'package:pure_live/player/interface/media_kit_player_accessor.dart';
import 'package:pure_live/player/core/player_error_classifier.dart';
import 'package:pure_live/player/core/source_event_fence.dart';
import 'package:pure_live/player/core/playback_proxy_policy.dart';
import 'package:pure_live/core/common/log.dart';

@visibleForTesting
({int width, int height})? resolveMediaKitDisplaySize(VideoParams params) {
  final size = resolveVideoParamsDisplaySize(params);
  return size == null ? null : (width: size.width, height: size.height);
}

@visibleForTesting
bool shouldPublishMediaKitPlaying(bool nativePlaying) => nativePlaying;

class MediaKitAdapter
    implements
        UnifiedPlayer,
        MediaKitPlayerAccessor,
        VideoFitAwarePlayer,
        SourceTransitionAwarePlayer,
        PrivateInputAwarePlayer,
        DecoderRecoveryAwarePlayer,
        VideoFrameProgressAwarePlayer {
  MediaKitAdapter() {
    _audioModeTransitions = LatestAsyncValueQueue<bool>(_applyAudioOnly);
  }

  bool _privateInput = false;
  String? _nextSourceIdentity;
  String? _currentSourceIdentity;
  @override
  void setPrivateInput(bool value, {String? sourceIdentity}) {
    _privateInput = value;
    _nextSourceIdentity = sourceIdentity;
  }

  /// Exercises the real source lifecycle and subscriptions without a renderer.
  /// The supplied player owns its event contract; widget/native rendering is
  /// intentionally outside this deterministic adapter-test entry point.
  @visibleForTesting
  factory MediaKitAdapter.headlessForTest(Player player, {String preferredHardwareDecoder = 'no'}) {
    return MediaKitAdapter()
      .._player = player
      .._preferredHardwareDecoder = preferredHardwareDecoder
      .._initialized = true;
  }

  /// Applies the shared low-latency live-stream mpv property set to a native
  /// (libmpv) player platform.
  ///
  /// 单一事实来源：主播放器（[MediaKitAdapter.init]）与 multiview 每格播放器
  /// 都必须使用同一套属性（seek 白名单、探测时长、LiveBufferPolicy 缓冲上限、
  /// 网络超时、音频驱动、代理、macOS 硬解关闭），避免两处配置漂移。
  static Future<void> applyNativeLiveProperties(dynamic native) async {
    // 壁纸模式下让 mpv 背景透明，使播放器宽高比不匹配时的黑边透出壁纸。
    // 注意：此属性在 DXGI 渲染路径下可能被忽略，需配合 native 层处理。
    await native.setProperty('background', 'transparent');

    await native.setProperty('force-seekable', 'yes');

    await native.setProperty(
      'protocol_whitelist',
      'httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt',
    );

    await native.setProperty('demuxer-lavf-probesize', '2097152');

    // Live FLV/HLS streams need a short probe rather than a long-file
    // analysis pass.  This reduces the black-screen interval before the
    // first decoded frame while retaining enough data for codec detection.
    await native.setProperty('demuxer-lavf-analyzeduration', '2');

    // mpv's generic defaults keep a large seek-oriented forward/backward
    // cache. Live rooms are not meaningfully seekable, so retaining that
    // much compressed data only makes long Windows/Android sessions appear
    // to grow indefinitely. Keep this shared with the tested policy rather
    // than scattering raw byte strings through the adapter.
    final preset = SettingsService.to.player.liveBufferPreset.v;
    await LiveBufferPolicy.apply((name, value) async => await native.setProperty(name, value), preset: preset);

    await native.setProperty('network-timeout', '15');

    final scaleAlgo = SettingsService.to.player.videoScaleAlgorithm.v;
    if (scaleAlgo != 'auto') {
      await native.setProperty('scale', scaleAlgo);
    }

    // Anime4K 超分着色器：默认关闭，开启时从 assets 提取 .glsl 到磁盘后挂载。
    // glsl-shaders 是列表选项，必须用 change-list 命令（clr + 逐个 append），
    // 不能用逗号拼接字符串——否则 mpv 会把整串当成单个文件名。
    if (SettingsService.to.player.enableAnime4K.v) {
      final quality = SettingsService.to.player.anime4KQuality.v;
      final shaderPaths = await Anime4KShaderManager.resolveShaderPaths(quality: quality);
      if (shaderPaths.isNotEmpty) {
        await _applyGlslShaders(native, shaderPaths);
      } else {
        Log.w('[MPV] anime4k enabled but no shader files found in assets/shaders/');
      }
    }

    // Ask mpv to abandon a broken hardware decoder after the first consecutive
    // frame failure. This preserves the low-power fast path on compatible
    // devices while making unsupported profiles fall back to software instead
    // of leaving a black Surface behind. mpv's larger default can skip several
    // live packets before the fallback is attempted.
    await native.setProperty('hwdec-software-fallback', '1');

    final audioOutput = effectiveMpvAudioOutputDriverForPlatform(
      customOutput: SettingsService.to.player.customPlayerOutput.v,
      configuredDriver: SettingsService.to.player.audioOutputDriver.v,
      platform: defaultTargetPlatform,
    );
    if (audioOutput != null) {
      await native.setProperty('ao', audioOutput);
    }

    // Multiview also calls this shared initializer. Keep its media routing;
    // the main adapter applies it again per source, bypassing private input.
    await native.setProperty('http-proxy', PlaybackProxyPolicy.currentNativeUrl(privateInput: false));

    if (PlatformUtils.isMacOS) {
      await native.setProperty('hwdec', 'no');
    }

    if (PlatformUtils.isWindows && SettingsService.to.player.enableRtxVsr.value) {
      await native.setProperty('hwdec', 'd3d11va');
      await native.setProperty('vf', 'd3d11vpp=scale=2:scaling-mode=nvidia');
    }
  }

  /// 在 VideoController（vo）创建后重新应用视频增强属性。
  ///
  /// mpv 的 `scale` 与 `glsl-shaders` 依赖视频输出链初始化，
  /// 在 vo 创建前设置可能被忽略。此方法必须在 VideoController 创建后调用。
  static Future<void> applyVideoEnhancementProperties(dynamic native) async {
    // 视频增强（scale / glsl-shaders）依赖 GPU 后处理管线。
    // 若使用零拷贝硬件解码（hwdec=auto/d3d11va），解码帧直接上屏，
    // 着色器与 scale 都会被跳过。强制切换到 copy 模式让帧经过着色器。
    final needsShaderPipeline =
        SettingsService.to.player.enableAnime4K.v || SettingsService.to.player.videoScaleAlgorithm.v != 'auto';
    if (needsShaderPipeline) {
      String? hwdec;
      try {
        hwdec = await native.getProperty('hwdec') as String?;
      } catch (_) {}
      final copyHwdec = hwdec ?? '';
      if (copyHwdec != 'no' && !copyHwdec.endsWith('-copy') && copyHwdec.isNotEmpty) {
        await native.setProperty('hwdec', 'auto-copy');
      }
    }

    final scaleAlgo = SettingsService.to.player.videoScaleAlgorithm.v;
    if (scaleAlgo != 'auto') {
      await native.setProperty('scale', scaleAlgo);
    }

    if (SettingsService.to.player.enableAnime4K.v) {
      final shaderPaths = await Anime4KShaderManager.resolveShaderPaths(
        quality: SettingsService.to.player.anime4KQuality.v,
      );
      if (shaderPaths.isNotEmpty) {
        await _applyGlslShaders(native, shaderPaths);
      }
    }
  }

  /// 用 change-list 命令挂载 GLSL 着色器列表。
  ///
  /// `glsl-shaders` 是 mpv 的列表属性，`setProperty` 会把整串当成单个条目。
  /// 正确做法：先 `clr` 清空，再逐个 `append`。
  static Future<void> _applyGlslShaders(dynamic native, List<String> shaderPaths) async {
    await native.command(['change-list', 'glsl-shaders', 'clr', '']);
    for (final path in shaderPaths) {
      await native.command(['change-list', 'glsl-shaders', 'append', path]);
    }
  }

  late final Player _player;

  late final VideoController _controller;

  bool _initialized = false;

  bool _disposed = false;

  bool _listenerBound = false;

  bool _nativePathObserved = false;

  bool _nativeFramePropertiesObserved = false;

  bool _usesNativeFrameProbe = false;

  String? _currentUrl;

  bool _isAudioOnly = false;

  final SourceEventFence _sourceFence = SourceEventFence();

  bool _sourceTransitionPrepared = false;

  bool _sourceHasVideoFrame = false;

  bool _sourceHasAudioFrame = false;

  String _preferredHardwareDecoder = 'no';

  String? _softwareDecoderFallbackUrl;

  int _sourceProgressRevision = 0;

  Timer? _pendingNativeErrorTimer;

  _NativeDiagnostic? _openingNativeDiagnostic;

  PlayerException? _pendingNativeError;

  int? _pendingNativeErrorGeneration;

  int _pendingNativeErrorProgressRevision = 0;

  NativeDiagnosticComponent _pendingNativeErrorComponent = NativeDiagnosticComponent.either;

  String? _lastEmittedNativeError;

  DateTime? _lastEmittedNativeErrorAt;

  int? _lastEmittedNativeErrorGeneration;

  BoxFit _videoFit = BoxFit.contain;

  late final LatestAsyncValueQueue<bool> _audioModeTransitions;

  // =========================
  // subjects
  // =========================

  final _stateSubject = BehaviorSubject<PlayerState>.seeded(PlayerState.idle);

  final _playingSubject = BehaviorSubject<bool>.seeded(false);

  final _loadingSubject = BehaviorSubject<bool>.seeded(false);

  final _errorSubject = PublishSubject<PlayerException>();

  final _completeSubject = BehaviorSubject<bool>.seeded(false);

  final _widthSubject = BehaviorSubject<int?>.seeded(null);

  final _heightSubject = BehaviorSubject<int?>.seeded(null);

  final _videoFrameProgressSubject = PublishSubject<int>();

  VoidCallback? _videoFrameRevisionListener;

  // =========================
  // subscriptions
  // =========================

  final List<StreamSubscription> _subscriptions = [];

  StreamSubscription? _playingSub;

  StreamSubscription? _bufferingSub;

  StreamSubscription? _videoParamsSub;

  StreamSubscription? _audioParamsSub;

  StreamSubscription? _completeSub;

  StreamSubscription? _errorSub;

  StreamSubscription? _logSub;

  StreamSubscription? _positionSub;

  StreamSubscription? _durationSub;

  Duration _lastPosition = Duration.zero;

  Duration _lastDuration = Duration.zero;

  /// Target of the most recent interactive seek, used as the arithmetic base
  /// for repeated arrow-key seeks while `time-pos` has not caught up yet.
  /// mpv's native relative seeks accumulate against its internal playback
  /// time; with absolute seeks we emulate that so quick repeated presses move
  /// by N*step instead of re-seeking the same spot.
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekAt;

  /// Seekable ranges reported by mpv's `demuxer-cache-state`.
  ///
  /// Each entry is `(start, end)` in the same time base as `time-pos`
  /// (mpv adds `ts_offset` when serialising them). These ranges are the
  /// *only* positions a seek may target without making mpv drop the cache
  /// and reconnect the live stream (see `switch_to_fresh_cache_range` in
  /// mpv's demux.c).
  List<({Duration start, Duration end})> _seekableRanges = const [];

  /// Back-buffer bytes reported by `demuxer-cache-state` (`bw-bytes`). Used to
  /// estimate how much of the oldest cached content has been evicted once the
  /// back buffer saturates — mpv's `seekable-ranges` do not always shrink
  /// their left edge in sync with the actual eviction, so without this the
  /// progress bar would let the user drag into a "dead zone" that forces a
  /// live-stream reconnect.
  int _backBufferBytes = 0;

  /// Current video + audio bitrate in bits per second, polled alongside the
  /// cache state. Falls back to zero when mpv does not report it, in which
  /// case no dead-zone estimate is produced and the seekable ranges are used
  /// as-is.
  double _videoBitrate = 0.0;
  double _audioBitrate = 0.0;

  /// Polls `demuxer-cache-state` because mpv does not push property-change
  /// events for this structured property. The `duration` property is polled
  /// as well so the live timeline length (which keeps growing for live
  /// streams) stays in sync even if the duration stream event is delayed.
  Timer? _cacheStateTimer;

  /// When true, eviction / reconnect toasts are suppressed so we don't spam
  /// the user during a rapid drag-seek gesture. The UI layer sets this flag
  /// during `onHorizontalDragStart` and clears it on `onHorizontalDragEnd`.
  bool _suppressSeekToast = false;

  /// repeating post-seek verifier started by [_seekAbsolute]. Confirms the
  /// decoder actually landed near the requested position; a land far below
  /// the target means mpv performed a silent reconnect (PTS base reset).
  Timer? _reconnectWatch;

  /// Bumped whenever the mpv timeline is reset (reconnect recovery, source
  /// switch). `_refreshCacheState` captures this before its awaits and
  /// discards its results if the epoch moved, so a property read that was
  /// made against the pre-reconnect timeline can never write back a stale
  /// large `duration` / old cache ranges after the reset.
  int _cacheStateEpoch = 0;

  // =========================
  // init
  // =========================

  @override
  Future<void> init({bool audioOnly = false}) async {
    if (_initialized) return;
    // Always create a normal video output. Audio-only is a reversible track
    // selection on the same player; constructing a `vo=null` controller made
    // returning to video depend on destroying and recreating the native player.
    _disposed = false;

    // This is application presentation state. On Android the attached
    // media_kit VideoController is the sole owner of mpv's `vid` property.
    _isAudioOnly = false;

    _listenerBound = false;

    _currentUrl = null;

    try {
      _stateSubject.add(PlayerState.initializing);

      MediaKit.ensureInitialized();
      _player = Player();

      if (_player.platform is NativePlayer) {
        final native = _player.platform as dynamic;
        // Live adapters use one explicit seekability override. The upstream
        // Android workaround duplicated this native property write.
        await applyNativeLiveProperties(native);
      }

      // =========================
      // controller
      // =========================
      final platform = defaultTargetPlatform;
      final androidCompatMode = PlatformUtils.isAndroid && SettingsService.to.player.playerCompatMode.v;
      final videoOutputDriver = normalizeMpvVideoOutputDriverForPlatform(
        SettingsService.to.player.videoOutputDriver.v,
        platform,
      );
      final hardwareDecoder = normalizeMpvHardwareDecoderForPlatform(
        SettingsService.to.player.videoHardwareDecoder.v,
        platform,
      );

      _preferredHardwareDecoder = PlatformUtils.isMacOS
          ? 'no'
          : androidCompatMode
          ? 'mediacodec'
          : SettingsService.to.player.customPlayerOutput.v
          ? hardwareDecoder
          : SettingsService.to.player.enableCodec.v
          ? 'auto-safe'
          : 'no';

      _controller = androidCompatMode
          ? VideoController(
              _player,
              configuration: const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec'),
            )
          : SettingsService.to.player.customPlayerOutput.v
          ? VideoController(
              _player,
              configuration: VideoControllerConfiguration(
                vo: videoOutputDriver,
                hwdec: PlatformUtils.isMacOS ? 'no' : hardwareDecoder,
                enableHardwareAcceleration: !PlatformUtils.isMacOS,
              ),
            )
          : VideoController(
              _player,
              configuration: VideoControllerConfiguration(
                enableHardwareAcceleration: PlatformUtils.isMacOS ? false : SettingsService.to.player.enableCodec.v,
                hwdec: PlatformUtils.isMacOS ? 'no' : null,
                androidAttachSurfaceAfterVideoParameters: false,
              ),
            );

      // VideoController 创建后重新应用视频增强属性（scale、glsl-shaders），
      // 这些属性依赖 vo 初始化，在 init 阶段设置可能被忽略。
      if (_player.platform is NativePlayer) {
        await applyVideoEnhancementProperties(_player.platform as dynamic);
      }

      if (PlatformUtils.isWindows) {
        var lastRevision = _controller.frameRevision.value;
        void handleFrameRevision() {
          if (_disposed) return;
          final revision = _controller.frameRevision.value;
          if (revision == lastRevision) return;
          lastRevision = revision;
          _videoFrameProgressSubject.add(revision);
        }

        _videoFrameRevisionListener = handleFrameRevision;
        _controller.frameRevision.addListener(handleFrameRevision);
      }

      await _bindListeners(sourceGeneration: _sourceFence.generation);

      _initialized = true;

      _stateSubject.add(PlayerState.initialized);
    } catch (e, s) {
      final exception = PlayerException(
        message: 'MediaKit init failed',
        type: PlayerErrorType.initialization,
        error: e,
        stackTrace: s,
      );

      _safeAddError(exception);

      throw exception;
    }
  }

  // =========================
  // datasource
  // =========================

  @override
  void beginSourceTransition() {
    if (_disposed) return;
    _prepareSourceTransition();
    _sourceTransitionPrepared = true;
  }

  void _prepareSourceTransition({String? url}) {
    _pendingNativeErrorTimer?.cancel();
    _pendingNativeErrorTimer = null;
    _pendingNativeError = null;
    _pendingNativeErrorGeneration = null;
    _pendingNativeErrorComponent = NativeDiagnosticComponent.either;
    _openingNativeDiagnostic = null;
    _sourceHasVideoFrame = false;
    _sourceHasAudioFrame = false;
    _sourceProgressRevision = 0;
    _sourceFence.begin(url ?? _currentUrl);
    _playingSubject.add(false);
    _loadingSubject.add(true);
    _completeSubject.add(false);
    _widthSubject.add(null);
    _heightSubject.add(null);
  }

  Future<List<String>> _currentNativeSourcePaths() async {
    if (_player.platform is! NativePlayer) return <String>[_currentUrl ?? ''];
    try {
      final path = await (_player.platform as dynamic).getProperty('path') as String;
      return <String>[path];
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _bindNativeSourceObservers(int generation) async {
    if (_disposed || _player.platform is! NativePlayer) return;
    final native = _player.platform as dynamic;

    if (_nativePathObserved) {
      try {
        await native.unobserveProperty('path');
      } catch (_) {}
      _nativePathObserved = false;
    }
    if (_nativeFramePropertiesObserved) {
      try {
        await native.unobserveProperty('video-frame-info/picture-type');
        await native.unobserveProperty('estimated-vf-fps');
      } catch (_) {}
      _nativeFramePropertiesObserved = false;
      _usesNativeFrameProbe = false;
    }
    if (_disposed || generation != _sourceFence.generation) return;

    // Every callback captures the source lease that installed it. Reading the
    // fence's current generation inside a delayed callback relabels an old
    // room/quality event as new and was the root of stale dimensions, repeated
    // danmaku recovery and spurious decoder errors after source replacement.
    await native.observeProperty('path', (String path) async {
      _handleNativePath(path, generation);
    });
    _nativePathObserved = true;
    await native.observeProperty('video-frame-info/picture-type', (String value) async {
      _handleDecodedVideoFrameSignal(value, generation);
    });
    await native.observeProperty('estimated-vf-fps', (String value) async {
      _handleDecodedVideoFrameRate(value, generation);
    });
    _nativeFramePropertiesObserved = true;
    _usesNativeFrameProbe = true;
  }

  void _handleNativePath(String path, int generation) {
    if (_disposed || generation != _sourceFence.generation) return;
    _sourceFence.observeNativeSources(<String>[path]);
    if (_sourceFence.isOpening) return;
    if (!_sourceFence.accepts(generation)) return;
    _publishCurrentNativeSnapshot(generation);
    unawaited(_refreshCurrentNativeReadinessSnapshot(generation));
    _drainDeferredNativeDiagnostic(generation);
  }

  Future<void> _refreshCurrentNativeReadinessSnapshot(int generation) async {
    if (_disposed || !_sourceFence.accepts(generation) || _player.platform is! NativePlayer) return;
    final native = _player.platform as dynamic;
    try {
      final pictureType = (await native.getProperty('video-frame-info/picture-type') as String).trim();
      if (_sourceFence.accepts(generation)) _handleDecodedVideoFrameSignal(pictureType, generation);
    } catch (_) {
      // The property is unavailable until the first decoded video frame.
    }
    try {
      final fps = (await native.getProperty('estimated-vf-fps') as String).trim();
      if (_sourceFence.accepts(generation)) _handleDecodedVideoFrameRate(fps, generation);
    } catch (_) {
      // The property is unavailable when this source has no decoded video.
    }
    try {
      final audioFormat = (await native.getProperty('audio-params/format') as String).trim();
      if (audioFormat.isNotEmpty && _sourceFence.accepts(generation)) {
        _markDecodedAudioFrame(generation);
      }
    } catch (_) {
      // The property is unavailable until the audio decoder is configured.
    }
  }

  void _handleDecodedVideoFrameSignal(String value, int generation) {
    final pictureType = value.trim().toUpperCase();
    if (pictureType != 'I' && pictureType != 'P' && pictureType != 'B') return;
    _markDecodedVideoFrame(generation);
  }

  void _handleDecodedVideoFrameRate(String value, int generation) {
    final fps = double.tryParse(value.trim());
    if (fps == null || !fps.isFinite || fps <= 0) return;
    _markDecodedVideoFrame(generation);
  }

  void _markDecodedVideoFrame(int generation) {
    if (_disposed || !_sourceFence.accepts(generation)) return;
    _sourceHasVideoFrame = true;
    _openingNativeDiagnostic = null;
    _sourceProgressRevision++;
    // Native frame probes are progress heartbeats, not playback-state
    // transitions. Republishing playing/loading on every decoded frame made
    // PlayerManager recreate watchdog timers and notify UI listeners dozens of
    // times per second on Windows. Keep the dedicated frame stream hot while
    // emitting state only when it actually changes.
    _publishMediaProgressState();
    _cancelRecoveredNativeError(NativeDiagnosticComponent.video);
  }

  void _markDecodedAudioFrame(int generation) {
    if (_disposed || !_sourceFence.accepts(generation)) return;
    _sourceHasAudioFrame = true;
    _sourceProgressRevision++;
    if (_isAudioOnly && _player.state.playing) {
      _publishMediaProgressState();
    }
    _cancelRecoveredNativeError(NativeDiagnosticComponent.audio);
  }

  void _publishMediaProgressState() {
    // A queued frame or playing=true may arrive while mpv is still waiting
    // for cache. Only the native buffering contract ends that episode; media
    // readiness must not retire PlayerManager's independent stall watchdog.
    final buffering = _player.state.buffering;
    if (_loadingSubject.value != buffering) _loadingSubject.add(buffering);
    if (_player.state.playing && !_playingSubject.value) _playingSubject.add(true);
    if (buffering) {
      if (_stateSubject.value != PlayerState.buffering) _stateSubject.add(PlayerState.buffering);
    } else if (_player.state.playing) {
      if (_stateSubject.value != PlayerState.playing) _stateSubject.add(PlayerState.playing);
    }
  }

  @override
  Future<bool> prepareSoftwareDecoderFallback(PlayerException error) async {
    final url = _currentSourceIdentity;
    if (_disposed ||
        _isAudioOnly ||
        error.type != PlayerErrorType.codec ||
        error.code?.startsWith('audio_') == true ||
        url == null ||
        url.isEmpty ||
        _preferredHardwareDecoder == 'no' ||
        _softwareDecoderFallbackUrl == url) {
      return false;
    }

    // Only mark the next open. Changing `hwdec` while the failing source still
    // owns the decoder can synchronously emit another error into the recovery
    // stack and race the source-generation fence.
    _softwareDecoderFallbackUrl = url;
    return true;
  }

  Future<void> _applyDecoderPolicyForSource(String url) async {
    if (_player.platform is! NativePlayer) return;
    final useSoftware = _softwareDecoderFallbackUrl == url;
    if (!useSoftware) _softwareDecoderFallbackUrl = null;
    await (_player.platform as dynamic).setProperty('hwdec', useSoftware ? 'no' : _preferredHardwareDecoder);
  }

  @override
  Future<void> setDataSource(
    String url,
    List<String> playUrls,
    Map<String, String> headers, {
    LiveRoom? room,
    bool audioOnly = false,
  }) async {
    if (_disposed) return;
    final privateInput = _privateInput;
    final sourceIdentity = _nextSourceIdentity ?? url;
    _privateInput = false;
    _nextSourceIdentity = null;
    _currentSourceIdentity = sourceIdentity;
    // An explicit manager play is a new source generation even if the URL is
    // textually identical. Decoder recovery, manual retry and signed CDN URLs
    // may all reopen the same string with different native policy. Skipping
    // here used to clear the public subjects in beginSourceTransition and then
    // leave them permanently empty; it also made software-decoder fallback a
    // no-op for the exact URL that had just failed in hardware.
    _currentUrl = url;
    _isAudioOnly = audioOnly;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _seekableRanges = const [];
    _backBufferBytes = 0;
    _reconnectWatch?.cancel();
    _reconnectWatch = null;
    _cacheStateEpoch++;
    _videoBitrate = 0.0;
    _audioBitrate = 0.0;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    if (_sourceTransitionPrepared) {
      // The manager reset the public source state before rebinding its
      // source-scoped listeners. Associate that generation with this URL.
      _sourceFence.retargetOpening(url);
      _sourceTransitionPrepared = false;
    } else {
      _prepareSourceTransition(url: url);
    }
    final sourceGeneration = _sourceFence.generation;

    try {
      _stateSubject.add(PlayerState.preparing);

      await _bindNativeSourceObservers(sourceGeneration);
      await _bindListeners(sourceGeneration: sourceGeneration, force: true);
      if (_disposed || sourceGeneration != _sourceFence.generation) return;

      await _applyDecoderPolicyForSource(sourceIdentity);

      if (_player.platform is NativePlayer) {
        await (_player.platform as dynamic).setProperty(
          'http-proxy',
          PlaybackProxyPolicy.currentNativeUrl(privateInput: privateInput),
        );
      }

      // 预置音量：mpv open(play:true) 后默认以 100% 音量出声，会在下方
      // post-open 恢复保存音量之前先炸一声。open 前先写入目标音量
      // （移动端维持既有固定 1.0 语义）。同步自上游 467977e 炸音部分的
      // 本地简化方案。
      await setVolume(PlatformUtils.isMobile ? 1.0 : (room?.getSavedVolume() ?? 1.0));

      await _player.open(Media(url, httpHeaders: headers), play: true);

      if (_disposed || sourceGeneration != _sourceFence.generation) return;
      _sourceFence.finishOpen(await _currentNativeSourcePaths(), authorizeSuccessfulOpen: true);
      _publishCurrentNativeSnapshot(sourceGeneration);
      unawaited(_refreshCurrentNativeReadinessSnapshot(sourceGeneration));

      // mpv opens a normal Android source with `vid=auto`, and the Surface
      // controller already owns that same initial state. Reissuing an async
      // `vid=auto` command here can stay pending after the first frame is
      // visible; the room controller's initialization Future then never
      // completes and the first headphone tap waits on a stream that is already
      // playing. Audio-only still needs an explicit post-open selection.
      if (PlatformUtils.isAndroid && !audioOnly) {
        _isAudioOnly = false;
      } else {
        await _applyAudioOnly(audioOnly, force: true);
      }

      if (_disposed || sourceGeneration != _sourceFence.generation) return;
      _publishCurrentNativeSnapshot(sourceGeneration);
      final openingDiagnostic = _openingNativeDiagnostic;
      _openingNativeDiagnostic = null;
      if (openingDiagnostic != null && !_isDiagnosticComponentReady(openingDiagnostic.prefix)) {
        if (openingDiagnostic.generation == sourceGeneration) {
          _handleNativeDiagnostic(
            openingDiagnostic.message,
            nativePrefix: openingDiagnostic.prefix,
            generation: sourceGeneration,
          );
        }
      }
      _stateSubject.add(_loadingSubject.value ? PlayerState.buffering : PlayerState.ready);

      if (PlatformUtils.isMobile) {
        await setVolume(1.0);
      } else {
        final targetVolume = room?.getSavedVolume() ?? 1.0;
        await setVolume(targetVolume);
      }
    } catch (e, s) {
      if (sourceGeneration != _sourceFence.generation || _disposed) return;
      final classification = PlayerErrorClassifier.classify(e.toString());
      final exception = e is PlayerException
          ? e
          : PlayerException(
              message: 'Media open failed: $e',
              type: classification.type == PlayerErrorType.native ? PlayerErrorType.source : classification.type,
              code: classification.code,
              error: e,
              stackTrace: s,
            );

      _safeAddError(exception);

      throw exception;
    } finally {
      if (!_disposed &&
          _sourceFence.accepts(sourceGeneration) &&
          (_sourceHasVideoFrame || (_isAudioOnly && _sourceHasAudioFrame))) {
        _publishMediaProgressState();
      }
    }
  }

  // =========================
  // listeners
  // =========================

  Future<void> _bindListeners({required int sourceGeneration, bool force = false}) async {
    if (_listenerBound && !force) return;

    _listenerBound = true;

    await _cancelAllSubscriptions();
    if (_disposed || sourceGeneration != _sourceFence.generation) return;

    // =========================
    // playing
    // =========================

    _playingSub = _player.stream.playing.listen(
      (playing) {
        if (_disposed) return;
        if (!_sourceFence.accepts(sourceGeneration)) return;
        final publishPlaying = shouldPublishMediaKitPlaying(playing);
        _playingSubject.add(publishPlaying);
        if (publishPlaying) {
          // `Player.stream.playing` is the native playback authority. Optional
          // mpv frame properties are not available on every Android backend and
          // must never suppress this state or keep the manager's readiness
          // deadline alive for a stream which is already playing.
          _publishMediaProgressState();
          if (!_player.state.buffering) {
            _sourceProgressRevision++;
            _cancelRecoveredNativeError(
              _isAudioOnly ? NativeDiagnosticComponent.audio : NativeDiagnosticComponent.video,
            );
          }
        } else {
          if (!_loadingSubject.value) _stateSubject.add(PlayerState.paused);
        }
      },
      onError: (e, s) {
        _emitError(e, s, PlayerErrorType.native, sourceGeneration);
      },
    );

    // =========================
    // buffering
    // =========================

    _bufferingSub = _player.stream.buffering.listen(
      (loading) {
        if (_disposed) return;
        if (!_sourceFence.accepts(sourceGeneration)) return;
        _loadingSubject.add(loading);

        if (loading) {
          _stateSubject.add(PlayerState.buffering);
        } else {
          _sourceProgressRevision++;
          _stateSubject.add(_playingSubject.value ? PlayerState.playing : PlayerState.paused);
          if (_playingSubject.value) {
            _cancelRecoveredNativeError(
              _isAudioOnly ? NativeDiagnosticComponent.audio : NativeDiagnosticComponent.video,
            );
          }
        }
      },
      onError: (e, s) {
        _emitError(e, s, PlayerErrorType.native, sourceGeneration);
      },
    );

    // Keep width and height from the same decoder-parameter event. Listening
    // to the two derived streams independently allowed a transient width from
    // one quality/rotation state to be paired with the previous height. That
    // malformed ratio was then propagated into portrait detection and PiP.
    _videoParamsSub = _player.stream.videoParams.listen((params) {
      if (_disposed) return;
      if (!_sourceFence.accepts(sourceGeneration)) return;
      final size = resolveMediaKitDisplaySize(params);
      _widthSubject.add(size?.width);
      _heightSubject.add(size?.height);
      if (size != null) {
        // Non-native backends do not expose mpv frame properties. Their video
        // parameter event remains the strongest available readiness signal.
        if (!_usesNativeFrameProbe) _markDecodedVideoFrame(sourceGeneration);
      }
    });

    _audioParamsSub = _player.stream.audioParams.listen((_) {
      if (_disposed) return;
      _markDecodedAudioFrame(sourceGeneration);
    });

    // Timeshift state: track the high-frequency playhead and the (growing)
    // live timeline. `_pendingSeekTarget` is cleared once the native position
    // reports landing within 1.5s of the requested target.
    _positionSub = _player.stream.position.listen((pos) {
      if (_disposed) return;
      _lastPosition = pos;
      final pending = _pendingSeekTarget;
      if (pending != null && (pos - pending).inMilliseconds.abs() < 1500) {
        _pendingSeekTarget = null;
        _pendingSeekAt = null;
      }
    });

    _durationSub = _player.stream.duration.listen((dur) {
      if (_disposed) return;
      // Ignore spurious zero/regressing events during live playback
      // (media_kit re-seeds the subject on source switches; live `duration`
      // is monotonically growing). A genuine reset goes through
      // setDataSource/softStop which clear `_lastDuration` first.
      if (dur > Duration.zero && dur >= _lastDuration) {
        _lastDuration = dur;
      }
    });

    // =========================
    // completed
    // =========================

    _completeSub = _player.stream.completed.listen(
      (completed) {
        if (_disposed) return;
        if (!_sourceFence.accepts(sourceGeneration)) return;

        if (!completed) return;

        _completeSubject.add(true);

        _stateSubject.add(PlayerState.completed);
      },
      onError: (e, s) {
        _emitError(e, s, PlayerErrorType.native, sourceGeneration);
      },
    );

    // =========================
    // error
    // =========================

    // The same native message can legitimately be emitted by two consecutive
    // CDN lines. Stream-wide `distinct` treated the second source failure as a
    // duplicate, so the recovery chain stopped on a permanent loading state.
    // Deduplication below is scoped to one source generation instead.
    if (_player.platform is NativePlayer) {
      _logSub = _player.stream.log.listen((event) {
        if (_disposed || event.level != 'error' || !_isActionableNativeLog(event.prefix, event.text)) return;
        _handleNativeDiagnostic(event.text, nativePrefix: event.prefix, generation: sourceGeneration);
      });
    } else {
      _errorSub = _player.stream.error.listen((error) {
        if (_disposed) return;
        _handleNativeDiagnostic(error.toString(), generation: sourceGeneration);
      });
    }

    // =========================
    // collect
    // =========================

    _subscriptions.addAll([
      _playingSub!,
      _bufferingSub!,
      _videoParamsSub!,
      _audioParamsSub!,
      _completeSub!,
      ?_errorSub,
      ?_logSub,
      _positionSub!,
      _durationSub!,
    ]);

    _startCacheStatePolling();
  }

  static bool _isActionableNativeLog(String prefix, String text) {
    final normalizedPrefix = prefix.trim().toLowerCase();
    if (normalizedPrefix == 'ffmpeg') return text.trimLeft().toLowerCase().startsWith('tcp:');
    return const <String>{
      'file',
      'vd',
      'ad',
      'ffmpeg/video',
      'ffmpeg/audio',
      'cplayer',
      'stream',
    }.contains(normalizedPrefix);
  }

  void _publishCurrentNativeSnapshot(int generation) {
    if (!_sourceFence.accepts(generation) || _disposed) return;
    final size = resolveMediaKitDisplaySize(_player.state.videoParams);
    if (size != null) {
      _widthSubject.add(size.width);
      _heightSubject.add(size.height);
      if (!_usesNativeFrameProbe) _markDecodedVideoFrame(generation);
    }
    final audioParams = _player.state.audioParams;
    if (audioParams.format?.isNotEmpty == true ||
        (audioParams.sampleRate ?? 0) > 0 ||
        (audioParams.channelCount ?? 0) > 0) {
      _markDecodedAudioFrame(generation);
    }
    if (shouldPublishMediaKitPlaying(_player.state.playing)) {
      _playingSubject.add(true);
      _publishMediaProgressState();
      if (!_player.state.buffering) {
        _cancelRecoveredNativeError(_isAudioOnly ? NativeDiagnosticComponent.audio : NativeDiagnosticComponent.video);
      }
    }
  }

  void _handleNativeDiagnostic(String message, {String? nativePrefix, required int generation}) {
    if (generation != _sourceFence.generation) return;
    if (_sourceFence.isOpening || !_sourceFence.accepts(generation)) {
      _openingNativeDiagnostic = _NativeDiagnostic(message: message, prefix: nativePrefix, generation: generation);
      return;
    }
    final classification = PlayerErrorClassifier.classify(message, nativePrefix: nativePrefix);
    final exception = PlayerException(message: message, type: classification.type, code: classification.code);
    if (classification.immediatelyTerminal) {
      _emitConfirmedNativeError(exception, generation);
      return;
    }

    // mpv reports recoverable packet and hardware-decoder diagnostics on the
    // same stream as terminal failures. Give the active source one bounded
    // recovery window; a fresh frame/playing transition cancels this error.
    if (_pendingNativeErrorTimer != null) return;
    _pendingNativeError = exception;
    _pendingNativeErrorGeneration = generation;
    _pendingNativeErrorProgressRevision = _sourceProgressRevision;
    _pendingNativeErrorComponent = classification.component;
    _pendingNativeErrorTimer = Timer(const Duration(milliseconds: 1200), () {
      _pendingNativeErrorTimer = null;
      final pending = _pendingNativeError;
      final pendingGeneration = _pendingNativeErrorGeneration;
      _pendingNativeError = null;
      _pendingNativeErrorGeneration = null;
      if (pending == null || pendingGeneration == null || !_sourceFence.accepts(pendingGeneration)) return;
      final componentReady = switch (_pendingNativeErrorComponent) {
        NativeDiagnosticComponent.video => _sourceHasVideoFrame,
        NativeDiagnosticComponent.audio => _sourceHasAudioFrame,
        NativeDiagnosticComponent.either => _sourceHasVideoFrame || _sourceHasAudioFrame,
      };
      final playbackProgressed = _sourceProgressRevision > _pendingNativeErrorProgressRevision;
      final recovered = playbackProgressed && _player.state.playing && (componentReady || !_loadingSubject.value);
      if (recovered || (_player.state.playing && !_loadingSubject.value)) {
        return;
      }
      _emitConfirmedNativeError(pending, pendingGeneration);
    });
  }

  void _cancelRecoveredNativeError(NativeDiagnosticComponent progressedComponent) {
    if (_pendingNativeErrorTimer == null) return;
    if (_pendingNativeErrorComponent != NativeDiagnosticComponent.either &&
        _pendingNativeErrorComponent != progressedComponent) {
      return;
    }
    _pendingNativeErrorTimer?.cancel();
    _pendingNativeErrorTimer = null;
    _pendingNativeError = null;
    _pendingNativeErrorGeneration = null;
    _pendingNativeErrorComponent = NativeDiagnosticComponent.either;
  }

  void _drainDeferredNativeDiagnostic(int generation) {
    final diagnostic = _openingNativeDiagnostic;
    if (diagnostic != null && diagnostic.generation != generation) {
      _openingNativeDiagnostic = null;
      return;
    }
    if (diagnostic != null && _isDiagnosticComponentReady(diagnostic.prefix)) {
      _openingNativeDiagnostic = null;
      return;
    }
    if (diagnostic == null || !_sourceFence.accepts(generation)) return;
    _openingNativeDiagnostic = null;
    _handleNativeDiagnostic(diagnostic.message, nativePrefix: diagnostic.prefix, generation: generation);
  }

  bool _isDiagnosticComponentReady(String? nativePrefix) {
    final prefix = nativePrefix?.trim().toLowerCase();
    if (prefix == 'ad' || prefix == 'ffmpeg/audio') return _sourceHasAudioFrame;
    if (prefix == 'vd' || prefix == 'ffmpeg/video') return _sourceHasVideoFrame;
    return _sourceHasVideoFrame || _sourceHasAudioFrame;
  }

  void _emitConfirmedNativeError(PlayerException exception, int generation) {
    if (!_sourceFence.accepts(generation) || _disposed) return;
    _emitCurrentSourceError(exception, generation);
  }

  void _emitCurrentSourceError(PlayerException exception, int generation) {
    if (!_sourceFence.isCurrentGeneration(generation) || _disposed) return;
    final now = DateTime.now();
    if (_lastEmittedNativeErrorGeneration == generation &&
        _lastEmittedNativeError == exception.toString() &&
        _lastEmittedNativeErrorAt != null &&
        now.difference(_lastEmittedNativeErrorAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastEmittedNativeErrorGeneration = generation;
    _lastEmittedNativeError = exception.toString();
    _lastEmittedNativeErrorAt = now;
    _safeAddError(exception);
  }

  // =========================
  // cancel subscriptions
  // =========================

  Future<void> _cancelAllSubscriptions() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }

    _subscriptions.clear();

    _playingSub = null;
    _bufferingSub = null;
    _videoParamsSub = null;
    _audioParamsSub = null;
    _positionSub = null;
    _durationSub = null;

    _completeSub = null;
    _errorSub = null;
    _logSub = null;

    _stopCacheStatePolling();
  }

  // =========================
  // timeshift: seekable cache ranges
  // =========================

  /// Parses the string form of mpv's `demuxer-cache-state` property.
  ///
  /// mpv serialises `MPV_FORMAT_NODE_ARRAY` / `MPV_FORMAT_NODE_MAP` values
  /// with the `{key=value,...}` / `[...]` syntax produced by
  /// `mpv_get_property_string`. We only need the `start`/`end` pairs of the
  /// `seekable-ranges` list, so a small regex is sufficient and robust
  /// against surrounding fields that may change between mpv versions.
  static List<({Duration start, Duration end})> parseSeekableRanges(String raw) {
    if (raw.isEmpty) return const [];
    final ranges = <({Duration start, Duration end})>[];
    // mpv serialises each seekable range as a `{...}` map. Parse each block
    // independently so field ordering and whitespace do not matter.
    final blockRegExp = RegExp(r'\{([^{}]*)\}');
    // Tolerate optional whitespace around `=` and scientific notation.
    final startRegExp = RegExp(r'start\s*=\s*([-+]?[\d.eE+-]+)');
    final endRegExp = RegExp(r'end\s*=\s*([-+]?[\d.eE+-]+)');
    for (final block in blockRegExp.allMatches(raw)) {
      final content = block.group(1)!;
      final startMatch = startRegExp.firstMatch(content);
      final endMatch = endRegExp.firstMatch(content);
      if (startMatch == null || endMatch == null) continue;
      final start = double.tryParse(startMatch.group(1)!);
      final end = double.tryParse(endMatch.group(1)!);
      if (start == null || end == null || end <= start) continue;
      ranges.add((
        start: Duration(microseconds: (start * 1e6).round()),
        end: Duration(microseconds: (end * 1e6).round()),
      ));
    }
    return ranges;
  }

  void _startCacheStatePolling() {
    _cacheStateTimer?.cancel();
    _cacheStateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      await _refreshCacheState();
    });
  }

  /// Reads `demuxer-cache-state` and related live-stream properties from mpv
  /// and updates all derived fields (`_seekableRanges`, `_backBufferBytes`,
  /// `_lastDuration`, bitrates). Called on a 500 ms timer and also right
  /// before every in-cache seek so we clamp against the freshest possible
  /// window, avoiding stale-data seeks that would trigger an mpv reconnect.
  Future<void> _refreshCacheState() async {
    if (_disposed || _player.platform is! NativePlayer) return;
    // Guard against writing pre-reset data back after a timeline reset
    // (reconnect recovery / source switch). See [_cacheStateEpoch].
    final epoch = _cacheStateEpoch;
    try {
      final native = _player.platform as NativePlayer;
      final raw = await native.getProperty('demuxer-cache-state');
      if (_disposed || epoch != _cacheStateEpoch) return;
      _seekableRanges = parseSeekableRanges(raw);
      _backBufferBytes = _parseBackBytes(raw);
      // For live streams mpv's `duration` keeps growing (highest buffered
      // PTS minus stream start). Poll it as a backstop for the duration
      // stream subscription, which can lag property updates slightly.
      final durationRaw = await native.getProperty('duration');
      if (_disposed || epoch != _cacheStateEpoch) return;
      final seconds = double.tryParse(durationRaw);
      if (seconds != null && seconds.isFinite && seconds >= 0) {
        final d = Duration(microseconds: (seconds * 1e6).round());
        if (d > _lastDuration) _lastDuration = d;
      }
      // Bitrate is needed to convert back-buffer bytes into a time span.
      // These properties can be absent for some live sources; we keep the
      // previous reading instead of zeroing it out on a transient failure.
      try {
        final vbr = double.tryParse(await native.getProperty('video-bitrate'));
        final abr = double.tryParse(await native.getProperty('audio-bitrate'));
        if (_disposed || epoch != _cacheStateEpoch) return;
        if (vbr != null && vbr > 0) _videoBitrate = vbr;
        if (abr != null && abr > 0) _audioBitrate = abr;
      } catch (_) {
        // Transient property failures are fine; keep the last known bitrate.
      }
    } catch (_) {
      // Property lookup can fail while the player is switching sources;
      // the next tick will retry.
    }
  }

  /// Extracts the `bw-bytes` field from mpv's `demuxer-cache-state` string.
  /// Returns 0 when the field is missing or unparseable.
  static int _parseBackBytes(String raw) {
    if (raw.isEmpty) return 0;
    final match = RegExp(r'bw-bytes\s*=\s*([\d.eE+-]+)').firstMatch(raw);
    if (match == null) return 0;
    final value = double.tryParse(match.group(1)!);
    if (value == null || !value.isFinite || value < 0) return 0;
    return value.round();
  }

  void _stopCacheStatePolling() {
    _cacheStateTimer?.cancel();
    _cacheStateTimer = null;
    _reconnectWatch?.cancel();
    _reconnectWatch = null;
  }

  // =========================
  // emit error
  // =========================

  void _emitError(Object error, StackTrace stackTrace, PlayerErrorType type, int generation) {
    if (_disposed || !_sourceFence.accepts(generation)) return;

    _safeAddError(PlayerException(message: error.toString(), type: type, error: error, stackTrace: stackTrace));
  }

  void _safeAddError(PlayerException exception) {
    if (_disposed) return;

    if (_errorSubject.isClosed) return;

    _errorSubject.add(exception);
  }

  // =========================
  // widget
  // =========================

  @override
  Widget getVideoWidget({BoxFit? fit}) {
    final effectiveFit = fit ?? _videoFit;
    _videoFit = effectiveFit;
    // Plain Video widget, matching the dev version: no dynamic native video
    // output resize. The previous Windows-only VideoOutputViewportSizer chain
    // called VideoController.setSize on every layout change (fullscreen/wide
    // switch, window or panel resize), which rebuilt the Direct3D video output
    // and flashed a black frame — the "picture refreshed" glitch. media_kit's
    // Video already scales its texture via `fit` without an output rebuild.
    return Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: effectiveFit,
      // 壁纸模式下填充透明，使视频宽高比不匹配时露出的区域透出壁纸。
      fill: SettingsService.hasWallpaper ? Colors.transparent : const Color(0xFF000000),
      // PlaybackLifecycleCoordinator is the single lifecycle authority.
      // Letting Video apply a second, settings-only policy paused audio-only
      // rooms on Home/lock even though the background policy kept them alive.
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }

  @override
  void setVideoFit(BoxFit fit) {
    _videoFit = fit;
  }

  // =========================
  // play
  // =========================

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.pause();

    await _player.seek(Duration.zero);

    _stateSubject.add(PlayerState.stopped);
  }

  @override
  Future<void> softStop() async {
    // Pausing a live source keeps its demuxer, decoder, audio track and network
    // buffers alive. That left the home/settings UI competing with an invisible
    // room for CPU and hundreds of MiB after navigation. Unload the current
    // media while retaining the native Player object for a fast next open.
    await _player.setVolume(0.0);
    await _player.stop();
    _currentUrl = null;
    _isAudioOnly = false;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _seekableRanges = const [];
    _backBufferBytes = 0;
    _reconnectWatch?.cancel();
    _reconnectWatch = null;
    _cacheStateEpoch++;
    _videoBitrate = 0.0;
    _audioBitrate = 0.0;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    _playingSubject.add(false);
    _loadingSubject.add(false);
    _widthSubject.add(null);
    _heightSubject.add(null);
    _stateSubject.add(PlayerState.stopped);
  }

  @override
  Future<void> setAudioOnly(bool audioOnly) {
    if (!_audioModeTransitions.isRunning && _isAudioOnly == audioOnly) {
      return Future<void>.value();
    }
    return _audioModeTransitions.submit(audioOnly);
  }

  Future<void> _applyAudioOnly(bool audioOnly, {bool force = false}) async {
    if (_disposed) return;
    if (!force && _isAudioOnly == audioOnly) return;

    try {
      if (PlatformUtils.isAndroid) {
        // Android's patched video controller serializes `vid` with WID/Surface
        // updates. Disabling decode here saves battery during long ASMR sessions
        // while retaining the same player, demuxer and network connection.
        if (audioOnly) {
          await _controller.setVideoOutputEnabled(false);
        } else {
          await _restoreAndroidVideoOutput();
        }
      } else {
        // Desktop video outputs do not rewrite `vid` while their surface is
        // resized, so changing the decoded track is safe and saves resources.
        final track = audioOnly ? VideoTrack.no() : VideoTrack.auto();
        await _player.setVideoTrack(track);
      }

      _isAudioOnly = audioOnly;
      if (_disposed) return;
    } catch (error, stackTrace) {
      throw PlayerException(
        message: 'MediaKit audio mode switch failed',
        type: PlayerErrorType.lifecycle,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Enables Android video and waits for mpv to publish fresh decoded-video
  /// parameters before the room removes its audio presentation. This is an
  /// adaptive keyframe fence rather than an arbitrary fixed delay: fast streams
  /// reveal immediately, while a slow GOP remains covered by the room artwork
  /// instead of showing a black texture.
  Future<void> _restoreAndroidVideoOutput() async {
    final frameReady = Completer<void>();
    var armed = false;
    final stopwatch = Stopwatch()..start();
    final subscription = _player.stream.videoParams.listen((params) {
      final width = params.dw ?? params.w ?? 0;
      final height = params.dh ?? params.h ?? 0;
      if (armed && width > 0 && height > 0 && !frameReady.isCompleted) {
        frameReady.complete();
      }
    });

    try {
      // The stream is broadcast, but arm after attaching the listener so a
      // stale cached state can never be mistaken for the next decoded frame.
      armed = true;
      await _controller.setVideoOutputEnabled(true);

      var observedFreshFrame = true;
      await frameReady.future.timeout(
        const Duration(milliseconds: 2800),
        onTimeout: () {
          observedFreshFrame = false;
        },
      );
      if (observedFreshFrame) {
        // video-params precedes texture composition by a very small interval.
        // Two display frames keep the cover in place until the GPU texture has
        // had a chance to present without adding a user-visible fixed pause.
        await Future<void>.delayed(const Duration(milliseconds: 34));
      } else {
        debugPrint(
          'MediaKitAdapter: video restore readiness timed out after '
          '${stopwatch.elapsedMilliseconds} ms; revealing the live texture',
        );
      }
    } finally {
      stopwatch.stop();
      await subscription.cancel();
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final vol = (volume * 100).clamp(0.0, 100.0);

    await _player.setVolume(vol);
  }

  // =========================
  // dispose
  // =========================

  @override
  Future<void> hardDispose() async {
    if (_disposed) return;

    _disposed = true;

    _initialized = false;

    _listenerBound = false;

    _stopCacheStatePolling();

    _pendingNativeErrorTimer?.cancel();

    _pendingNativeErrorTimer = null;

    _sourceFence.clear();

    final frameRevisionListener = _videoFrameRevisionListener;
    if (frameRevisionListener != null) {
      _controller.frameRevision.removeListener(frameRevisionListener);
      _videoFrameRevisionListener = null;
    }

    await _cancelAllSubscriptions();

    if (_nativePathObserved && _player.platform is NativePlayer) {
      try {
        await (_player.platform as dynamic).unobserveProperty('path');
      } catch (_) {}
      _nativePathObserved = false;
    }

    if (_nativeFramePropertiesObserved && _player.platform is NativePlayer) {
      try {
        final native = _player.platform as dynamic;
        await native.unobserveProperty('video-frame-info/picture-type');
        await native.unobserveProperty('estimated-vf-fps');
      } catch (_) {}
      _nativeFramePropertiesObserved = false;
      _usesNativeFrameProbe = false;
    }

    try {
      await _player.stop();
    } catch (_) {}

    try {
      await _player.dispose();
    } catch (_) {}

    _softwareDecoderFallbackUrl = null;
    _currentSourceIdentity = null;
    _nextSourceIdentity = null;
    _privateInput = false;

    await Future.wait([
      _stateSubject.close(),
      _playingSubject.close(),
      _loadingSubject.close(),
      _errorSubject.close(),
      _completeSubject.close(),
      _widthSubject.close(),
      _heightSubject.close(),
      _videoFrameProgressSubject.close(),
    ]);
  }

  // =========================
  // getter
  // =========================

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isPlayingNow => _playingSubject.value;

  @override
  // Windows keeps the libmpv/D3D renderer valid after [softStop]; only the
  // current Media (and therefore the CDN transport, demuxer and decoder
  // buffers) is unloaded.  The Huya first-frame-gated hand-off can therefore
  // alternate two initialized players instead of allocating another native
  // renderer every lease period.  Keep the contract Windows-only until the
  // surface-backed mobile implementations have equivalent lifecycle proof.
  bool get isReusable => PlatformUtils.isWindows;

  @override
  Stream<PlayerState> get onStateChanged => _stateSubject.stream;

  @override
  Stream<bool> get onPlaying => _playingSubject.stream.distinct();

  @override
  Stream<PlayerException> get onError => _errorSubject.stream;

  @override
  Stream<bool> get onLoading => _loadingSubject.stream.distinct();

  @override
  Stream<bool> get onComplete => _completeSubject.stream;

  @override
  Stream<int?> get width => _widthSubject.stream;

  @override
  Stream<int?> get height => _heightSubject.stream;

  @override
  bool get supportsVideoFrameProgress => PlatformUtils.isWindows;

  @override
  Stream<int> get onVideoFrameProgress => _videoFrameProgressSubject.stream;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Player get mediaKitPlayer => _player;

  @override
  VideoController get mediaKitVideoController => _controller;

  // =========================
  // timeshift: seek API
  // =========================

  @override
  Duration get currentPosition => _lastPosition;

  /// Full timeline length reported by mpv (`duration`). For live streams
  /// this keeps growing from stream start (highest buffered PTS - start),
  /// exactly the scale mpv's own seekbar maps `percent-pos` onto.
  Duration get streamDuration => _lastDuration;

  /// Playhead position as a 0.0–1.0 fraction of the *cached seekable window*
  /// [earliestCachedPosition, duration]. When no content has been evicted yet
  /// (earliest == 0) this is identical to the full-timeline ratio; once the
  /// back buffer starts dropping old frames the fraction space is compressed
  /// so the handle still spans the full visible track.
  double? get positionFraction {
    final totalMicros = _lastDuration.inMicroseconds;
    if (totalMicros <= 0) return null;
    final earliestMicros = earliestCachedPosition.inMicroseconds;
    final rangeMicros = totalMicros - earliestMicros;
    if (rangeMicros <= 0) return (_lastPosition.inMicroseconds / totalMicros).clamp(0.0, 1.0);
    return ((_lastPosition.inMicroseconds - earliestMicros) / rangeMicros).clamp(0.0, 1.0);
  }

  /// Seekable cached ranges projected onto the 0.0–1.0 fraction of the
  /// *cached seekable window* [earliestCachedPosition, duration], matching
  /// [positionFraction]. This keeps the UI's fraction space consistent so the
  /// painter and snapping logic can remain unchanged.
  List<({double start, double end})> get seekableFractions {
    final totalMicros = _lastDuration.inMicroseconds;
    if (totalMicros <= 0 || _seekableRanges.isEmpty) return const [];
    final earliestMicros = earliestCachedPosition.inMicroseconds.toDouble();
    final rangeMicros = totalMicros - earliestCachedPosition.inMicroseconds;
    // Fallback to full-timeline mapping when the window is degenerate.
    final baseDenom = rangeMicros > 0 ? rangeMicros.toDouble() : totalMicros.toDouble();
    return _seekableRanges.map((r) {
      final startMicros = r.start.inMicroseconds.toDouble();
      final endMicros = r.end.inMicroseconds.toDouble();
      final clampedStartMicros = startMicros > earliestMicros ? startMicros : earliestMicros;
      return (
        start: ((clampedStartMicros - earliestMicros) / baseDenom).clamp(0.0, 1.0),
        end: ((endMicros - earliestMicros) / baseDenom).clamp(0.0, 1.0),
      );
    }).toList();
  }

  /// Estimated position of the oldest still-cached frame, i.e. the right
  /// boundary of the "dead zone" that has been evicted from the back buffer.
  ///
  /// mpv's `seekable-ranges` are not guaranteed to track back-buffer eviction
  /// in real time, so when the back buffer saturates we derive the earliest
  /// cached position from `bw-bytes` and the current bitrate instead. When the
  /// back buffer is not yet full (or no bitrate is available) we return
  /// [Duration.zero], meaning the whole timeline from stream start is still
  /// seekable.
  Duration get earliestCachedPosition {
    // Back buffer not saturated yet: nothing has been evicted.
    // mpv's seekable-ranges left edge can be non-zero right after entering
    // the room (ts_offset / initial buffering), so we must NOT use it here
    // or we would show a spurious dead zone before any content is actually
    // evicted.
    if (_backBufferBytes < LiveBufferPolicy.backBytes * 0.9) return Duration.zero;
    final bitrate = _videoBitrate + _audioBitrate;
    if (bitrate <= 0) {
      // No bitrate available — fall back to mpv's own seekable-ranges start.
      // It lags the true eviction but is better than assuming zero eviction.
      // This path is only reached once the back buffer is already saturated,
      // so we know eviction has actually begun.
      if (_seekableRanges.isEmpty) return Duration.zero;
      return _seekableRanges.map((r) => r.start).reduce((a, b) => a < b ? a : b);
    }
    // How many seconds of audio+video fit in the current back buffer.
    final backSeconds = (_backBufferBytes * 8.0) / bitrate;
    if (!backSeconds.isFinite || backSeconds <= 0) return Duration.zero;
    final earliest = liveEdgePosition - Duration(seconds: backSeconds.round());
    // Safety margin for variable-bitrate streams: the measured bitrate may
    // be lower than the instantaneous peak, which would make our estimate
    // drift left of the true eviction boundary and risk a reconnect seek.
    // Shrinking the window by a few seconds trades a tiny amount of usable
    // cache for reliability.
    final withMargin = earliest + const Duration(seconds: 5);
    final clamped = withMargin > liveEdgePosition ? liveEdgePosition : withMargin;
    return clamped > Duration.zero ? clamped : Duration.zero;
  }

  /// Snaps an absolute target position into the cached seekable ranges.
  ///
  /// mpv can seek *inside* a seekable range without touching the network
  /// (`execute_cache_seek`); a target outside any range makes it call
  /// `switch_to_fresh_cache_range` + a low-level stream seek, which for a
  /// live FLV/TS/HLS URL reconnects at the live edge with PTS restarted at
  /// 0 — the seekbar then visually jumps back to the far left. We therefore
  /// never issue an out-of-range seek: targets in a dead zone snap to the
  /// nearest range boundary. Returns `null` when no range is known yet.
  Duration? _clampToSeekable(Duration target) {
    if (_seekableRanges.isEmpty) return null;
    // The back buffer may have evicted content left of `earliestCachedPosition`
    // even though mpv's seekable-ranges still claim it. Snap to the real
    // earliest cached position first.
    final earliest = earliestCachedPosition;
    if (target < earliest) return earliest;
    final t = target.inMicroseconds;
    int? nearest;
    var nearestDistance = -1;
    for (final r in _seekableRanges) {
      final rs = r.start.inMicroseconds;
      final re = r.end.inMicroseconds;
      if (t >= rs && t <= re) return target;
      final boundary = (t < rs ? rs : re);
      final distance = (boundary - t).abs();
      if (nearestDistance < 0 || distance < nearestDistance) {
        nearestDistance = distance;
        nearest = boundary;
      }
    }
    return nearest == null ? null : Duration(microseconds: nearest);
  }

  bool _isInAnySeekableRange(Duration pos) {
    if (_seekableRanges.isEmpty) return false;
    if (pos < earliestCachedPosition) return false;
    final t = pos.inMicroseconds;
    for (final r in _seekableRanges) {
      if (t >= r.start.inMicroseconds && t <= r.end.inMicroseconds) return true;
    }
    return false;
  }

  Duration? _clampToSeekableWithDirection(Duration target, Duration offset) {
    if (_seekableRanges.isEmpty) return null;
    // Respect back-buffer eviction even when the target falls inside a
    // seekable range whose left edge mpv has not yet updated.
    final earliest = earliestCachedPosition;
    if (target < earliest) return earliest;
    final t = target.inMicroseconds;

    for (final r in _seekableRanges) {
      final rs = r.start.inMicroseconds;
      final re = r.end.inMicroseconds;
      if (t >= rs && t <= re) return target;
    }

    if (offset < Duration.zero) {
      int? nearestLeftEnd;
      var nearestLeftDist = -1;
      for (final r in _seekableRanges) {
        final re = r.end.inMicroseconds;
        if (re <= t) {
          final dist = t - re;
          if (nearestLeftDist < 0 || dist < nearestLeftDist) {
            nearestLeftDist = dist;
            nearestLeftEnd = re;
          }
        }
      }
      if (nearestLeftEnd != null) {
        return Duration(microseconds: nearestLeftEnd);
      }
      return streamStartPosition;
    } else if (offset > Duration.zero) {
      int? nearestRightStart;
      var nearestRightDist = -1;
      for (final r in _seekableRanges) {
        final rs = r.start.inMicroseconds;
        if (rs >= t) {
          final dist = rs - t;
          if (nearestRightDist < 0 || dist < nearestRightDist) {
            nearestRightDist = dist;
            nearestRightStart = rs;
          }
        }
      }
      if (nearestRightStart != null) {
        return Duration(microseconds: nearestRightStart);
      }
      return liveEdgePosition;
    }

    return target;
  }

  Future<void> _seekAbsolute(Duration position, {required bool exact, Duration? expectedTarget}) async {
    // A new seek supersedes any watch still running from the previous one —
    // otherwise a stale watch can fire during (and misjudge) this seek.
    _reconnectWatch?.cancel();
    _reconnectWatch = null;
    if (_disposed || _player.platform is! NativePlayer) return;
    final safePos = position < Duration.zero
        ? Duration.zero
        : (_lastDuration > Duration.zero && position > _lastDuration ? _lastDuration : position);
    final seconds = safePos.inMicroseconds / 1e6;
    if (seconds.isNegative || seconds.isNaN || seconds.isInfinite) return;
    try {
      final native = _player.platform as NativePlayer;
      // CRITICAL: always use an absolute-time seek on live streams, never
      // `absolute-percent`. mpv keeps SEEK_FACTOR set for percent seeks when
      // the demuxer reports ts_resets_possible (FLV/TS/HLS all do), and the
      // demuxer then bypasses its cache entirely, performing a low-level
      // reconnect seek. Absolute seconds land in find_cache_seek_range() and
      // are served from the local back-buffer. `exact` mirrors the OSC click
      // behaviour; keyframes are used while dragging for responsiveness.
      final mode = exact ? 'absolute+exact' : 'absolute+keyframes';
      await native.command(['seek', seconds.toStringAsFixed(3), mode]);
    } catch (e) {
      debugPrint('[LiveSeek] mpv seek command failed: $e');
      return;
    }

    // Post-seek reconnect guard.
    //
    // Even with the pre-seek `_refreshCacheState()` check above, a seek can
    // still land outside every cached range if mpv silently evicts frames
    // between our property-read and the actual seek command. When that
    // happens, mpv performs a low-level stream reconnect, the PTS base resets
    // to ~0, and `time-pos` jumps back to the far left of the progress bar.
    //
    // A reconnect involves an actual network re-connection and typically takes
    // 1–3 s to complete, so a single delayed check is unreliable (the old
    // position may still be reported at +350 ms). We therefore poll `time-pos`
    // every 400 ms for ~4 s until it either lands near the target (success) or
    // drops near zero (reconnect → recover to the live edge).
    //
    // Suppressed when the target itself was near the live edge, because
    // landing at a low `time-pos` after a seek-edge is indistinguishable
    // from a normal reconnect and we'd otherwise recurse.
    if (expectedTarget == null || expectedTarget < const Duration(seconds: 1)) {
      return; // nothing meaningful to detect
    }
    if (expectedTarget > liveEdgePosition - const Duration(seconds: 3)) {
      return; // target was near live edge; skip reconnect watch
    }
    _startReconnectWatch(expectedTarget);
  }

  /// Polls `time-pos` after a seek until the decoder demonstrably *stays* at
  /// the target, or a reconnect shows up. See the comment above the call site
  /// in [_seekAbsolute] for the rationale.
  ///
  /// The first tick that reads `time-pos ≈ target` is deliberately NOT taken
  /// as success: on a rejected seek mpv briefly reports the requested position
  /// (the optimistic result of the seek command) and only later reconnects
  /// back to the live edge. We therefore require the position to hold steady
  /// for a short stability window, and separately flag a large forward jump.
  void _startReconnectWatch(Duration target) {
    _reconnectWatch?.cancel();
    var attempts = 0;
    int? confirmedTick;
    const maxAttempts = 25; // 25 × 400 ms ≈ 10 s budget (slow reconnects happen)
    const confirmWindow = 7; // after first landing, watch ~2.8 s more
    const interval = Duration(milliseconds: 400);
    // Normal playback advances only ~3 s across the confirm window, so a jump
    // this far past the target can only be a reconnect that landed back at the
    // live edge.
    const edgeJump = Duration(seconds: 30);
    debugPrint('[LiveSeek] watch started: target=${target.inSeconds}s');
    _reconnectWatch = Timer.periodic(interval, (timer) async {
      attempts++;
      if (_disposed || attempts > maxAttempts) {
        if (!_disposed) {
          debugPrint(
            '[LiveSeek] watch gave up after $maxAttempts attempts: '
            'target=${target.inSeconds}s, last pos=${_lastPosition.inSeconds}s',
          );
        }
        timer.cancel();
        return;
      }
      // Read a fresh `time-pos` — `_lastPosition` may be stale while mpv is
      // still seeking / buffering.
      double? actualSeconds;
      try {
        final platform = _player.platform;
        if (platform is! NativePlayer) {
          timer.cancel();
          return;
        }
        final raw = await platform.getProperty('time-pos');
        // getProperty can outlast one tick when mpv is busy reconnecting;
        // an overlapping tick may already have cancelled this timer and taken
        // over. Re-check before acting so we never double-toast / double-recover.
        if (_disposed || !timer.isActive) return;
        actualSeconds = double.tryParse(raw);
      } catch (_) {
        return; // transient property failure — retry on the next tick
      }
      if (actualSeconds == null) return;
      final actual = Duration(microseconds: (actualSeconds * 1e6).round());
      final diff = (actual - target).abs();

      final landedAt = confirmedTick;
      if (landedAt == null) {
        // The seek has not landed yet. A large `|actual − target|` here means
        // nothing: mpv has not finished seeking and `time-pos` still reports
        // the pre-seek position, which for a backward seek is naturally far
        // *ahead* of the target. Treating that as a reconnect was the
        // false-positive that spammed the toast on every valid click.
        //
        // The one genuine reconnect signature that IS trustworthy before
        // landing is the PTS-reset one: a far target with a near-zero position.
        if (target > const Duration(seconds: 10) && actual < const Duration(seconds: 2)) {
          timer.cancel();
          await _handleReconnectDetected(target, actual, 'near-zero PTS');
          return;
        }
        if (diff < const Duration(seconds: 2)) {
          confirmedTick = attempts;
          debugPrint(
            '[LiveSeek] landed near target at tick $attempts; watching '
            '$confirmWindow more tick(s) to confirm it sticks',
          );
        }
        // Still seeking/buffering — keep polling until the budget runs out.
        return;
      }

      // The position has reached the target at least once. Only now does a
      // large forward jump mean something: the seek was overturned and
      // playback reconnected at the live edge.
      if (actual - target > edgeJump) {
        timer.cancel();
        await _handleReconnectDetected(target, actual, 'jumped past target after landing');
        return;
      }
      // Position stayed put — normal playback advances only a few seconds
      // across this window, far below [edgeJump]. Accept the seek.
      if (attempts - landedAt >= confirmWindow) {
        debugPrint(
          '[LiveSeek] watch OK: position stable near ${actual.inSeconds}s '
          '(target ${target.inSeconds}s)',
        );
        timer.cancel();
      }
    });
  }

  /// Shared reconnect recovery: resets the app-side timeline bookkeeping (mpv
  /// has restarted its own), notifies the user, and jumps back to the live
  /// edge. Every detection path funnels through here so the reset lives in one
  /// place.
  Future<void> _handleReconnectDetected(Duration target, Duration actual, String reason) async {
    debugPrint(
      '[LiveSeek] reconnect detected ($reason): target=${target.inSeconds}s, '
      'now=${actual.inSeconds}s — resetting timeline and recovering to live edge',
    );
    // The reconnect reset mpv's time base: duration shrank back to a few
    // seconds and all old cache ranges are gone. Our monotonic duration
    // tracking must be reset too, otherwise the fraction space stays anchored
    // to the pre-reconnect timeline and the bar never recovers. `_lastPosition`
    // and the pending-seek state are equally stale; the epoch bump discards any
    // in-flight `_refreshCacheState` result read against the old timeline.
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _seekableRanges = const [];
    _backBufferBytes = 0;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    _cacheStateEpoch++;
    if (!_suppressSeekToast) {
      ToastUtil.error('该位置缓存已失效，已自动恢复至直播边缘');
    }
    await seekToLiveEdge();
  }

  /// Seek to a 0.0–1.0 fraction of the *cached seekable window*
  /// [earliestCachedPosition, duration]. The fraction is back-converted to an
  /// absolute time, snapped into the cached seekable ranges, and sent to mpv.
  ///
  /// If the refresh reveals that the requested fraction maps to a position
  /// mpv has already evicted (snapped target differs from original by more
  /// than a couple of seconds) we block the original seek, show a brief
  /// toast explaining that the cache has expired, and seek instead to the
  /// earliest still-usable position — which is the leftmost point in the
  /// freshly-refreshed cached window.
  Future<void> seekToFraction(double fraction, {bool exact = false}) async {
    if (!canSeek) return;
    // Pre-seek refresh: discard stale ranges that may have been evicted since
    // the last 500 ms poll. This is the primary guard against reconnect seeks
    // that happen when we clamp against a window mpv has already dropped.
    await _refreshCacheState();
    if (!canSeek) return;
    final totalMicros = _lastDuration.inMicroseconds.toDouble();
    if (totalMicros <= 0) return;
    final earliestMicros = earliestCachedPosition.inMicroseconds.toDouble();
    final rangeMicros = totalMicros - earliestMicros;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    final f = fraction.clamp(0.0, 1.0);
    // Convert from [earliest, duration] fraction space back to absolute Duration.
    final targetMicros = rangeMicros > 0
        ? (earliestMicros + f * rangeMicros).round()
        : (f * totalMicros).round(); // fallback: no eviction yet
    final originalTarget = Duration(microseconds: targetMicros);
    final snapped = _seekableRanges.isNotEmpty ? (_clampToSeekable(originalTarget) ?? originalTarget) : originalTarget;

    // Detect a significant eviction: if snapping pushed the target forward by
    // more than a couple of seconds, the user asked for a position that has
    // already fallen off the back buffer. Surface a toast so they understand
    // why the seek didn't land where they tapped, and redirect them to the
    // *actual* earliest usable point rather than the expired one.
    final deltaMicros = (snapped.inMicroseconds - originalTarget.inMicroseconds).abs();
    if (deltaMicros > const Duration(seconds: 2).inMicroseconds) {
      debugPrint(
        '[LiveSeek] EXPIRED position blocked: original=${originalTarget.inSeconds}s '
        'snapped=${snapped.inSeconds}s '
        'redirecting to earliest=${streamStartPosition.inSeconds}s',
      );
      if (!_suppressSeekToast) {
        ToastUtil.error('该位置缓存已失效，已跳转至最早可用时间');
      }
      // Seek to the real earliest available position (streamStartPosition,
      // which equals max(earliestCachedPosition, min seekable-range start)
      // after the fresh refresh). This is NOT the original expired target —
      // we are actively redirecting to a position we know is still cached.
      final earliestUsable = streamStartPosition;
      await _seekAbsolute(earliestUsable, exact: exact, expectedTarget: earliestUsable);
      return;
    }

    await _seekAbsolute(snapped, exact: exact, expectedTarget: snapped);
  }

  @override
  Duration get liveEdgePosition {
    if (_seekableRanges.isNotEmpty) {
      return _seekableRanges.map((r) => r.end).reduce((a, b) => a > b ? a : b);
    }
    // No range data: assume the playhead currently sits at the edge.
    return _lastPosition;
  }

  Duration get streamStartPosition {
    final rangesStart = _seekableRanges.isNotEmpty
        ? _seekableRanges.map((r) => r.start).reduce((a, b) => a < b ? a : b)
        : _lastPosition;
    // Honour the back-buffer eviction estimate so the time label shrinks to the
    // real cache-window length instead of showing the full elapsed time.
    final earliest = earliestCachedPosition;
    return earliest > rangesStart ? earliest : rangesStart;
  }

  bool get isUserSeekedBack {
    if (_seekableRanges.isEmpty) return false;
    return liveEdgePosition - _lastPosition > const Duration(seconds: 2);
  }

  /// Suppresses the "cache expired" toast during rapid drag-seek gestures.
  /// The UI layer sets `true` on drag-start and `false` on drag-end.
  set suppressSeekToast(bool value) => _suppressSeekToast = value;

  @override
  bool get canSeek {
    if (!_initialized || _disposed || _player.platform is! NativePlayer) {
      return false;
    }
    // Live streams: safe in-cache seek requires cached seekable ranges.
    // VOD / file streams are seekable by nature and report a finite
    // duration without necessarily exposing cache ranges. Use duration as a
    // fallback so the progress bar appears and seeks work immediately, even
    // before the first demuxer-cache-state poll returns ranges for a live
    // stream.
    return _seekableRanges.isNotEmpty || _lastDuration > Duration.zero;
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Future<void> seekTo(Duration position) async {
    if (!canSeek) return;
    // Pre-seek refresh so the clamp uses current eviction boundaries.
    await _refreshCacheState();
    if (!canSeek) return;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    final Duration clamped;
    if (_seekableRanges.isNotEmpty) {
      clamped = _clampToSeekable(position) ?? position;
    } else {
      final upper = _lastDuration > Duration.zero ? _lastDuration : position;
      clamped = position < Duration.zero ? Duration.zero : (position > upper ? upper : position);
    }
    await _seekAbsolute(clamped, exact: true, expectedTarget: clamped);
  }

  @override
  Future<void> seekRelative(Duration offset) async {
    if (!canSeek) return;
    // Pre-seek refresh for the same stale-window reason as seekToFraction.
    await _refreshCacheState();
    if (!canSeek) return;
    final now = DateTime.now();
    final pending = _pendingSeekTarget;
    final pendingAt = _pendingSeekAt;
    final usePending = pending != null && pendingAt != null && now.difference(pendingAt) < const Duration(seconds: 2);
    Duration base = _lastPosition;
    if (usePending) {
      base = pending;
    }
    if (!_isInAnySeekableRange(base) && _seekableRanges.isNotEmpty) {
      final baseSnapped = _clampToSeekable(base);
      if (baseSnapped != null) {
        base = baseSnapped;
      }
    }
    final target = base + offset;
    Duration snapped;
    if (_seekableRanges.isNotEmpty) {
      snapped = _clampToSeekableWithDirection(target, offset) ?? target;
    } else {
      snapped = target;
    }
    final upperBound = _lastDuration > Duration.zero
        ? _lastDuration
        : (liveEdgePosition > Duration.zero ? liveEdgePosition : const Duration(seconds: 60));
    if (snapped < Duration.zero) snapped = Duration.zero;
    if (snapped > upperBound) snapped = upperBound;
    _pendingSeekTarget = snapped;
    _pendingSeekAt = now;
    await _seekAbsolute(snapped, exact: false, expectedTarget: snapped);
  }

  @override
  Future<void> seekToLiveEdge() async {
    if (!canSeek) return;
    // Freshness matters here too — `liveEdgePosition` / `_clampToSeekable`
    // both read `_seekableRanges` which may be stale by up to 500 ms.
    await _refreshCacheState();
    if (!canSeek) return;
    final Duration target;
    if (_seekableRanges.isNotEmpty) {
      // Seek just inside the newest cached range instead of issuing a
      // `seek 100 absolute-percent` (which reconnects live streams). The
      // Back off from the live edge by a couple of seconds. Landing too close
      // to seek_end leaves almost no forward buffer, which makes the h264
      // decoder fail with "reference picture missing" / "mmco: unref short
      // failure" because B-frames near the edge need future frames that have
      // not been downloaded yet. Seeking a few seconds back gives the decoder
      // enough buffered lookahead; playback then catches up to the live edge
      // smoothly.
      const backOff = Duration(seconds: 2);
      final edge = liveEdgePosition;
      final desired = edge > backOff ? edge - backOff : edge;
      target = _clampToSeekable(desired) ?? desired;
    } else {
      // No cached ranges (VOD or early live): `duration` points at the
      // buffered end, which is the live edge for live streams.
      final dur = _lastDuration;
      const backOff = Duration(seconds: 2);
      target = dur > backOff ? dur - backOff : (dur > Duration.zero ? dur : _lastPosition);
    }
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    // expectedTarget == target means we accept landing at (or near) the live
    // edge — the post-seek reconnect detection is suppressed in that case.
    await _seekAbsolute(target, exact: true, expectedTarget: target);
  }
}

class _NativeDiagnostic {
  const _NativeDiagnostic({required this.message, required this.prefix, required this.generation});

  final String message;
  final String? prefix;
  final int generation;
}
