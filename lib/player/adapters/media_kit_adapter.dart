import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/core/common/log.dart';
import 'package:pure_live/plugins/file_utils.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:pure_live/player/utils/player_consts.dart';
import 'package:pure_live/player/models/player_state.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:pure_live/player/models/player_engine.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/player/models/player_exception.dart';
import 'package:pure_live/player/models/player_error_type.dart';
import 'package:pure_live/player/utils/playback_cache_policy.dart';
import 'package:pure_live/player/shaders/shader_asset_service.dart';
import 'package:pure_live/player/models/player_super_resolution.dart';
import 'package:pure_live/common/utils/latest_async_value_queue.dart';
import 'package:pure_live/player/interface/unified_player_interface.dart';
import 'package:pure_live/player/interface/media_kit_player_accessor.dart';

class MediaKitAdapter implements UnifiedPlayer, MediaKitPlayerAccessor {
  MediaKitAdapter() {
    _audioModeTransitions = LatestAsyncValueQueue<bool>(_applyAudioOnly);
  }

  late final Player _player;
  late final VideoController _controller;

  bool _initialized = false;
  bool _disposed = false;
  bool _listenerBound = false;

  String? _currentUrl;
  bool _isAudioOnly = false;

  SuperResolutionMode _superResolutionMode = SuperResolutionMode.off;

  late final LatestAsyncValueQueue<bool> _audioModeTransitions;

  late final PlaybackCachePolicy _cachePolicy;

  final _stateSubject = BehaviorSubject<PlayerState>.seeded(PlayerState.idle);

  final _playingSubject = BehaviorSubject<bool>.seeded(false);

  final _loadingSubject = BehaviorSubject<bool>.seeded(false);

  final _errorSubject = PublishSubject<PlayerException>();

  final _completeSubject = BehaviorSubject<bool>.seeded(false);

  final _widthSubject = BehaviorSubject<int?>.seeded(null);

  final _heightSubject = BehaviorSubject<int?>.seeded(null);

  final _videoFrameProgressSubject = PublishSubject<int>();

  final List<StreamSubscription> _subscriptions = [];

  StreamSubscription? _playingSub;
  StreamSubscription? _bufferingSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _videoParamsSub;
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

  /// Polls `demuxer-cache-state` because mpv does not push property-change
  /// events for this structured property. The `duration` property is polled
  /// as well so the live timeline length (which keeps growing for live
  /// streams) stays in sync even if the duration stream event is delayed.
  Timer? _cacheStateTimer;

  static Future<void> applyNativeLiveProperties(NativePlayer native) async {
    await native.setProperty('force-seekable', 'yes');

    await native.setProperty(
      'protocol_whitelist',
      'httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt',
    );
    await native.setProperty('demuxer-cache-dir', await FileUtils().getTempPath());

    await native.setProperty('demuxer-lavf-probesize', '2097152');

    // Live FLV/HLS streams need a short probe rather than a long-file
    // analysis pass.  This reduces the black-screen interval before the
    // first decoded frame while retaining enough data for codec detection.
    await native.setProperty('demuxer-lavf-analyzeduration', '2');

    await native.setProperty('network-timeout', '15');

    await native.setProperty('hwdec-software-fallback', '1');

    await native.setProperty('volume-max', '100');
  }

  static Future<void> _configureAndroidCustomOutput(NativePlayer native) async {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return;
    }

    if (PlatformUtils.isAndroid && settings.playerCompatMode.v) {
      return;
    }
    if (settings.audioOutputDriver.v != 'auto') {
      await native.setProperty(
        'ao',
        settings.androidEnableOpenSLES.v ? 'opensles' : settings.audioOutputDriver.v,
      );
    }

    await native.setProperty('volume-max', '100');

    await native.setProperty('hwdec-software-fallback', '1');
  }

  static Future<void> _configureWindowsCustomOutput(NativePlayer native) async {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return;
    }

    if (settings.enableRtxVsr.v) {
      await native.setProperty('vf', 'd3d11vpp=scale=2:scaling-mode=nvidia');
    }
    if (settings.audioOutputDriver.v != 'auto') {
      await native.setProperty('ao', settings.audioOutputDriver.v);
    }
  }

  static Future<void> _configureMacOSCustomOutput(NativePlayer native) async {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return;
    }
    if (settings.audioOutputDriver.v != 'auto') {
      await native.setProperty('ao', settings.audioOutputDriver.v);
    }
  }

  static Future<void> _configureIOSCustomOutput(NativePlayer native) async {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return;
    }
    if (settings.audioOutputDriver.v != 'auto') {
      await native.setProperty('ao', settings.audioOutputDriver.v);
    }
  }

  static Future<void> _configureLinuxCustomOutput(NativePlayer native) async {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return;
    }

    if (settings.audioOutputDriver.v != 'auto') {
      await native.setProperty('ao', settings.audioOutputDriver.v);
    }
  }

  SuperResolutionMode _resolveInitialSuperResolutionMode() {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return SuperResolutionMode.off;
    }

    if (PlatformUtils.isAndroid && settings.playerCompatMode.v) {
      return SuperResolutionMode.off;
    }

    if (PlatformUtils.isIOS) {
      return SuperResolutionMode.off;
    }

    if (PlatformUtils.isWindows && settings.enableRtxVsr.v) {
      return SuperResolutionMode.off;
    }

    return SuperResolutionMode.fromStorageValue(settings.defaultSuperResolutionMode.v);
  }

  List<String> _getSuperResolutionShaders() {
    return switch (_superResolutionMode) {
      SuperResolutionMode.off => const <String>[],
      SuperResolutionMode.efficiency => PlayerConsts.mpvAnime4KShadersLiteKeys,
      SuperResolutionMode.quality => PlayerConsts.mpvAnime4KShaderKeys,
    };
  }

  Future<void> _configureSuperResolution() async {
    if (_disposed) {
      return;
    }

    if (_player.platform is! NativePlayer) {
      return;
    }

    final native = _player.platform as NativePlayer;

    await native.waitForPlayerInitialization;
    await native.waitForVideoControllerInitializationIfAttached;

    if (_disposed) {
      return;
    }

    final shaders = _getSuperResolutionShaders();

    await _applyShaderList(native, shaders);
  }

  Future<void> _applyShaderList(NativePlayer native, List<String> shaders) async {
    if (shaders.isEmpty) {
      await native.command(['change-list', 'glsl-shaders', 'clr', '']);

      return;
    }

    final shaderCommand = FileUtils().buildShadersAbsolutePath(
      ShaderAssetService.instance.shadersDirectoryPath!,
      shaders,
    );

    await native.command(['change-list', 'glsl-shaders', 'set', shaderCommand]);
  }

  Future<void> setSuperResolution(SuperResolutionMode mode) async {
    if (_disposed) {
      return;
    }

    if (_player.platform is! NativePlayer) {
      return;
    }

    if (!_isSuperResolutionSupported()) {
      if (_superResolutionMode != SuperResolutionMode.off) {
        final oldMode = _superResolutionMode;

        _superResolutionMode = SuperResolutionMode.off;

        try {
          await _configureSuperResolution();
        } catch (_) {
          _superResolutionMode = oldMode;
        }
      }

      return;
    }

    final oldMode = _superResolutionMode;

    if (oldMode == mode) {
      return;
    }

    try {
      _superResolutionMode = mode;

      await _configureSuperResolution();

      Log.i(
        'MediaKitAdapter: super resolution changed '
        '${oldMode.name} -> ${mode.name}',
      );
    } catch (e, s) {
      _superResolutionMode = oldMode;

      Log.e('MediaKitAdapter: failed to set super resolution', s);

      try {
        await _configureSuperResolution();
      } catch (restoreError, restoreStack) {
        Log.e(
          'MediaKitAdapter: failed to restore previous '
          'super resolution shader',
          restoreStack,
        );
      }

      rethrow;
    }
  }

  bool _isSuperResolutionSupported() {
    final settings = SettingsService.to.player;

    if (!settings.customPlayerOutput.v) {
      return false;
    }

    if (PlatformUtils.isAndroid && settings.playerCompatMode.v) {
      return false;
    }

    if (PlatformUtils.isIOS) {
      return false;
    }

    if (PlatformUtils.isWindows && settings.enableRtxVsr.v) {
      return false;
    }

    return true;
  }

  Future<VideoControllerConfiguration> _buildVideoControllerConfiguration() async {
    final settings = SettingsService.to.player;
    final customOutput = settings.customPlayerOutput.v;
    if (!customOutput) {
      _superResolutionMode = SuperResolutionMode.off;

      return VideoControllerConfiguration(enableHardwareAcceleration: settings.enableCodec.v);
    }
    if (PlatformUtils.isAndroid && settings.playerCompatMode.v) {
      _superResolutionMode = SuperResolutionMode.off;

      return const VideoControllerConfiguration(
        vo: 'mediacodec_embed',
        hwdec: 'mediacodec',
        enableHardwareAcceleration: true,
        enableAndroidSurfaceProducer: false,
        androidAttachSurfaceAfterVideoParameters: false,
      );
    }

    String? vo;
    String? hwdec;
    if (PlatformUtils.isAndroid) {
      final renderer =
          settings.videoOutputDriver.v.isEmpty || settings.videoOutputDriver.v == 'auto'
          ? 'gpu'
          : settings.videoOutputDriver.v;

      if (renderer.isEmpty || renderer == 'auto') {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        vo = androidInfo.version.sdkInt >= 34 ? 'gpu-next' : 'gpu';
      } else {
        vo = renderer;
      }

      hwdec = settings.videoHardwareDecoder.v;
    } else if (PlatformUtils.isWindows) {
      final driver = settings.videoOutputDriver.v;

      if (driver.isNotEmpty && driver != 'auto') {
        vo = driver;
      }

      hwdec = settings.enableRtxVsr.v ? 'd3d11va' : settings.videoHardwareDecoder.v;
    } else if (PlatformUtils.isLinux) {
      final driver = settings.videoOutputDriver.v;
      if (driver.isNotEmpty && driver != 'auto') {
        vo = driver;
      }
      hwdec = settings.videoHardwareDecoder.v;
    } else if (PlatformUtils.isMacOS) {
      final driver = settings.videoOutputDriver.v;

      if (driver.isNotEmpty && driver != 'auto') {
        vo = driver;
      }

      hwdec = settings.videoHardwareDecoder.v;
    } else if (PlatformUtils.isIOS) {
      final driver = settings.videoOutputDriver.v;
      if (driver.isNotEmpty && driver != 'auto') {
        vo = driver;
      }
      hwdec = settings.videoHardwareDecoder.v;
    }

    final enableHardwareAcceleration = settings.enableCodec.v;
    Log.i(
      'MediaKit VideoOutput: '
      'videoOutputDriver=${settings.videoOutputDriver.v}, '
      'audioOutputDriver=${settings.audioOutputDriver.v}, '
      'vo=$vo, '
      'enableRtxVsr=${settings.enableRtxVsr.v}, '
      'videoHardwareDecoder=${settings.videoHardwareDecoder.v}',
    );
    return VideoControllerConfiguration(
      vo: vo,
      hwdec: hwdec,
      enableHardwareAcceleration: enableHardwareAcceleration,
    );
  }

  @override
  Future<void> init({bool audioOnly = false}) async {
    if (_initialized) {
      return;
    }

    _disposed = false;
    _listenerBound = false;
    _currentUrl = null;
    _isAudioOnly = false;

    _superResolutionMode = _resolveInitialSuperResolutionMode();

    try {
      _stateSubject.add(PlayerState.initializing);
      _cachePolicy = PlaybackCachePolicy(
        isLocalPlayback: () => false,
        currentPlayer: () => _player,
      );
      final settings = SettingsService.to.player;

      _player = Player(configuration: const PlayerConfiguration(osc: false));

      if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;

        await applyNativeLiveProperties(native);
        _cachePolicy.startWatching();
        await _cachePolicy.apply();
        if (settings.customPlayerOutput.v) {
          if (PlatformUtils.isAndroid) {
            if (!settings.playerCompatMode.v) {
              await _configureAndroidCustomOutput(native);
            }
          } else if (PlatformUtils.isWindows) {
            await _configureWindowsCustomOutput(native);
          } else if (PlatformUtils.isMacOS) {
            await _configureMacOSCustomOutput(native);
          } else if (PlatformUtils.isIOS) {
            await _configureIOSCustomOutput(native);
          } else if (PlatformUtils.isLinux) {
            await _configureLinuxCustomOutput(native);
          }
        }
      }

      _controller = VideoController(
        _player,
        configuration: await _buildVideoControllerConfiguration(),
      );

      await _bindListeners();

      if (_superResolutionMode != SuperResolutionMode.off) {
        await _configureSuperResolution();
      }

      await _player.setPlaylistMode(PlaylistMode.none);

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

  @override
  Future<void> setDataSource(
    String url,
    List<String> playUrls,
    Map<String, String> headers, {
    LiveRoom? room,
    bool audioOnly = false,
  }) async {
    if (_disposed) {
      return;
    }

    if (_currentUrl == url && isPlayingNow) {
      return;
    }

    _currentUrl = url;

    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _seekableRanges = const [];
    _pendingSeekTarget = null;
    _pendingSeekAt = null;

    try {
      _loadingSubject.add(true);

      _stateSubject.add(PlayerState.preparing);

      _completeSubject.add(false);

      _widthSubject.add(null);
      _heightSubject.add(null);

      if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;

        final proxy = SettingsService.to.proxy;

        if (proxy.enableProxy.v && proxy.proxyHost.v.isNotEmpty) {
          final proxyUrl = 'http://${proxy.proxyHost.v}:${proxy.proxyPort.v}';

          await native.setProperty('http-proxy', proxyUrl);
        }

        await native.setProperty('vid', audioOnly ? 'no' : 'auto');
      }

      await _player.setAudioTrack(AudioTrack.auto());

      final urls = <String>[url, ...playUrls.where((item) => item.isNotEmpty && item != url)];

      final playlist = Playlist(urls.map((item) => Media(item, httpHeaders: headers)).toList());

      await _player.open(playlist, play: true);

      if (PlatformUtils.isAndroid && !audioOnly) {
        _isAudioOnly = false;
      } else {
        await _applyAudioOnly(audioOnly, force: true);
      }
      if (_superResolutionMode != SuperResolutionMode.off) {
        await _configureSuperResolution();
      }
      _stateSubject.add(PlayerState.ready);

      if (PlatformUtils.isMobile) {
        await setVolume(1.0);
      } else {
        final targetVolume = room?.getSavedVolume() ?? 1.0;
        await setVolume(targetVolume);
      }
    } catch (e, s) {
      final exception = PlayerException(
        message: 'Media open failed',
        type: PlayerErrorType.source,
        error: e,
        stackTrace: s,
      );

      _safeAddError(exception);

      _stateSubject.add(PlayerState.error);

      throw exception;
    } finally {
      if (!_disposed) {
        _loadingSubject.add(false);
      }
    }
  }

  Future<void> _bindListeners() async {
    if (_listenerBound) {
      return;
    }

    _listenerBound = true;

    await _cancelAllSubscriptions();

    _playingSub = _player.stream.playing.listen(
      (playing) {
        if (_disposed) {
          return;
        }

        _playingSubject.add(playing);

        if (!_loadingSubject.value) {
          _stateSubject.add(playing ? PlayerState.playing : PlayerState.paused);
        }
      },
      onError: (e, s) {
        Log.e(e, s);

        _emitError(e, s, PlayerErrorType.native);
      },
    );

    _bufferingSub = _player.stream.buffering.listen(
      (loading) {
        if (_disposed) {
          return;
        }

        _loadingSubject.add(loading);

        if (loading) {
          _stateSubject.add(PlayerState.buffering);
        } else {
          _stateSubject.add(_playingSubject.value ? PlayerState.playing : PlayerState.paused);
        }
      },
      onError: (e, s) {
        Log.e(e, s);

        _emitError(e, s, PlayerErrorType.native);
      },
    );

    _completeSub = _player.stream.completed.listen(
      (completed) {
        if (_disposed || !completed) {
          return;
        }

        _completeSubject.add(true);

        _stateSubject.add(PlayerState.completed);
      },
      onError: (e, s) {
        Log.e(e, s);

        _emitError(e, s, PlayerErrorType.native);
      },
    );

    _videoParamsSub = _player.stream.videoParams.listen((params) {
      if (_disposed) return;
      final width = params.dw ?? params.w;
      final height = params.dh ?? params.h;

      if (width != null && width > 0) {
        _widthSubject.add(width);
      }

      if (height != null && height > 0) {
        _heightSubject.add(height);
      }
    });

    _errorSub = _player.stream.error.distinct().listen(
      (error) {
        if (_disposed) {
          return;
        }

        final type = _mapErrorType(error.toString());

        _safeAddError(PlayerException(message: error.toString(), type: type));

        _stateSubject.add(PlayerState.error);
      },
      onError: (e, s) {
        Log.e(e, s);

        _emitError(e, s, PlayerErrorType.native);
      },
    );

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

    _subscriptions.addAll([
      _playingSub!,
      _bufferingSub!,
      _completeSub!,
      _errorSub!,
      _videoParamsSub!,
      _positionSub!,
      _durationSub!,
    ]);

    _startCacheStatePolling();
  }

  Future<void> _cancelAllSubscriptions() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }

    _subscriptions.clear();

    _playingSub = null;
    _bufferingSub = null;
    _completeSub = null;
    _errorSub = null;
    _videoParamsSub = null;
    _positionSub = null;
    _durationSub = null;
  }

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
      if (_disposed || _player.platform is! NativePlayer) return;
      try {
        final native = _player.platform as NativePlayer;
        final raw = await native.getProperty('demuxer-cache-state');
        if (_disposed) return;
        _seekableRanges = parseSeekableRanges(raw);
        // For live streams mpv's `duration` keeps growing (highest buffered
        // PTS minus stream start). Poll it as a backstop for the duration
        // stream subscription, which can lag property updates slightly.
        final durationRaw = await native.getProperty('duration');
        if (_disposed) return;
        final seconds = double.tryParse(durationRaw);
        if (seconds != null && seconds.isFinite && seconds >= 0) {
          final d = Duration(microseconds: (seconds * 1e6).round());
          if (d > _lastDuration) _lastDuration = d;
        }
      } catch (_) {
        // Property lookup can fail while the player is switching sources;
        // the next tick will retry.
      }
    });
  }

  void _stopCacheStatePolling() {
    _cacheStateTimer?.cancel();
    _cacheStateTimer = null;
  }

  void _emitError(Object error, StackTrace stackTrace, PlayerErrorType type) {
    if (_disposed) {
      return;
    }

    _safeAddError(
      PlayerException(message: error.toString(), type: type, error: error, stackTrace: stackTrace),
    );

    _stateSubject.add(PlayerState.error);
  }

  void _safeAddError(PlayerException exception) {
    if (_disposed || _errorSubject.isClosed) {
      return;
    }

    _errorSubject.add(exception);
  }

  PlayerErrorType _mapErrorType(String error) {
    final lower = error.toLowerCase();

    if (lower.contains('network') || lower.contains('timeout') || lower.contains('io')) {
      return PlayerErrorType.network;
    }

    if (lower.contains('codec') || lower.contains('mediacodec') || lower.contains('decode')) {
      return PlayerErrorType.codec;
    }

    if (lower.contains('404') || lower.contains('source') || lower.contains('open')) {
      return PlayerErrorType.source;
    }

    if (lower.contains('surface') || lower.contains('texture')) {
      return PlayerErrorType.texture;
    }

    Log.d(error);

    return PlayerErrorType.native;
  }

  @override
  Widget getVideoWidget(BoxFit fit) {
    return StreamBuilder<List<int?>>(
      stream: CombineLatestStream.list<int?>([_widthSubject, _heightSubject]),
      builder: (context, snapshot) {
        final width = snapshot.data?[0];
        final height = snapshot.data?[1];

        double ratio = 16 / 9;

        if (width != null && height != null && width > 0 && height > 0) {
          ratio = width / height;
        }

        return Video(
          controller: _controller,
          controls: NoVideoControls,
          aspectRatio: ratio,
          fit: fit,
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
        );
      },
    );
  }

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

    _stateSubject.add(PlayerState.stopped);
  }

  @override
  Future<void> softStop() async {
    await _player.setVolume(0.0);

    await _player.stop();

    _currentUrl = null;
    _isAudioOnly = false;

    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _seekableRanges = const [];
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
    if (_disposed) {
      return;
    }

    if (!force && _isAudioOnly == audioOnly) {
      return;
    }

    try {
      if (PlatformUtils.isAndroid) {
        if (audioOnly) {
          await _player.setVideoTrack(VideoTrack.no());
        } else {
          await _restoreAndroidVideoOutput();
        }
      } else {
        await _player.setVideoTrack(audioOnly ? VideoTrack.no() : VideoTrack.auto());
      }

      _isAudioOnly = audioOnly;
    } catch (error, stackTrace) {
      throw PlayerException(
        message: 'MediaKit audio mode switch failed',
        type: PlayerErrorType.lifecycle,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _restoreAndroidVideoOutput() async {
    final frameReady = Completer<void>();

    var armed = false;

    final subscription = _player.stream.videoParams.listen((params) {
      final width = params.dw ?? params.w ?? 0;

      final height = params.dh ?? params.h ?? 0;

      if (armed && width > 0 && height > 0 && !frameReady.isCompleted) {
        frameReady.complete();
      }
    });

    try {
      armed = true;

      await _player.setVideoTrack(VideoTrack.auto());

      var observedFreshFrame = true;

      await frameReady.future.timeout(
        const Duration(milliseconds: 2800),
        onTimeout: () {
          observedFreshFrame = false;
        },
      );

      if (observedFreshFrame) {
        await Future<void>.delayed(const Duration(milliseconds: 34));
      }
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final vol = (volume * 100).clamp(0.0, 100.0);

    await _player.setVolume(vol);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    await _player.setRate(speed);
  }

  Future<void> setProperty(String property, String value) async {
    if (_disposed) {
      return;
    }

    if (_player.platform is! NativePlayer) {
      return;
    }

    final native = _player.platform as NativePlayer;

    await native.setProperty(property, value);
  }

  @override
  Duration get currentPosition => _lastPosition;

  /// Full timeline length reported by mpv (`duration`). For live streams
  /// this keeps growing from stream start (highest buffered PTS - start),
  /// exactly the scale mpv's own seekbar maps `percent-pos` onto.
  Duration get streamDuration => _lastDuration;

  /// Playhead position as a 0.0–1.0 fraction of the full timeline. This is
  /// mathematically identical to mpv's `percent-pos / 100`
  /// (`get_current_pos_ratio` in playloop.c is `time-pos / duration`), but
  /// derived from the high-frequency position stream so the handle moves
  /// smoothly without waiting for property polls.
  double? get positionFraction {
    final total = _lastDuration.inMicroseconds;
    if (total <= 0) return null;
    return (_lastPosition.inMicroseconds / total).clamp(0.0, 1.0);
  }

  /// Seekable cached ranges projected onto the 0.0–1.0 timeline fraction,
  /// in the same coordinate space as [positionFraction]. mpv's OSC computes
  /// the identical mapping (`range / duration`) to draw its cache overlay.
  List<({double start, double end})> get seekableFractions {
    final total = _lastDuration.inMicroseconds;
    if (total <= 0 || _seekableRanges.isEmpty) return const [];
    return _seekableRanges
        .map(
          (r) => (
            start: (r.start.inMicroseconds / total).clamp(0.0, 1.0),
            end: (r.end.inMicroseconds / total).clamp(0.0, 1.0),
          ),
        )
        .toList();
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
    final t = pos.inMicroseconds;
    for (final r in _seekableRanges) {
      if (t >= r.start.inMicroseconds && t <= r.end.inMicroseconds) return true;
    }
    return false;
  }

  Duration? _clampToSeekableWithDirection(Duration target, Duration offset) {
    if (_seekableRanges.isEmpty) return null;
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

  Future<void> _seekAbsolute(Duration position, {required bool exact}) async {
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
      Log.w('seekAbsolute failed: $e');
    }
  }

  /// Seek to a 0.0–1.0 fraction of the full timeline. The fraction is
  /// converted to an absolute time and snapped into the cached seekable
  /// ranges before being sent to mpv — see [_clampToSeekable]. When no
  /// cached ranges are known yet (VOD or a just-started live stream) the
  /// target is forwarded as-is so seeking still works.
  Future<void> seekToFraction(double fraction, {bool exact = false}) async {
    if (!canSeek) return;
    final total = _lastDuration.inMicroseconds;
    if (total <= 0) return;
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    final f = fraction.clamp(0.0, 1.0);
    final target = Duration(microseconds: (f * total).round());
    final snapped = _seekableRanges.isNotEmpty ? (_clampToSeekable(target) ?? target) : target;
    await _seekAbsolute(snapped, exact: exact);
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
    if (_seekableRanges.isNotEmpty) {
      return _seekableRanges.map((r) => r.start).reduce((a, b) => a < b ? a : b);
    }
    // No range data: report a zero-width window at the playhead rather than
    // deriving a bogus start from `position - duration`.
    return _lastPosition;
  }

  bool get isUserSeekedBack {
    if (_seekableRanges.isEmpty) return false;
    return liveEdgePosition - _lastPosition > const Duration(seconds: 2);
  }

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
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    final Duration clamped;
    if (_seekableRanges.isNotEmpty) {
      clamped = _clampToSeekable(position) ?? position;
    } else {
      final upper = _lastDuration > Duration.zero ? _lastDuration : position;
      clamped = position < Duration.zero ? Duration.zero : (position > upper ? upper : position);
    }
    await _seekAbsolute(clamped, exact: true);
  }

  @override
  Future<void> seekRelative(Duration offset) async {
    if (!canSeek) return;
    final now = DateTime.now();
    final pending = _pendingSeekTarget;
    final pendingAt = _pendingSeekAt;
    final usePending =
        pending != null &&
        pendingAt != null &&
        now.difference(pendingAt) < const Duration(seconds: 2);
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
    await _seekAbsolute(snapped, exact: false);
  }

  @override
  Future<void> seekToLiveEdge() async {
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
    await _seekAbsolute(target, exact: true);
  }

  Future<void> setPrefetchSuspended(bool suspended) async {
    if (_disposed) {
      return;
    }

    _cachePolicy.setPrefetchSuspended(suspended);
  }

  @override
  Future<void> hardDispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    _initialized = false;
    _listenerBound = false;

    _stopCacheStatePolling();

    await _cancelAllSubscriptions();

    try {
      await _player.stop();
    } catch (_) {}

    try {
      await _player.dispose();
    } catch (_) {}

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

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isPlayingNow => _playingSubject.value;

  @override
  bool get isReusable => PlatformUtils.isWindows;

  SuperResolutionMode get superResolutionMode => _superResolutionMode;

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
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Player get mediaKitPlayer => _player;

  @override
  VideoController get mediaKitVideoController => _controller;
}
