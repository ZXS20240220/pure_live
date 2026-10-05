import 'dart:io';
import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:pure_live/core/common/hls_source_query_policy.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/core/interface/live_quality_discovery.dart';

import 'playback_source_transport.dart';
import 'playback_source.dart';
import 'playback_header_resolver.dart';

import 'line_fallback_manager.dart';
import 'live_stream_geometry_hint.dart';
import 'portrait_stream_support.dart';
import '../models/player_state.dart';
import '../models/player_engine.dart';
import 'engine_fallback_manager.dart';
import 'playback_lifecycle_coordinator.dart';

import 'package:floating/floating.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, Uint8List;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../models/player_exception.dart';

import 'package:remixicon/remixicon.dart';

import '../models/player_error_type.dart';

import 'package:rxdart/rxdart.dart' hide Rx;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/player_settings_controller.dart';

import '../interface/unified_player_interface.dart';

import 'package:pure_live/routes/app_navigation.dart';
import 'package:pure_live/model/live_play_quality.dart';
import 'package:pure_live/player/utils/fullscreen.dart';
import 'package:pure_live/player/utils/window_helper.dart';
import 'package:flutter_floating/flutter_floating.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/player/utils/player_consts.dart';
import 'package:pure_live/player/utils/popup_route_tracker.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/core/site/huya/huya_transport_policy.dart';
import 'package:pure_live/player/utils/pip_window_widget.dart';
import 'package:pure_live/player/core/live_audio_service.dart';
import 'package:pure_live/common/utils/latest_async_value_queue.dart';
import 'package:pure_live/player/adapters/player_adapter_factory.dart';
import 'package:pure_live/player/adapters/media_kit_adapter.dart';
import 'package:pure_live/player/interface/media_kit_player_accessor.dart';
import 'package:pure_live/player/utils/media_kit_content_probe.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/compact_danmaku_overlay.dart';
import 'package:pure_live/modules/multiview/danmaku/multiview_danmaku_session.dart';
import 'package:pure_live/player/core/flv_splice_relay.dart';

typedef UnifiedPlayerCreator = FutureOr<UnifiedPlayer> Function(PlayerEngine engine);
typedef WindowsPipEnter = Future<void> Function(double videoRatio, {int? videoWidth, int? videoHeight});
typedef WindowsPipExit = Future<void> Function();

@immutable
class PlaybackSourceRefreshRequest {
  const PlaybackSourceRefreshRequest({
    required this.currentLineIndex,
    required this.advanceLine,
    this.currentUrl,
    this.currentQuality,
    this.currentSource,
  });

  final int currentLineIndex;
  final bool advanceLine;
  final PlaybackSource? currentSource;

  /// The active transport, not a URL captured when the room first opened.
  /// Refreshed manifests may reorder or remove CDN entries.
  final String? currentUrl;

  /// The quality which owns the active native source. Resolvers must prefer
  /// this value over a quality captured when the route first opened: the route
  /// may have been disposed while an application-floating session continued.
  final LivePlayQuality? currentQuality;
}

@immutable
class PlaybackSourceQualitySelection {
  factory PlaybackSourceQualitySelection({
    required List<LivePlayQuality> qualities,
    required int currentQuality,
    Map<String, HlsSourceQueryPolicy> sourceQueryPolicies = const {},
  }) {
    final immutableQualities = List<LivePlayQuality>.unmodifiable(qualities);
    if (immutableQualities.isEmpty) {
      throw ArgumentError.value(qualities, 'qualities', 'must contain the committed quality');
    }
    for (final entry in sourceQueryPolicies.entries) {
      final source = Uri.tryParse(entry.key);
      if (source == null || !entry.value.matchesSource(source)) {
        throw const FormatException('Source query policy does not match its source key');
      }
    }
    return PlaybackSourceQualitySelection._(
      immutableQualities,
      currentQuality.clamp(0, immutableQualities.length - 1),
      Map<String, HlsSourceQueryPolicy>.unmodifiable(sourceQueryPolicies),
    );
  }

  const PlaybackSourceQualitySelection._(this.qualities, this.currentQuality, this.sourceQueryPolicies);

  final List<LivePlayQuality> qualities;
  final int currentQuality;

  /// In-memory capabilities of this resolved source cohort, keyed by exact
  /// remote URL, not by quality or by a token parameter shared across sources.
  final Map<String, HlsSourceQueryPolicy> sourceQueryPolicies;

  LivePlayQuality get quality => qualities[currentQuality];
}

@immutable
class PlaybackSourceRefreshResult {
  const PlaybackSourceRefreshResult({
    required this.urls,
    required this.preferredLineIndex,
    this.refreshAt,
    this.invalidAt,
    this.selection,
  }) : ownedSource = null;

  const PlaybackSourceRefreshResult.owned({
    required OwnedPlaybackSource source,
    this.refreshAt,
    this.invalidAt,
    this.selection,
  }) : ownedSource = source,
       urls = const [],
       preferredLineIndex = 0;

  final OwnedPlaybackSource? ownedSource;
  bool get hasSources => ownedSource != null || urls.isNotEmpty;
  final List<String> urls;
  final int preferredLineIndex;
  final DateTime? refreshAt;
  final DateTime? invalidAt;
  final PlaybackSourceQualitySelection? selection;
}

/// Immutable source metadata published only after the corresponding native
/// source transaction has committed.
@immutable
class PlaybackSourceCommitSnapshot {
  PlaybackSourceCommitSnapshot({
    required this.revision,
    required this.sessionId,
    required this.intentRevision,
    required this.room,
    required List<String> urls,
    String? currentUrl,
    PlaybackSource? source,
    required this.currentLineIndex,
    required Map<String, String> headers,
    required this.audioOnly,
    required this.selection,
  }) : source = _resolveCommitSource(source, currentUrl),
       urls = List<String>.unmodifiable(urls),
       headers = Map<String, String>.unmodifiable(headers);

  static PlaybackSource _resolveCommitSource(PlaybackSource? source, String? url) {
    if (source != null && (url == null || source.url == url)) return source;
    if (source == null && url != null) return UrlPlaybackSource(url);
    throw ArgumentError('Source commit requires one consistent source');
  }

  final int revision;
  final int sessionId;
  final int intentRevision;
  final LiveRoom room;
  final List<String> urls;
  final PlaybackSource source;

  /// Legacy presentation/export view; owned recipes have no media URL.
  String get currentUrl => source.url ?? '';
  final int currentLineIndex;
  final Map<String, String> headers;
  final bool audioOnly;
  final PlaybackSourceQualitySelection? selection;
}

typedef PlaybackSourceResolver = Future<PlaybackSourceRefreshResult> Function(PlaybackSourceRefreshRequest request);

class _PlaybackCredentialPrefetch {
  const _PlaybackCredentialPrefetch(this.sessionId, this.intentRevision, this.operation);

  final int sessionId;
  final int intentRevision;
  final Future<bool> operation;

  bool belongsTo(int session, int intent) => sessionId == session && intentRevision == intent;
}

enum _PlaybackSuspensionReason { lifecycle, audioInterruption }

class PlayerManager {
  final EngineFallbackManager fallbackManager;
  final LineFallbackManager lineManager;
  final Duration audioModeSwitchTimeout;
  final Duration sourceOpenTimeout;
  final Duration sourceRefreshTimeout;
  final Duration sourceReadyTimeout;
  final Duration unexpectedPauseGrace;
  final Duration unexpectedPauseFailureGrace;
  final Duration bufferingStallTimeout;
  final Duration videoFrameStallTimeout;
  final Duration recoveryBudgetResetDelay;
  final List<Duration> transientLiveRetryDelays;
  final Duration idlePlayerReleaseDelay;
  final bool enableActiveContentProbe;

  /// Compatibility interval for Windows Huya web/HLS fallback transports only.
  /// Validated native FLV credentials bypass this timer and keep a healthy
  /// connection open. A fallback edge connection has ended as early as roughly
  /// 100 seconds while its longer `wsTime` lease remained valid. Native
  /// room resolution plus D3D/player initialization has also consumed about
  /// 51 seconds in a real Windows run, so the hand-off starts after 40 seconds.
  /// This leaves about a minute before the shortest isolated connection end
  /// observed here, without changing other platforms or non-Huya streams.
  final Duration windowsHuyaProactiveRefreshInterval;

  /// How long a manual foreground audio session keeps video decode warm.
  /// `null` retains it until the app backgrounds; [Duration.zero] selects the
  /// immediate low-power behaviour used by automatic ASMR and focused tests.
  final Duration? audioModeVideoWarmRetention;
  final UnifiedPlayerCreator _playerCreator;
  final bool Function() _suppressAutomaticFallbackAudio;
  final bool Function() _useHardStopOnExit;
  final Floating? _androidFloatingOverride;
  bool get _usesAndroidPip => PlatformUtils.isAndroid || _androidFloatingOverride != null;
  final bool _usesWindowsPipOverride;
  bool get _usesWindowsPip => !_usesAndroidPip && (Platform.isWindows || _usesWindowsPipOverride);
  final WindowsPipEnter _windowsPipEnter;
  final WindowsPipExit _windowsPipExit;
  final Future<void> Function(UnifiedPlayer player, bool audioOnly)? _audioModeServiceSync;
  final Future<void> Function(LiveRoom room) _audioSessionStart;
  Future<void> _playerLifecycleQueue = Future.value();
  int _sessionId = 0;
  int _playbackIntentRevision = 0;
  bool _playbackRequested = false;
  bool _playbackIntentEstablished = false;
  bool _videoPresentationVisible = true;
  // Native buffering is independent of the loading UI written by recovery.
  // Event revisions let an in-flight recovery notice that its observation was
  // refuted, even if another buffering cycle begins before a resolver returns.
  bool _nativeLoading = false;
  int _bufferingRecoveryRevision = 0;
  int _playingRecoveryRevision = 0;
  final Set<_PlaybackSuspensionReason> _playbackSuspensions = <_PlaybackSuspensionReason>{};
  Timer? _continuityTimer;
  Timer? _bufferingStallTimer;
  Timer? _videoFrameStallTimer;
  final Stopwatch _videoFrameWatchdogClock = Stopwatch();
  Duration? _videoFrameDeadline;
  int _continuityRevision = 0;
  DateTime? _lastPresentedFrameAt;
  int _presentedFrameRevision = 0;
  bool _isClosing = false;
  int _sameEngineRecoveryAttempts = 0;
  int _sourceRefreshAttempts = 0;
  int _transientLiveRetryAttempts = 0;
  PlaybackSourceResolver? _sourceRefreshResolver;
  Timer? _sourceRefreshAttemptResetTimer;
  Timer? _transientLiveRetryTimer;
  // A timer can finish while its queued resolver/candidate still owns work.
  // Keep the operation alive until commit, cancellation or async completion.
  _PendingPlayerError? _transientLiveRetryOwner;
  int _transientLiveRetryRevision = 0;
  Timer? _proactiveSourceRefreshTimer;
  DateTime? _currentSourceRefreshAt;
  PlaybackSourceRefreshResult? _prefetchedSourceRefresh;
  _PlaybackCredentialPrefetch? _credentialPrefetch;
  final StreamController<PlaybackSourceCommitSnapshot> _sourceCommitController =
      StreamController<PlaybackSourceCommitSnapshot>.broadcast();
  PlaybackSourceCommitSnapshot? _currentSourceCommit;
  int _sourceCommitRevision = 0;
  PlaybackSourceQualitySelection? _sourceCohortSelection;
  LiveRoom? _sourceCohortRoom;
  PlaybackSource? _sourceCohortSource;
  final Map<UnifiedPlayer, PlaybackSourceTransport> _sourceTransports = Map.identity();

  /// Players whose leased FLV source is renewed by [FlvSpliceRelay]. Their
  /// lease needs no proactive credential refresh or reopen.
  final Set<UnifiedPlayer> _splicedLeasePlayers = Set.identity();
  final PlaybackInputFactory? _sourceInputFactory;

  PlayerManager({
    required this.fallbackManager,
    required this.lineManager,
    this.audioModeSwitchTimeout = const Duration(seconds: 5),
    this.sourceOpenTimeout = const Duration(seconds: 18),
    this.sourceRefreshTimeout = const Duration(seconds: 12),
    this.sourceReadyTimeout = Duration.zero,
    this.unexpectedPauseGrace = const Duration(milliseconds: 350),
    this.unexpectedPauseFailureGrace = const Duration(seconds: 5),
    this.bufferingStallTimeout = const Duration(seconds: 12),
    this.videoFrameStallTimeout = const Duration(seconds: 10),
    this.recoveryBudgetResetDelay = const Duration(seconds: 30),
    this.transientLiveRetryDelays = const <Duration>[Duration(milliseconds: 750), Duration(seconds: 2)],
    this.idlePlayerReleaseDelay = const Duration(seconds: 45),
    this.windowsHuyaProactiveRefreshInterval = const Duration(seconds: 40),
    // media_kit's screenshot path temporarily detaches the Android hardware
    // decoder surface on several ColorOS/Qualcomm devices. Repeated probes
    // then discard every frame and trigger the continuity recovery path,
    // which looks like random pause/reload to the user. Decoder dimensions,
    // platform hints and the manual per-room override remain available.
    this.enableActiveContentProbe = false,
    this.audioModeVideoWarmRetention,
    UnifiedPlayerCreator? playerCreator,
    this._sourceInputFactory,
    Floating? androidFloating,
    bool Function()? useHardStopOnExit,
    bool Function()? suppressAutomaticFallbackAudio,
    this._audioModeServiceSync,
    Future<void> Function(LiveRoom room)? audioSessionStart,
    WindowsPipEnter? windowsPipEnter,
    WindowsPipExit? windowsPipExit,
  }) : _androidFloatingOverride = androidFloating,
       _usesWindowsPipOverride = windowsPipEnter != null || windowsPipExit != null,
       _windowsPipEnter = windowsPipEnter ?? WindowService().enterWinPiP,
       _windowsPipExit = windowsPipExit ?? WindowService().exitWinPiP,
       _playerCreator = playerCreator ?? PlayerAdapterFactory.create,
       _useHardStopOnExit = useHardStopOnExit ?? (() => SettingsService.to.player.useHardStopOnExit.v),
       _suppressAutomaticFallbackAudio = suppressAutomaticFallbackAudio ?? (() => false),
       _audioSessionStart =
           audioSessionStart ??
           ((room) => LiveAudioService.start(room.roomId!, room.title ?? "", room.nick ?? "", room.avatar)) {
    _audioModeTransitions = LatestAsyncValueQueue<bool>(_applyAudioOnlyMode);
    _audioServiceTransitions = LatestAsyncValueQueue<_AudioServiceRequest>(_applyAudioServiceRequest);
    _pipStateSubscription = isInPip.listen((value) {
      GlobalPlayerState.to.isPipMode.value = value;
      if (!value) {
        _lastAppliedPipAspectRatio = null;
        _pipGeometryUpdateGeneration++;
      }
      if (!value && !isFloating.value && !_appFloatingPrepared) {
        _videoController?.clearPipDanmaku();
      }
    });
  }

  bool _isSessionValid(int id) => !_disposed && !_isClosing && _sessionId == id;

  bool _isPlaybackCommandCurrent(int revision) =>
      !_disposed && !_isClosing && _playbackRequested && _playbackIntentRevision == revision;

  PlaybackSourceCommitSnapshot? get currentSourceCommit => _currentSourceCommit;

  Stream<PlaybackSourceCommitSnapshot> get onSourceCommitted => _sourceCommitController.stream;

  bool isSourceCommitCurrent(PlaybackSourceCommitSnapshot snapshot) {
    final current = _currentSourceCommit;
    return !_disposed &&
        !_isClosing &&
        current != null &&
        current.revision == snapshot.revision &&
        current.sessionId == snapshot.sessionId &&
        current.intentRevision == snapshot.intentRevision &&
        current.room == snapshot.room &&
        current.sessionId == _sessionId &&
        current.room == currentFloatRoom &&
        current.source == _currentSource;
  }

  UnifiedPlayer? _currentPlayer;
  // Windows uses a first-frame-gated handoff for actual source failures and
  // short-lived fallback transports, not periodic native Huya FLV replacement.
  // Keep the retired
  // native player initialized but with its media unloaded, then alternate the
  // two instances. Recreating D3D/player state for every lease consumed up to
  // tens of seconds in one real run and also produced avoidable native-memory
  // churn. A soft-stopped player owns no live transport or decoder buffers.
  UnifiedPlayer? _windowsWarmStandbyPlayer;
  bool? _windowsWarmStandbyAudioOnly;
  PlayerEngine? _runtimeEngine;
  PlayerEngine? _defaultEngine;
  bool _runtimeAudioOnly = false;
  bool _requestedAudioOnly = false;
  bool _nativeAudioOnly = false;
  Timer? _audioModeVideoWarmTimer;
  Timer? _idlePlayerReleaseTimer;
  late final LatestAsyncValueQueue<bool> _audioModeTransitions;
  late final LatestAsyncValueQueue<_AudioServiceRequest> _audioServiceTransitions;
  LiveRoom? _pendingRoomReentry;
  RoomSessionSnapshot? _appFloatingSession;

  PlaybackSource? _currentSource;
  bool _sourceOpened = false;
  String? get _currentUrl => _currentSource?.url;
  List<String> _currentPlayUrls = [];
  Map<String, String> _currentHeaders = {};

  final RxBool isInitialized = false.obs;
  final RxBool hasError = false.obs;
  final RxBool isVerticalVideo = false.obs;
  final Rx<VideoGeometrySnapshot> videoGeometry = const VideoGeometrySnapshot.unknown().obs;
  final RxBool isInPip = false.obs;
  final RxBool isPipPreparing = false.obs;
  final RxBool isFloating = false.obs;
  final RxBool isHovered = false.obs;
  final RxBool isFloatingVideoVisible = true.obs;

  /// 悬浮窗（app floating）长边尺寸，运行时记忆，不落盘。
  /// 范围 [floatingMinLongSide, floatingMaxLongSide]，默认 350（即原最小尺寸）。
  final RxDouble floatingLongSide = 350.0.obs;

  /// 悬浮窗上次拖拽结束后的位置（左上角坐标），运行时记忆，不落盘。
  /// null 表示使用默认位置（right: 50, top: 100）。
  final Rxn<Offset> floatingSavedPosition = Rxn<Offset>();

  /// 从卡片打开悬浮窗时的独立弹幕会话（不依赖 LivePlayController）。
  MultiviewDanmakuSession? _floatingDanmakuSession;

  /// 卡片悬浮窗专用弹幕控制器。该场景没有直播页路由，也就没有
  /// VideoController/DanmakuManager，弹幕经 [MultiviewDanmakuSession]
  /// 直接转发到这里，并由 StandaloneCompactDanmakuOverlay 渲染。
  final BarrageController _standaloneFloatingDanmaku = BarrageController();

  /// Ctrl+点击打开悬浮窗的请求代号。每次 [openAppFloatingFromRoom] 自增，
  /// 异步解析返回后核对，丢弃被新请求取代的过期结果（快速切换房间竞态）。
  int _appFloatingOpenEpoch = 0;

  /// 悬浮窗尺寸容器的 key：边缘拖拽开始时据此读取当前窗口位置/尺寸。
  final GlobalKey _appFloatingContainerKey = GlobalKey(debugLabel: 'app-floating-container');
  _FloatingResizeSession? _floatingResizeSession;

  static const double floatingMinLongSide = 350.0;
  static const double floatingMaxLongSide = 640.0;

  /// Compact-mode scoped mute (PiP + app floating). It only silences the
  /// current player session and is never persisted: leaving compact mode
  /// restores the room's saved volume, and the next compact session starts
  /// unmuted.
  final RxBool isCompactMuted = false.obs;

  /// App 悬浮窗弹幕的会话级显隐开关。仅由左上角按钮切换，不接入设置、
  /// 不落盘，生命周期与 [isCompactMuted] 一致：下次打开悬浮窗默认显示。
  /// 注意：只作用于应用内悬浮窗，不影响 Windows PiP。
  final RxBool isCompactDanmakuHidden = false.obs;

  /// Ephemeral compact-mode volume override changed via the mouse wheel or the
  /// compact volume bar. It is independent of the room's saved volume and is
  /// dropped when compact mode ends. `null` means the saved room volume is
  /// currently in effect.
  double? _compactVolumeOverride;
  final RxDouble compactVolumePreview = 1.0.obs;

  /// Live topmost state of the Windows PiP window. Seeded from the
  /// `windowsPipAlwaysOnTop` setting on entry, toggled from the PiP overlay;
  /// not persisted across PiP sessions.
  final RxBool isPipAlwaysOnTop = false.obs;

  /// True only while a deep power-saving audio session is reacquiring video.
  /// The audio presentation remains interactive during this interval, avoiding
  /// a black texture or full-page loading state while the next keyframe arrives.
  final RxBool isVideoRestorePending = false.obs;
  final RxInt videoFitIndex = 0.obs;
  Rx<ValueKey> videoKey = Rx<ValueKey>(const ValueKey("video_0"));
  final RxInt videoPresentationRevision = 0.obs;

  final _stateSubject = BehaviorSubject<PlayerState>.seeded(PlayerState.idle);
  final _playingSubject = BehaviorSubject<bool>.seeded(false);
  final _loadingSubject = BehaviorSubject<bool>.seeded(false);
  final _completeSubject = BehaviorSubject<bool>.seeded(false);
  final _errorSubject = PublishSubject<PlayerException>();
  final _widthSubject = BehaviorSubject<int?>.seeded(null);
  final _heightSubject = BehaviorSubject<int?>.seeded(null);
  final PortraitStreamDetector _portraitDetector = PortraitStreamDetector();

  final List<StreamSubscription> _subscriptions = [];
  StreamSubscription<PiPStatus>? _pipSubscription;
  StreamSubscription<bool>? _pipStateSubscription;

  bool _disposed = false;
  bool _isSwitchingDueToFallback = false;
  bool _isHandlingError = false;
  _PendingPlayerError? _pendingPlayerError;
  int? _errorDedupeSession;
  final Set<String> _errorDedupeSignatures = <String>{};
  static const String _floatTag = "global_video_player";
  Timer? _hideTimer;
  Timer? _sourceReadyTimer;
  Timer? _geometryObservationTimer;
  Timer? _geometryStabilityTimer;
  Timer? _contentProbeTimer;
  int _geometrySessionGeneration = 0;
  int? _freshDecoderGeometryGeneration;
  int _contentProbeAttempts = 0;
  int? _contentProbeInFlightGeneration;
  static const List<Duration> _contentProbeDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(milliseconds: 900),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 2500),
    Duration(milliseconds: 4000),
    Duration(milliseconds: 6500),
  ];
  late Floating floating;
  LiveRoom? currentFloatRoom;
  VideoController? _videoController;
  final List<Future<void> Function()> _floatingResourceDisposers = <Future<void> Function()>[];
  Future<void>? _floatingCleanup;
  StreamSubscription<int>? _floatingPopupSubscription;
  bool _appFloatingPrepared = false;
  bool _pipTransitionInFlight = false;
  int _pipTransitionRevision = 0;
  Completer<void>? _pipTransitionCancellation;
  int _pipObservationGeneration = 0;
  int _pipStatusRevision = 0;
  int _pipGeometryUpdateGeneration = 0;
  double? _lastAppliedPipAspectRatio;
  final GlobalKey _pipSourceKey = GlobalKey(debugLabel: 'pip-video-source');

  UnifiedPlayer? get currentPlayer => _currentPlayer;

  /// 捕获当前解码帧的原始直播画面（不含任何 UI 控件）。
  ///
  /// 仅 media_kit 引擎支持；其他引擎、播放器未初始化或截图失败时返回 null。
  /// mpv 的原生截图走解码器输出，不会经过 RepaintBoundary，因此不受
  /// 视频纹理合成方式的限制，Windows 下可稳定得到 png 原始帧。
  Future<Uint8List?> captureScreenshot() async {
    final player = _currentPlayer;
    if (player is! MediaKitPlayerAccessor) return null;
    try {
      return await (player as MediaKitPlayerAccessor).mediaKitPlayer.safeScreenshot(
        format: 'image/png',
        includeLibassSubtitles: false,
      );
    } catch (error, stackTrace) {
      log('Screenshot capture failed: $error', name: 'PlayerManager.Screenshot', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  PlayerEngine get currentEngine => _runtimeEngine ?? _defaultEngine ?? PlayerEngine.mediaKit;
  Stream<PlayerState> get onStateChanged => _stateSubject.stream;
  Stream<bool> get onPlaying => _playingSubject.stream;
  Stream<bool> get onLoading => _loadingSubject.stream;
  Stream<bool> get onComplete => _completeSubject.stream;
  Stream<PlayerException> get onError => _errorSubject.stream;
  Stream<int?> get width => _widthSubject.stream;
  Stream<int?> get height => _heightSubject.stream;
  bool get isPlayingNow => _playingSubject.value;
  bool get isAudioOnlyMode => _runtimeAudioOnly;
  bool get desiredAudioOnlyMode => _requestedAudioOnly;

  /// A lifecycle pause is an implementation detail, not a user playback
  /// intent. The token lets a later resume prove that neither the source nor
  /// the user's intent changed while the application was hidden.
  Future<PlaybackLifecyclePauseToken?> pauseForLifecycle() async {
    return _pauseForSuspension(_PlaybackSuspensionReason.lifecycle);
  }

  Future<bool> resumeFromLifecycle(PlaybackLifecyclePauseToken token) async {
    return _resumeFromSuspension(_PlaybackSuspensionReason.lifecycle, token);
  }

  Future<PlaybackLifecyclePauseToken?> pauseForAudioInterruption() async {
    return _pauseForSuspension(_PlaybackSuspensionReason.audioInterruption);
  }

  Future<bool> resumeFromAudioInterruption(PlaybackLifecyclePauseToken token) async {
    return _resumeFromSuspension(_PlaybackSuspensionReason.audioInterruption, token);
  }

  Future<PlaybackLifecyclePauseToken?> _pauseForSuspension(_PlaybackSuspensionReason reason) async {
    final player = _currentPlayer;
    if (player == null || _disposed || _isClosing) return null;
    if (!_playbackRequested) {
      if (_playbackIntentEstablished || (!isPlayingNow && !player.isPlayingNow)) return null;
      // Compatibility for an already-active adapter supplied by an explicit
      // pre-warm/restore path. Once any public command establishes intent,
      // native state alone never overrides that user decision.
      _playbackRequested = true;
    }
    final token = (sessionId: _sessionId, intentRevision: _playbackIntentRevision);
    _playbackSuspensions.add(reason);
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    if (isPlayingNow || player.isPlayingNow) await player.pause();
    if (_disposed || _isClosing || _sessionId != token.sessionId) {
      _playbackSuspensions.remove(reason);
      return null;
    }
    return token;
  }

  Future<bool> _resumeFromSuspension(_PlaybackSuspensionReason reason, PlaybackLifecyclePauseToken token) async {
    final player = _currentPlayer;
    if (player == null ||
        _disposed ||
        _isClosing ||
        _sessionId != token.sessionId ||
        _playbackIntentRevision != token.intentRevision ||
        !_playbackRequested ||
        !_playbackSuspensions.remove(reason)) {
      return false;
    }
    if (_playbackSuspensions.isNotEmpty || isPlayingNow || player.isPlayingNow) return true;
    await player.play();
    _armVideoFrameStallRecovery(player, token.sessionId);
    _scheduleRecoveryBudgetReset(player, token.sessionId);
    _scheduleProactiveSourceRefresh(player, token.sessionId);
    return !_disposed && !_isClosing && _sessionId == token.sessionId;
  }

  /// Selects the first engine without allocating a native player yet.
  /// Browsing the home/settings pages does not need a decoder, demuxer,
  /// texture or their worker threads; [play] performs the one-time warm-up on
  /// the first real room request.
  void configureDefaultEngine(PlayerEngine engine) {
    if (_disposed || _currentPlayer != null) return;
    _defaultEngine = engine;
  }

  /// Whether the room already owns a live native source that can accept an
  /// in-place audio/video track change.
  ///
  /// A live stream can paint and report `playing` before `Player.open`'s Future
  /// settles. Waiting for the whole route initialization in that state made the
  /// first headphone tap wait forever even though the current source was ready
  /// to accept commands.
  bool hasActivePlaybackSession(LiveRoom room) {
    return !_disposed &&
        !_isClosing &&
        _currentPlayer != null &&
        _currentSource != null &&
        currentFloatRoom == room &&
        isPlayingNow;
  }

  void prepareRoomSessionReentry(LiveRoom room) {
    _pendingRoomReentry = isAppFloatingActive && currentFloatRoom == room ? room : null;
  }

  RoomSessionSnapshot? consumeRoomSessionReentry(LiveRoom room) {
    final resumes =
        _pendingRoomReentry == room && _currentPlayer != null && currentFloatRoom == room && !_isClosing && !_disposed;
    _pendingRoomReentry = null;
    if (!resumes) {
      _appFloatingSession = null;
      return null;
    }

    final cached = _appFloatingSession;
    _appFloatingSession = null;
    final committed = _currentSourceCommit;
    if (cached != null && cached.room == room) {
      return committed != null && isSourceCommitCurrent(committed) && committed.room == room
          ? _mergeRoomSessionWithCommit(cached, committed)
          : cached;
    }

    // Compatibility fallback for a floating session created before the route
    // supplied its complete presentation state. It is still preferable to
    // reopening the same native live source during route construction.
    final urls = List<String>.unmodifiable(_currentPlayUrls);
    final currentUrl = _currentUrl ?? (urls.isEmpty ? '' : urls.first);
    final fallback = RoomSessionSnapshot(
      room: currentFloatRoom!,
      qualities: <LivePlayQuality>[LivePlayQuality(quality: '原画')],
      currentQuality: 0,
      playUrls: urls.isEmpty && currentUrl.isNotEmpty ? <String>[currentUrl] : urls,
      ownedSource: _currentSource is OwnedPlaybackSource ? _currentSource as OwnedPlaybackSource : null,
      sourceQueryPolicies: _sourceSelectionForCurrentCohort()?.sourceQueryPolicies ?? const {},
      currentLineIndex: urls.isEmpty ? 0 : urls.indexOf(currentUrl).clamp(0, urls.length - 1),
      headers: Map<String, String>.unmodifiable(_currentHeaders),
      isAudioOnly: _requestedAudioOnly,
      isLiving: true,
      dataSource: currentUrl,
    );
    return committed != null && isSourceCommitCurrent(committed) && committed.room == room
        ? _mergeRoomSessionWithCommit(fallback, committed)
        : fallback;
  }

  void cancelRoomSessionReentry() {
    _pendingRoomReentry = null;
    _appFloatingSession = null;
  }

  bool get shouldKeepDanmakuForAppFloating => _appFloatingPrepared || isFloating.value;
  bool get isAppFloatingActive =>
      _appFloatingPrepared || isFloating.value || _floatingCleanup != null || _floatingResourceDisposers.isNotEmpty;
  bool get isCompactModeActive => isInPip.value || isPipPreparing.value || isFloating.value || _appFloatingPrepared;

  bool ownsVideoController(VideoController controller) => identical(_videoController, controller);

  void attachVideoController(VideoController controller) {
    _videoController = controller;
  }

  void detachVideoController(VideoController controller) {
    if (identical(_videoController, controller)) {
      _videoController = null;
    }
  }

  PlaybackSourceQualitySelection? _sourceSelectionForCurrentCohort() {
    if (_sourceCohortRoom == currentFloatRoom && _sourceCohortSource == _currentSource) {
      return _sourceCohortSelection;
    }
    final committed = _currentSourceCommit;
    if (committed != null && committed.room == currentFloatRoom) return committed.selection;
    return null;
  }

  void _setSourceCohort({
    required LiveRoom? room,
    required PlaybackSource source,
    required PlaybackSourceQualitySelection? selection,
  }) {
    _sourceCohortRoom = room;
    _sourceCohortSource = source;
    _sourceCohortSelection = selection;
  }

  void _clearSourceCommitState({bool clearSourceCohort = true}) {
    _currentSourceCommit = null;
    if (clearSourceCohort) {
      _sourceCohortSelection = null;
      _sourceCohortRoom = null;
      _sourceCohortSource = null;
    }
  }

  void _rebindSourceCommitToSession(int sessionId) {
    final committed = _currentSourceCommit;
    if (committed == null || committed.room != currentFloatRoom || committed.source != _currentSource) return;
    _currentSourceCommit = PlaybackSourceCommitSnapshot(
      revision: committed.revision,
      sessionId: sessionId,
      intentRevision: _playbackIntentRevision,
      room: committed.room,
      urls: committed.urls,
      source: committed.source,
      currentLineIndex: committed.currentLineIndex,
      headers: committed.headers,
      audioOnly: committed.audioOnly,
      selection: committed.selection,
    );
  }

  bool _publishSourceCommit({
    required int sessionId,
    required int intentRevision,
    required LiveRoom? room,
    required PlaybackSource source,
    required List<String> urls,
    required Map<String, String> headers,
    required bool audioOnly,
    required PlaybackSourceQualitySelection? selection,
  }) {
    if (room == null ||
        !_isSessionValid(sessionId) ||
        intentRevision != _playbackIntentRevision ||
        !_playbackRequested ||
        _playbackSuspensions.isNotEmpty ||
        _currentPlayer == null ||
        currentFloatRoom != room ||
        _currentSource != source) {
      return false;
    }

    final currentUrl = source.url ?? '';
    final immutableUrls = List<String>.unmodifiable(
      urls.isEmpty && currentUrl.isNotEmpty ? <String>[currentUrl] : urls,
    );
    final index = immutableUrls.isEmpty ? 0 : immutableUrls.indexOf(currentUrl).clamp(0, immutableUrls.length - 1);
    final snapshot = PlaybackSourceCommitSnapshot(
      revision: ++_sourceCommitRevision,
      sessionId: sessionId,
      intentRevision: intentRevision,
      room: room,
      urls: immutableUrls,
      source: source,
      currentLineIndex: index,
      headers: headers,
      audioOnly: audioOnly,
      selection: selection,
    );
    _currentSourceCommit = snapshot;
    _setSourceCohort(room: room, source: source, selection: selection);
    final floatingSession = _appFloatingSession;
    if (floatingSession != null && floatingSession.room == room) {
      _appFloatingSession = _mergeRoomSessionWithCommit(floatingSession, snapshot);
    }
    if (!_sourceCommitController.isClosed) _sourceCommitController.add(snapshot);
    return true;
  }

  RoomSessionSnapshot _mergeRoomSessionWithCommit(RoomSessionSnapshot session, PlaybackSourceCommitSnapshot commit) {
    if (session.room != commit.room) return session;
    final selection = commit.selection;
    return session.copyWith(
      qualities: selection?.qualities,
      currentQuality: selection?.currentQuality,
      playUrls: commit.urls,
      ownedSource: commit.source is OwnedPlaybackSource ? commit.source as OwnedPlaybackSource : null,
      sourceQueryPolicies: selection?.sourceQueryPolicies ?? const {},
      currentLineIndex: commit.currentLineIndex,
      headers: commit.headers,
      // Audio-only is an in-place player mode and can change without a source
      // transaction. The commit snapshot's value is historical; the manager's
      // desired mode is authoritative at hand-off time.
      isAudioOnly: _requestedAudioOnly,
      dataSource: commit.currentUrl,
    );
  }

  void prepareAppFloating({required Future<void> Function() onClose, RoomSessionSnapshot? session}) {
    // Keep every pending owner until the overlay and popped route have fully
    // unmounted. Releasing a previous owner here recreated the same late-Obx
    // unsubscribe race when navigation happened unusually quickly.
    _floatingResourceDisposers.add(onClose);
    if (session != null && session.room == currentFloatRoom && _currentPlayer != null) {
      final currentUrl = _currentSource == null ? session.dataSource : (_currentSource!.url ?? '');
      final urls = _currentSource == null ? session.playUrls : _currentPlayUrls;
      final transportSnapshot = session.copyWith(
        dataSource: currentUrl,
        playUrls: List<String>.unmodifiable(urls),
        ownedSource: _currentSource is OwnedPlaybackSource ? _currentSource as OwnedPlaybackSource : null,
        sourceQueryPolicies: _sourceSelectionForCurrentCohort()?.sourceQueryPolicies ?? const {},
        headers: Map<String, String>.unmodifiable(_currentSource == null ? session.headers : _currentHeaders),
        isAudioOnly: _requestedAudioOnly,
      );
      final committed = _currentSourceCommit;
      _appFloatingSession = committed != null && isSourceCommitCurrent(committed) && committed.room == session.room
          ? _mergeRoomSessionWithCommit(transportSnapshot, committed)
          : transportSnapshot;
    } else {
      _appFloatingSession = null;
    }
    _appFloatingPrepared = true;
  }

  /// 从房间卡片直接打开悬浮窗播放（关注/热门/分区页 Ctrl+点击入口）。
  ///
  /// - 若悬浮窗正在播放同一房间：原地刷新流，不重建悬浮窗、不改变位置/尺寸。
  /// - 若已有悬浮窗在播其他房间：关闭旧的再开新的。
  /// - 复用 [showAppFloating] 同一套悬浮窗 UI。
  ///
  /// 注意：退出直播间（未转悬浮窗）后 [currentFloatRoom] 仍指向该房间，但
  /// overlay 已经销毁。此时 Ctrl+点击同一房间不能走"原地刷新"分支（只 play
  /// 不显示窗口），必须重新走完整的 prepare + show 流程。
  Future<void> openAppFloatingFromRoom(LiveRoom room) async {
    if (!Platform.isWindows) return;
    final platform = room.platform;
    final roomId = room.roomId;
    if (platform == null || roomId == null) return;

    final requestId = ++_appFloatingOpenEpoch;
    bool isStale() => requestId != _appFloatingOpenEpoch || _disposed;
    bool isOverlayActive() => isFloating.value || _appFloatingPrepared;

    // 同房间且悬浮窗确实还在显示：原地刷新流，不重建 floating overlay。
    final current = currentFloatRoom;
    if (current != null && current.platform == platform && current.roomId == roomId && isOverlayActive()) {
      await _reloadFloatingRoom(room, requestId);
      return;
    }

    // 关闭已有悬浮窗（若在播其他房间）。必须 await，避免新旧播放器重叠。
    if (isOverlayActive()) {
      await closeAppFloating();
    }
    if (isStale()) return;

    final site = Sites.of(platform);
    final liveSite = site.liveSite;
    try {
      // 先准备并显示悬浮窗（黑色占位），让用户立即看到反馈，
      // 视频流在后台异步解析完成后自动渲染。
      prepareAppFloating(onClose: () async {}, session: null);
      showAppFloating();

      final detail = await liveSite.getRoomDetail(roomId: roomId, platform: platform);
      if (isStale()) return;
      if (!detail.isPlayableNow) {
        await closeAppFloating();
        return;
      }
      final qualities = await liveSite.discoverPlayQualities(detail: detail);
      if (isStale()) return;
      if (qualities.isEmpty) {
        await closeAppFloating();
        return;
      }
      // 悬浮窗尺寸小，取最低清晰度省流量。
      final quality = qualities.last;
      final resolution = await liveSite.resolvePlayUrls(detail: detail, quality: quality);
      if (isStale()) return;
      final urls = resolution.urls;
      if (urls.isEmpty) {
        await closeAppFloating();
        return;
      }
      final headers = await PlaybackHeaderResolver.resolve(
        platform: platform,
        roomId: roomId,
        roomHeaders: detail.httpHeaders,
      );
      if (isStale() || !isOverlayActive()) return;
      await play(urls.first, urls, headers, room: detail);
      if (isStale() || !isOverlayActive()) return;
      // 传入完整 qualities 列表，hasUseDefaultResolution=false：
      // 进入直播间后会重新选择用户偏好的清晰度，避免悬浮窗的低清被沿用。
      final selectedIndex = qualities.indexOf(quality).clamp(0, qualities.length - 1);
      prepareAppFloating(
        onClose: () async {},
        session: RoomSessionSnapshot(
          room: detail,
          qualities: List<LivePlayQuality>.unmodifiable(qualities),
          currentQuality: selectedIndex,
          playUrls: List<String>.unmodifiable(urls),
          currentLineIndex: 0,
          headers: Map<String, String>.unmodifiable(headers),
          isAudioOnly: false,
          isLiving: true,
          dataSource: urls.first,
          hasUseDefaultResolution: false,
        ),
      );
      // 卡片悬浮窗没有 VideoController：弹幕走独立会话 + 独立弹幕层。
      // 若用户开启了悬浮窗弹幕且平台支持，建立独立弹幕会话。
      if (isOverlayActive() &&
          _videoController == null &&
          SettingsService.to.danmaku.enablePipDanmaku.v &&
          MultiviewDanmakuSession.supportsRoom(detail)) {
        await _connectFloatingDanmaku(detail);
      }
    } catch (error, stackTrace) {
      if (isStale()) return;
      log('openAppFloatingFromRoom failed', name: 'PlayerManager', error: error, stackTrace: stackTrace);
      await closeAppFloating();
    }
  }

  /// 为从卡片打开的悬浮窗建立独立弹幕会话。
  ///
  /// 存在路由级 [VideoController] 时（退出直播间转悬浮窗的场景）转发给它的
  /// DanmakuManager；否则直接转成 [BarrageItem] 发往独立弹幕控制器——
  /// DanmakuManager 会丢弃非播放态消息，且卡片悬浮窗根本没有 VideoController。
  Future<void> _connectFloatingDanmaku(LiveRoom room) async {
    final session = _floatingDanmakuSession ??= MultiviewDanmakuSession(
      engineFactory: (r) => Sites.of(r.platform!).liveSite.getDanmaku(),
      onChatMessage: _dispatchFloatingDanmaku,
    );
    await session.connect(room);
  }

  void _dispatchFloatingDanmaku(LiveMessage msg) {
    final controller = _videoController;
    if (controller != null) {
      controller.sendDanmaku(msg);
      return;
    }
    if (!isPlayingNow && !msg.isLocal) return;
    final danmakuSettings = SettingsService.to.danmaku;
    final Color color;
    if (msg.isLocal || danmakuSettings.pipDanmakuUseOriginalColor.v) {
      color = Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b);
    } else {
      color = Color(danmakuSettings.pipDanmakuColor.v);
    }
    final content = msg.repeatCount >= 2 ? '${msg.message} ×${msg.repeatCount}' : msg.message;
    // 与 VideoController 的 PiP 弹幕转发保持一致：本地发送的弹幕保留
    // 置顶/置底与自定义样式。
    final localStyle = msg.isLocal ? msg.style : null;
    _standaloneFloatingDanmaku.send(
      BarrageItem(
        content: content,
        type: switch (localStyle?.placement) {
          LiveMessagePlacement.top => BarrageType.topFixed,
          LiveMessagePlacement.bottom => BarrageType.bottomFixed,
          _ => BarrageType.scroll,
        },
        userId: msg.userId,
        userName: msg.userName,
        textColor: color,
        fontSize: localStyle?.fontSize,
        fontWeight: localStyle == null ? null : FontWeight(localStyle.fontWeight),
        fontStyle: localStyle?.italic == true ? FontStyle.italic : null,
        fontFamily: localStyle?.fontFamily,
        letterSpacing: localStyle?.letterSpacing,
        opacity: localStyle?.opacity,
        showStroke: localStyle?.showStroke,
        strokeColor: localStyle == null ? null : Color(localStyle.strokeColor),
        strokeWidth: localStyle?.strokeWidth,
        showShadow: localStyle?.showShadow,
        shadowColor: localStyle == null ? null : Color(localStyle.shadowColor),
        shadowBlur: localStyle?.shadowBlur,
        shadowOffset: localStyle == null ? null : Offset(localStyle.shadowOffset, localStyle.shadowOffset),
        fixedDuration: localStyle == null ? null : Duration(milliseconds: localStyle.fixedDurationMs),
        baseSpeed: localStyle?.baseSpeed,
      ),
    );
  }

  /// 断开悬浮窗弹幕会话。
  Future<void> _disconnectFloatingDanmaku() async {
    final session = _floatingDanmakuSession;
    if (session != null) {
      _floatingDanmakuSession = null;
      await session.disconnect();
    }
    // 清空独立弹幕层残留，避免下次打开悬浮窗时短暂出现上个房间的弹幕。
    _standaloneFloatingDanmaku.clear();
  }

  /// 原地刷新悬浮窗正在播放的房间流（不重建 overlay、不改位置/尺寸）。
  ///
  /// [requestId] 与 [openAppFloatingFromRoom] 的代号对应：解析期间若有更新的
  /// Ctrl+点击请求或悬浮窗已被关闭/进入直播间，则放弃本次结果。
  Future<void> _reloadFloatingRoom(LiveRoom room, int requestId) async {
    final platform = room.platform;
    final roomId = room.roomId;
    if (platform == null || roomId == null) return;
    bool isStale() => requestId != _appFloatingOpenEpoch || _disposed;
    bool isOverlayActive() => isFloating.value || _appFloatingPrepared;
    final site = Sites.of(platform);
    final liveSite = site.liveSite;
    try {
      final detail = await liveSite.getRoomDetail(roomId: roomId, platform: platform);
      if (isStale() || !isOverlayActive() || !detail.isPlayableNow) return;
      final qualities = await liveSite.discoverPlayQualities(detail: detail);
      if (isStale() || !isOverlayActive()) return;
      if (qualities.isEmpty) return;
      final quality = qualities.last;
      final resolution = await liveSite.resolvePlayUrls(detail: detail, quality: quality);
      if (isStale() || !isOverlayActive()) return;
      final urls = resolution.urls;
      if (urls.isEmpty) return;
      final headers = await PlaybackHeaderResolver.resolve(
        platform: platform,
        roomId: roomId,
        roomHeaders: detail.httpHeaders,
      );
      if (isStale() || !isOverlayActive()) return;
      await play(urls.first, urls, headers, room: detail);
      if (isStale() || !isOverlayActive()) return;
      // play() 打开的是全新原生播放器，默认按房间保存音量播放。必须把当前
      // compact 会话音量（含单击静音的 0）重新施加给新实例，否则会出现
      // “声音恢复了但音量图标仍显示静音”的状态错位。
      await _reapplyCompactVolumeAfterReload();
      // 同房间刷新：若弹幕会话已断开则重连（connect 幂等）。路由级
      // VideoController 存在时由其自身弹幕引擎负责，不建立独立会话。
      if (_videoController == null &&
          SettingsService.to.danmaku.enablePipDanmaku.v &&
          MultiviewDanmakuSession.supportsRoom(detail)) {
        await _connectFloatingDanmaku(detail);
      }
    } catch (error, stackTrace) {
      if (isStale()) return;
      log('_reloadFloatingRoom failed', name: 'PlayerManager', error: error, stackTrace: stackTrace);
    }
  }

  Widget _buildCompactDanmaku() {
    final controller = _videoController;
    if (controller != null) {
      return CompactDanmakuOverlay(controller: controller);
    }
    // 卡片直接打开的悬浮窗没有直播页路由/VideoController，使用独立弹幕层。
    return StandaloneCompactDanmakuOverlay(barrageController: _standaloneFloatingDanmaku);
  }

  Future<void> _releaseAppFloatingResources() async {
    _appFloatingPrepared = false;
    // 弹幕显隐是会话临时态：随悬浮窗资源释放一起复位，下次打开默认显示。
    isCompactDanmakuHidden.value = false;
    // 断开悬浮窗独立弹幕会话。
    await _disconnectFloatingDanmaku();
    final disposers = List<Future<void> Function()>.from(_floatingResourceDisposers);
    _floatingResourceDisposers.clear();
    for (final disposer in disposers) {
      await disposer();
    }
    if (!isInPip.value && !isFloating.value) {
      _videoController?.clearPipDanmaku();
    }
  }

  Future<void> _awaitBoundedWidgetUnmount() async {
    // Route and overlay teardown normally completes on the next frame. During
    // backgrounding, shutdown and headless tests there may be no vsync, so an
    // unbounded endOfFrame wait would retain controllers, subscriptions and a
    // native player indefinitely.
    final completer = Completer<void>();
    late final Timer fallbackTimer;
    fallbackTimer = Timer(const Duration(milliseconds: 50), () {
      if (!completer.isCompleted) completer.complete();
    });
    SchedulerBinding.instance.scheduleFrame();
    SchedulerBinding.instance.endOfFrame.whenComplete(() {
      fallbackTimer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    fallbackTimer.cancel();
  }

  double get currentVideoRatio {
    final settings = _portraitSettings;
    return PortraitPresentationPolicy.resolveCompactWindowAspectRatio(
      snapshot: videoGeometry.value,
      effectiveOrientation: effectiveVideoOrientation,
      followStablePortraitSource: settings?.portraitPipFollowSource.v ?? true,
    );
  }

  /// The single immutable geometry shared by the normal room, fullscreen,
  /// system PiP and the application floating window.
  VideoPresentationGeometry get currentPresentationGeometry => PortraitPresentationPolicy.resolvePresentationGeometry(
    snapshot: videoGeometry.value,
    effectiveOrientation: effectiveVideoOrientation,
  );

  double get currentPresentationAspectRatio => currentPresentationGeometry.contentAspectRatio;

  void _beginVideoGeometrySession(LiveRoom? nextRoom, {String? selectedUrl}) {
    _geometrySessionGeneration++;
    _geometryObservationTimer?.cancel();
    _geometryStabilityTimer?.cancel();
    _contentProbeTimer?.cancel();
    _geometryObservationTimer = null;
    _geometryStabilityTimer = null;
    _contentProbeTimer = null;
    _contentProbeAttempts = 0;
    _freshDecoderGeometryGeneration = null;
    if (_widthSubject.value != null) _widthSubject.add(null);
    if (_heightSubject.value != null) _heightSubject.add(null);
    // A room ID is not a media identity. A restarted room, a refreshed signed
    // URL, another quality or another CDN may expose a different encoded
    // canvas. Reusing a room cache made the old orientation control the normal
    // page, fullscreen and PiP before the current decoder spoke. Start every
    // source from unknown; metadata below stays provisional until this source's
    // decoder publishes a valid dimension pair.
    VideoGeometrySnapshot next = _portraitDetector.reset();

    final hint = LiveStreamGeometryHintResolver.resolve(nextRoom, selectedUrl: selectedUrl);
    if (hint != null) {
      next = _portraitDetector.observeSourceMetadata(
        hint.width,
        hint.height,
        confidence: hint.confidence,
        source: hint.source,
      );
      log(
        'Source geometry hint ${hint.width}x${hint.height} (${hint.source}, ${hint.confidence.toStringAsFixed(2)})',
        name: 'PlayerManager.VideoGeometry',
      );
    }
    _publishVideoGeometry(next, notifyController: false);
  }

  void _scheduleVideoGeometryObservation() {
    // Coalesce a burst without postponing its deadline. Some adapters repeat
    // dimensions while a Surface is resizing; a trailing-edge debounce can
    // then starve detection indefinitely. Source changes explicitly cancel
    // this timer and fence the observation with a new generation below.
    if (_geometryObservationTimer != null) return;
    final generation = _geometrySessionGeneration;
    _geometryObservationTimer = Timer(const Duration(milliseconds: 120), () {
      _geometryObservationTimer = null;
      final width = _widthSubject.value;
      final height = _heightSubject.value;
      if (generation != _geometrySessionGeneration ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0 ||
          _disposed ||
          _isClosing) {
        return;
      }
      final snapshot = _portraitDetector.observe(width, height);
      _freshDecoderGeometryGeneration = generation;
      _publishVideoGeometry(snapshot);
      _scheduleGeometryStabilityCommit();
      if (snapshot.isStable) _scheduleActiveContentProbe();
    });
  }

  void _scheduleGeometryStabilityCommit() {
    _geometryStabilityTimer?.cancel();
    _geometryStabilityTimer = null;
    final since = _portraitDetector.pendingSince;
    if (since == null) return;
    final elapsed = DateTime.now().difference(since);
    final remaining = _portraitDetector.stabilityDelay - elapsed;
    final generation = _geometrySessionGeneration;
    _geometryStabilityTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _geometryStabilityTimer = null;
      if (generation != _geometrySessionGeneration || _disposed || _isClosing) return;
      final snapshot = _portraitDetector.commitPending();
      _publishVideoGeometry(snapshot);
      if (snapshot.isStable) _scheduleActiveContentProbe();
    });
  }

  void _scheduleActiveContentProbe() {
    final snapshot = videoGeometry.value;
    final needsCanvasInspection = shouldInspectActiveVideoContent(snapshot);
    if (!enableActiveContentProbe ||
        !PlatformUtils.isMobile ||
        _disposed ||
        _isClosing ||
        _runtimeAudioOnly ||
        !isPlayingNow ||
        _contentProbeAttempts >= _contentProbeDelays.length ||
        _contentProbeInFlightGeneration == _geometrySessionGeneration ||
        _contentProbeTimer != null ||
        _freshDecoderGeometryGeneration != _geometrySessionGeneration ||
        !snapshot.isStable ||
        snapshot.isProvisional ||
        !needsCanvasInspection ||
        _portraitDetector.contentEvidenceSettled ||
        !(_portraitSettings?.enablePortraitStreamAdaptation.v ?? true) ||
        _currentPlayer is! MediaKitPlayerAccessor) {
      return;
    }
    final generation = _geometrySessionGeneration;
    final delay = _contentProbeDelays[_contentProbeAttempts];
    _contentProbeTimer = Timer(delay, () {
      _contentProbeTimer = null;
      if (generation != _geometrySessionGeneration || _disposed || _isClosing) return;
      unawaited(_runActiveContentProbe(generation));
    });
  }

  Future<void> _runActiveContentProbe(int generation) async {
    final player = _currentPlayer;
    if (player is! MediaKitPlayerAccessor ||
        _contentProbeInFlightGeneration == generation ||
        _contentProbeAttempts >= _contentProbeDelays.length) {
      return;
    }
    final accessor = player as MediaKitPlayerAccessor;
    _contentProbeInFlightGeneration = generation;
    _contentProbeAttempts++;
    try {
      final observation = await MediaKitContentProbe.capture(accessor);
      if (observation == null ||
          generation != _geometrySessionGeneration ||
          _disposed ||
          _isClosing ||
          !identical(player, _currentPlayer)) {
        return;
      }
      _publishVideoGeometry(_portraitDetector.observeActiveContent(observation));
    } catch (error, stackTrace) {
      log(
        'Active content probe skipped: $error',
        name: 'PlayerManager.VideoGeometry',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (_contentProbeInFlightGeneration == generation) {
        _contentProbeInFlightGeneration = null;
      }
      if (generation == _geometrySessionGeneration &&
          _contentProbeAttempts < _contentProbeDelays.length &&
          !_portraitDetector.contentEvidenceSettled) {
        _scheduleActiveContentProbe();
      }
    }
  }

  VideoSourceOrientation get effectiveVideoOrientation {
    final settings = _portraitSettings;
    return PortraitPresentationPolicy.resolveOrientation(
      snapshot: videoGeometry.value,
      override: settings?.portraitOverrideForRoom(currentFloatRoom) ?? PortraitOrientationOverride.automatic,
      smartDetectionEnabled: settings?.enablePortraitStreamAdaptation.v ?? true,
    );
  }

  PlayerSettingsController? get _portraitSettings {
    try {
      return SettingsService.to.player;
    } catch (_) {
      return null;
    }
  }

  void refreshPortraitPresentationPolicy({bool notifyController = true}) {
    _publishVideoGeometry(videoGeometry.value, notifyController: false);
    if (notifyController) {
      final controller = _videoController;
      if (controller != null) unawaited(controller.applyFullscreenOrientationPolicy());
    }
  }

  void _publishVideoGeometry(VideoGeometrySnapshot snapshot, {bool notifyController = true}) {
    final previous = videoGeometry.value;
    final previousOrientation = effectiveVideoOrientation;
    final previousRatio = PortraitPresentationPolicy.resolveVideoDisplayAspectRatio(
      snapshot: previous,
      effectiveOrientation: previousOrientation,
    );
    videoGeometry.value = snapshot;
    final wasVertical = isVerticalVideo.value;
    final nextVertical = effectiveVideoOrientation == VideoSourceOrientation.portrait;
    final nextRatio = currentPresentationAspectRatio;
    final presentationChanged = wasVertical != nextVertical || (previousRatio - nextRatio).abs() > 0.004;
    final evidenceChanged = previous.evidence != snapshot.evidence;
    final encodedRatioChanged = (previous.aspectRatio - snapshot.aspectRatio).abs() > 0.01;
    if (presentationChanged || evidenceChanged || encodedRatioChanged) {
      log(
        'Geometry encoded=${snapshot.aspectRatio.toStringAsFixed(4)} '
        'effective=${snapshot.effectiveAspectRatio.toStringAsFixed(4)} '
        'presented=${nextRatio.toStringAsFixed(4)} '
        'orientation=${snapshot.orientation.name} evidence=${snapshot.evidence.name} '
        'hint=${snapshot.sourceHintSource.isEmpty ? '-' : snapshot.sourceHintSource}',
        name: 'PlayerManager.VideoGeometry',
      );
    }
    if (presentationChanged) {
      isVerticalVideo.value = nextVertical;
      videoPresentationRevision.value++;
      if (notifyController) {
        final controller = _videoController;
        if (controller != null) unawaited(controller.applyFullscreenOrientationPolicy());
      }
      if (isInPip.value) {
        unawaited(_updateActiveAndroidPip());
        unawaited(_updateActiveWindowsPipAspectRatio());
      }
    }
  }

  /// Windows PiP：视频比例变化时同步更新窗口宽高比锁定，保证拖拽边缘
  /// 缩放时始终贴合当前画面比例（横屏/竖屏切换均生效）。
  Future<void> _updateActiveWindowsPipAspectRatio() async {
    if (!_usesWindowsPip || !isInPip.value || _pipTransitionInFlight) return;
    await WindowHelper.instance.updatePiPAspectRatio(currentVideoRatio);
  }

  Future<void> _updateActiveAndroidPip() async {
    if (!_usesAndroidPip || !isInPip.value || _pipTransitionInFlight) return;
    final generation = ++_pipGeometryUpdateGeneration;
    // Mirror Android's layout-listener guidance: publish geometry only after
    // the compact video view has adopted the new presentation ratio.
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    if (generation != _pipGeometryUpdateGeneration || !isInPip.value || _disposed || _isClosing) return;
    final compactRatio = currentVideoRatio;
    final pipRatio = PortraitPresentationPolicy.resolveAndroidPipAspectRatio(
      width: (compactRatio * 10000).round(),
      height: 10000,
      portraitFallback: effectiveVideoOrientation == VideoSourceOrientation.portrait,
    );
    if (_lastAppliedPipAspectRatio != null && (_lastAppliedPipAspectRatio! - pipRatio.value).abs() < 0.004) return;
    try {
      await floating.update(
        aspectRatio: Rational(pipRatio.width, pipRatio.height),
        sourceRectHint: _currentPipSourceRect(contentAspectRatio: pipRatio.value),
      );
      if (generation != _pipGeometryUpdateGeneration || !isInPip.value || _disposed || _isClosing) return;
      _lastAppliedPipAspectRatio = pipRatio.value;
    } catch (error, stackTrace) {
      log(
        'Update active PiP geometry failed: $error',
        name: 'PlayerManager.VideoGeometry',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<UnifiedPlayer> _createPlayer(
    PlayerEngine engine, {
    bool audioOnly = false,
    bool suppressAudioOutput = false,
  }) async {
    final player = await _playerCreator(engine);
    try {
      if (player is AudioOutputSuppressionAwarePlayer) {
        (player as AudioOutputSuppressionAwarePlayer).setAudioOutputSuppressed(suppressAudioOutput);
        if (suppressAudioOutput) {
          log('Suppressing audio output for automatic fallback engine: ${engine.name}', name: 'PlayerManager');
        }
      }
      await player.init(audioOnly: audioOnly);
      return player;
    } catch (_) {
      // Native allocation may succeed before controller/surface setup fails.
      // Always release that partial player before trying another engine.
      await _safeDestroyPlayer(player);
      rethrow;
    }
  }

  Future<T> _enqueuePlayerLifecycle<T>(Future<T> Function() operation) {
    final previous = _playerLifecycleQueue;

    final current = previous.then((_) => operation());

    _playerLifecycleQueue = current.then<void>((_) {}, onError: (_, _) {});

    return current;
  }

  Future<void> initialize({PlayerEngine engine = PlayerEngine.mediaKit, bool audioOnly = false}) {
    return _enqueuePlayerLifecycle(
      () => _initializeInternal(engine: engine, audioOnly: audioOnly, sessionId: _sessionId, publishError: true),
    );
  }

  Future<void> _initializeInternal({
    required PlayerEngine engine,
    required bool audioOnly,
    required int sessionId,
    required bool publishError,
  }) async {
    if (_disposed || _isClosing) return;

    _stateSubject.add(PlayerState.initializing);

    try {
      _defaultEngine = engine;
      _runtimeEngine = engine;

      final player = await _createPlayer(engine, audioOnly: audioOnly);

      if (!_isSessionValid(sessionId)) {
        await _safeDestroyPlayer(player);
        return;
      }

      _currentPlayer = player;
      _runtimeAudioOnly = audioOnly;
      _requestedAudioOnly = audioOnly;
      _nativeAudioOnly = audioOnly;

      await _bindPlayerStreams(player, sessionId: sessionId);

      if (!_isSessionValid(sessionId)) {
        await _safeDestroyPlayer(player);

        if (identical(_currentPlayer, player)) {
          _currentPlayer = null;
        }

        return;
      }
      _startAndroidPipObservation();

      isInitialized.value = true;
      videoPresentationRevision.value++;
      _stateSubject.add(PlayerState.initialized);

      _scheduleAudioServiceSync(player, audioOnly, sessionId: sessionId);
    } catch (e, s) {
      if (!_isSessionValid(sessionId)) return;

      final exception = PlayerException(
        message: 'Initialize player failed',
        type: PlayerErrorType.initialization,
        error: e,
        stackTrace: s,
      );

      // Explicit pre-warm calls own their terminal error. A player allocated as
      // part of [play] is different: its initialization failure must remain
      // private until the orchestrator has tried the remaining engines.
      if (publishError) _publishTerminalPlayerError(exception);

      throw exception;
    }
  }

  Future<void> play(
    String url,
    List<String> playUrls,
    Map<String, String> headers, {
    LiveRoom? room,
    bool audioOnly = false,
    PlaybackSourceResolver? sourceResolver,
    DateTime? sourceRefreshAt,
    PlaybackSourceQualitySelection? sourceSelection,
  }) => playSource(
    UrlPlaybackSource(url),
    playUrls: playUrls,
    headers: headers,
    room: room,
    audioOnly: audioOnly,
    sourceResolver: sourceResolver,
    sourceRefreshAt: sourceRefreshAt,
    sourceSelection: sourceSelection,
  );

  Future<void> playSource(
    PlaybackSource source, {
    List<String> playUrls = const [],
    Map<String, String> headers = const {},
    LiveRoom? room,
    bool audioOnly = false,
    PlaybackSourceResolver? sourceResolver,
    DateTime? sourceRefreshAt,
    PlaybackSourceQualitySelection? sourceSelection,
  }) {
    if (source is UrlPlaybackSource && source.url.trim().isEmpty) {
      throw ArgumentError('Remote playback source is empty');
    }
    if (source is OwnedPlaybackSource &&
        (playUrls.isNotEmpty || headers.isNotEmpty || sourceSelection?.sourceQueryPolicies.isNotEmpty == true)) {
      throw ArgumentError('Owned source recipes do not accept remote URL capabilities');
    }
    final requestedUrls = List<String>.unmodifiable(playUrls);
    final requestedHeaders = Map<String, String>.unmodifiable(headers);
    _cancelIdlePlayerRelease();
    _playbackRequested = true;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _cancelPendingSourceInputs();
    final roomChanged = room != currentFloatRoom;
    if (roomChanged) {
      _currentSourceCommit = null;
      _pendingRoomReentry = null;
      _appFloatingSession = null;
    }
    _playbackSuspensions.clear();
    _sameEngineRecoveryAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _cancelTransientLiveRetry();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    final intentRevision = _playbackIntentRevision;
    return _enqueuePlayerLifecycle(() async {
      if (!_isPlaybackCommandCurrent(intentRevision)) return;
      final retainedCommit = _currentSourceCommit;
      final retainedResolver = _sourceRefreshResolver;
      var retainedAttempts = _sourceRefreshAttempts;
      var retainedPrefetch = _prefetchedSourceRefresh;
      var replacedRefreshOwner = false;
      void replaceRefreshOwner() {
        if (!replacedRefreshOwner) {
          retainedAttempts = _sourceRefreshAttempts;
          retainedPrefetch = _prefetchedSourceRefresh;
        }
        replacedRefreshOwner = true;
        _sourceRefreshResolver = sourceResolver;
        _sourceRefreshAttempts = 0;
        _prefetchedSourceRefresh = null;
        _sourceRefreshAttemptResetTimer?.cancel();
        _sourceRefreshAttemptResetTimer = null;
      }

      try {
        await _playResolvedSourceInternal(
          source,
          requestedUrls,
          requestedHeaders,
          room: room,
          audioOnly: audioOnly,
          allowWarmSwap: true,
          sourceRefreshAt: sourceRefreshAt,
          sourceSelection: sourceSelection,
          replaceSourceSelection: true,
          beforeSourceReplacement: replaceRefreshOwner,
        );
      } finally {
        final current = _currentSourceCommit;
        // Warm preparation keeps the old signer/cache/budget. If installation
        // later rolls back, restore those owners only for the retained source;
        // close, destructive open and a newer commit must never resurrect them.
        if (replacedRefreshOwner &&
            retainedCommit != null &&
            current != null &&
            current.revision == retainedCommit.revision &&
            current.currentUrl == retainedCommit.currentUrl &&
            current.room == retainedCommit.room &&
            isSourceCommitCurrent(current)) {
          _sourceRefreshResolver = retainedResolver;
          _sourceRefreshAttempts = retainedAttempts;
          _prefetchedSourceRefresh = retainedPrefetch;
          if (_playbackRequested && _playbackSuspensions.isEmpty && _currentPlayer != null) {
            _scheduleSourceRefreshAttemptReset(_currentPlayer!, _sessionId);
            _scheduleProactiveSourceRefresh(_currentPlayer!, _sessionId);
          }
        }
      }
    });
  }

  Future<void> _playResolvedSourceInternal(
    PlaybackSource source,
    List<String> playUrls,
    Map<String, String> headers, {
    required LiveRoom? room,
    required bool audioOnly,
    required bool allowWarmSwap,
    required DateTime? sourceRefreshAt,
    PlaybackSourceQualitySelection? sourceSelection,
    bool replaceSourceSelection = false,
    bool forceTransportRestart = false,
    bool Function()? isStillRequired,
    void Function()? beforeSourceReplacement,
  }) async {
    final url = source.url;
    if (isStillRequired?.call() == false) return;
    final canWarmSwap =
        allowWarmSwap &&
        PlatformUtils.isWindows &&
        _currentPlayer != null &&
        _runtimeEngine != null &&
        currentFloatRoom == room &&
        _currentSource != null &&
        (forceTransportRestart || source != _currentSource);
    if (canWarmSwap &&
        await _tryWarmSwapSource(
          source,
          playUrls,
          headers,
          room: room,
          audioOnly: audioOnly,
          sourceRefreshAt: sourceRefreshAt,
          sourceSelection: sourceSelection,
          replaceSourceSelection: replaceSourceSelection,
          isStillRequired: isStillRequired,
          beforeSourceReplacement: beforeSourceReplacement,
        )) {
      return;
    }
    if (isStillRequired?.call() == false) return;
    beforeSourceReplacement?.call();
    _proactiveSourceRefreshTimer?.cancel();
    _proactiveSourceRefreshTimer = null;
    _currentSourceRefreshAt = _effectiveSourceRefreshAt(sourceRefreshAt, url: url);
    await _playInternal(
      source,
      playUrls,
      headers,
      room: room,
      audioOnly: audioOnly,
      sourceSelection: sourceSelection,
      replaceSourceSelection: replaceSourceSelection,
    );
  }

  Future<void> _playInternal(
    PlaybackSource source,
    List<String> playUrls,
    Map<String, String> headers, {
    LiveRoom? room,
    bool audioOnly = false,
    PlaybackSourceQualitySelection? sourceSelection,
    bool replaceSourceSelection = false,
  }) async {
    final url = source.url;
    if (_disposed) return;
    _cancelIdlePlayerRelease();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    _audioModeVideoWarmTimer?.cancel();
    _audioModeVideoWarmTimer = null;
    isVideoRestorePending.value = false;
    if (_disposed || _isClosing) return;
    final mySessionId = ++_sessionId;
    final sourceIntentRevision = _playbackIntentRevision;
    _sourceOpened = false;
    final committedSelection = replaceSourceSelection ? sourceSelection : _sourceSelectionForCurrentCohort();
    // A warm candidate leaves the previous source intact until commit. Only
    // destructive opening reaches this point; a cancelled warm candidate must
    // not erase the still-active source snapshot (including its policy).
    _currentSourceCommit = null;

    final roomChanged = room != currentFloatRoom;
    if (roomChanged) {
      lineManager.reset();
      fallbackManager.resetAll();
      _sameEngineRecoveryAttempts = 0;
      _sourceRefreshAttempts = 0;
      _transientLiveRetryAttempts = 0;
      _cancelTransientLiveRetry();
    }
    // Start a geometry generation for every new source, including quality and
    // CDN switches in the same room. Every source starts with fresh evidence;
    // room identity alone must not carry a stale crop or orientation forward.
    _beginVideoGeometrySession(room, selectedUrl: url);

    // Recovery needs the complete request even when the preferred native
    // engine fails before a player exists. Previously these fields were set
    // only after initialization, so an initialization exception escaped the
    // line/engine recovery state machine and immediately surfaced as a decoder
    // error.
    _currentSource = source;
    _currentPlayUrls = List<String>.from(playUrls);
    _currentHeaders = Map<String, String>.from(headers);
    currentFloatRoom = room;
    _setSourceCohort(room: room, source: source, selection: committedSelection);
    refreshPortraitPresentationPolicy(notifyController: false);
    hasError.value = false;

    if (_currentPlayer == null || _runtimeEngine == null) {
      if (_defaultEngine == null) {
        final String savedKey = SettingsService.to.player.videoPlayerKey.v;
        final String validKey = normalizeVideoPlayerKeyForPlatform(savedKey, defaultTargetPlatform);

        _defaultEngine = PlayerConsts.engines[validKey]!;
      }

      final engine = _defaultEngine!;

      log('No current player, initializing with default engine: $engine', name: 'PlayerManager');

      try {
        await _initializeInternal(engine: engine, audioOnly: audioOnly, sessionId: mySessionId, publishError: false);
      } on PlayerException catch (error) {
        if (_isSessionValid(mySessionId) && _isPlaybackCommandCurrent(sourceIntentRevision)) {
          await _handleError(error, sessionId: mySessionId);
        }
        return;
      }
    } else if (_runtimeEngine != _defaultEngine && !_isSwitchingDueToFallback) {
      await _switchEngineInternal(_defaultEngine!, isManual: false, audioOnly: audioOnly, openCurrentSource: false);
    } else if (_runtimeAudioOnly != audioOnly || _requestedAudioOnly != audioOnly) {
      await setAudioOnlyMode(audioOnly);
    }

    if (!_isSessionValid(mySessionId) || !_isPlaybackCommandCurrent(sourceIntentRevision)) return;

    final player = _currentPlayer;

    if (player == null) {
      if (!_isSessionValid(mySessionId)) {
        return;
      }

      throw PlayerException(message: 'Current player is null', type: PlayerErrorType.lifecycle);
    }

    _startAndroidPipObservation();

    // Every bundled player has a native audio-only path.  Opening the original
    // live URL directly avoids a second FFmpeg decode pipeline and removes the
    // previous fixed two-second wait / 30-second pipe timeout.
    final targetSource = source;
    final List<String> targetPlayUrls = List.from(playUrls);

    // Reset retained-adapter subjects before rebinding this source generation.
    // Without this handshake BehaviorSubjects replayed the previous URL's
    // dimensions and delayed errors into the new room/quality session.
    if (player is SourceTransitionAwarePlayer) {
      (player as SourceTransitionAwarePlayer).beginSourceTransition();
    }
    await _bindPlayerStreams(player, sessionId: mySessionId);
    if (!_isSessionValid(mySessionId) || !_isPlaybackCommandCurrent(sourceIntentRevision)) return;

    _currentSource = targetSource;
    _currentPlayUrls = targetPlayUrls;

    try {
      _stateSubject.add(PlayerState.preparing);
      await _openPlayerSource(
        player,
        targetSource,
        targetPlayUrls,
        headers,
        room: room,
        audioOnly: audioOnly,
        sourceQueryPolicy: committedSelection?.sourceQueryPolicies[url],
      );
      if (!_isSessionValid(mySessionId) || !_isPlaybackCommandCurrent(sourceIntentRevision)) return;
      _sourceOpened = true;
      _nativeAudioOnly = audioOnly;
      _armSourceReadyDeadline(player, mySessionId);

      // Desktop player adapters do not all restore the per-room volume in
      // setDataSource. Apply it centrally so every engine starts consistently.
      if (PlatformUtils.isDesktop && room != null) {
        try {
          await player.setVolume(room.getSavedVolume().clamp(0.0, 1.0));
        } catch (error, stackTrace) {
          // A damaged/migrating volume preference is not a playback failure.
          // Keep the already-open live stream usable and fall back to the
          // adapter's current volume.
          log('Restore room volume failed: $error', name: 'PlayerManager', error: error, stackTrace: stackTrace);
        }
      }
      if (!_isSessionValid(mySessionId) || !_isPlaybackCommandCurrent(sourceIntentRevision)) return;
      // Opening the source can finish before the native cache has refilled.
      // Keep that buffering episode authoritative for both UI and recovery.
      _stateSubject.add(_nativeLoading ? PlayerState.buffering : PlayerState.ready);
      _scheduleAudioServiceSync(player, audioOnly, room: room, sessionId: mySessionId);
      _publishSourceCommit(
        sessionId: mySessionId,
        intentRevision: sourceIntentRevision,
        room: room,
        source: targetSource,
        urls: targetPlayUrls,
        headers: headers,
        audioOnly: audioOnly,
        selection: committedSelection,
      );
    } on PlayerException catch (e) {
      if (_isSessionValid(mySessionId) && _isPlaybackCommandCurrent(sourceIntentRevision)) {
        await _handleError(e, sessionId: mySessionId);
      }
    } catch (e, s) {
      log(e.toString());
      if (_isSessionValid(mySessionId) && _isPlaybackCommandCurrent(sourceIntentRevision)) {
        final exception = PlayerException(
          message: 'Play failed',
          type: PlayerErrorType.unknown,
          error: e,
          stackTrace: s,
        );
        await _handleError(exception, sessionId: mySessionId);
      }
    } finally {
      _isSwitchingDueToFallback = false;
    }
  }

  Future<void> replay() {
    _playbackRequested = true;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _cancelPendingSourceInputs();
    _playbackSuspensions.clear();
    _sameEngineRecoveryAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _cancelTransientLiveRetry();
    _cancelContinuityRecovery();
    final intentRevision = _playbackIntentRevision;
    return _enqueuePlayerLifecycle(() async {
      if (!_isPlaybackCommandCurrent(intentRevision) || _currentSource == null) return;

      await _playInternal(
        _currentSource!,
        _currentPlayUrls,
        _currentHeaders,
        room: currentFloatRoom,
        audioOnly: _runtimeAudioOnly,
      );
    });
  }

  /// Changes the current room between video and audio-only in place.
  ///
  /// Reopening the whole stream made the UI wait for native stop/dispose,
  /// player initialization, AudioService binding and CDN setup. A stalled
  /// native future therefore left the room on an endless loading indicator.
  Future<void> setAudioOnlyMode(bool audioOnly) async {
    if (_disposed || _isClosing) return;
    if (audioOnly) _cancelVideoFrameStallRecovery();
    if (!audioOnly) {
      _audioModeVideoWarmTimer?.cancel();
      _audioModeVideoWarmTimer = null;
    }
    _requestedAudioOnly = audioOnly;
    await _audioModeTransitions.submit(audioOnly);
  }

  Future<void> _applyAudioOnlyMode(bool audioOnly) async {
    if (_disposed || _isClosing) return;
    final player = _currentPlayer;
    if (player == null) {
      throw PlayerException(message: 'Current player is null', type: PlayerErrorType.lifecycle);
    }

    final previous = _runtimeAudioOnly;
    final transitionSessionId = _sessionId;
    final enteringAudioMode = audioOnly && !previous;
    final restoringDeepVideo = !audioOnly && previous && _nativeAudioOnly;

    // Cover the native video immediately when entering audio mode. Disabling
    // mpv's video track can make its buffering stream briefly report loading;
    // publishing the audio presentation first prevents that native transition
    // from replacing the room with an endless loading indicator. Restoring
    // video uses the opposite order and keeps the audio UI visible until the
    // Surface has really been re-enabled.
    if (enteringAudioMode && _requestedAudioOnly == audioOnly) {
      isVideoRestorePending.value = false;
      _runtimeAudioOnly = true;
      videoPresentationRevision.value++;
    }
    if (restoringDeepVideo && _requestedAudioOnly == audioOnly) {
      isVideoRestorePending.value = true;
    }
    try {
      final warmRetention = audioModeVideoWarmRetention;
      final keepVideoWarm =
          enteringAudioMode && !_nativeAudioOnly && (warmRetention == null || warmRetention > Duration.zero);
      if (keepVideoWarm) {
        _scheduleNativeAudioOnlyCommit(player, transitionSessionId);
      } else {
        // Restoring always submits `false`, even while the warm timer's
        // `true` command is in flight. The adapter's latest-value queue then
        // guarantees that a late power-saving commit cannot turn video off
        // again after the user has requested it.
        await player.setAudioOnly(audioOnly).timeout(audioModeSwitchTimeout);
        if (_requestedAudioOnly == audioOnly) {
          _nativeAudioOnly = audioOnly;
        }
      }
      if (!identical(_currentPlayer, player) || _disposed || _isClosing || transitionSessionId != _sessionId) {
        if (restoringDeepVideo) isVideoRestorePending.value = false;
        return;
      }

      _runtimeAudioOnly = audioOnly;
      // The request may have been superseded by a floating-window re-entry or
      // another room while the native command was pending. Let the queue apply
      // the latest value without publishing this stale intermediate state.
      if (_requestedAudioOnly != audioOnly) {
        if (restoringDeepVideo) isVideoRestorePending.value = false;
        return;
      }
      // Publish presentation state before synchronizing the notification/
      // foreground service. The headphone action must never leave the native
      // video surface as the only visible feedback while Android initializes
      // its media session.
      if (!enteringAudioMode) {
        isVideoRestorePending.value = false;
        videoPresentationRevision.value++;
        _scheduleActiveContentProbe();
        _armVideoFrameStallRecovery(player, transitionSessionId);
      }
    } catch (error, stackTrace) {
      if (!identical(_currentPlayer, player) || _disposed || _isClosing || transitionSessionId != _sessionId) {
        if (restoringDeepVideo) isVideoRestorePending.value = false;
        return;
      }
      // Future.timeout does not stop the native command. Do not launch an
      // opposite command concurrently here. Record the desired rollback; the
      // adapter's serialized latest-value queue will apply it after the timed
      // out command returns.
      if (_requestedAudioOnly == audioOnly) {
        _requestedAudioOnly = previous;
      }
      unawaited(player.setAudioOnly(_requestedAudioOnly).catchError((_) {}));
      if (_runtimeAudioOnly != previous) {
        _runtimeAudioOnly = previous;
        videoPresentationRevision.value++;
      }
      isVideoRestorePending.value = false;
      throw PlayerException(
        message: error is TimeoutException ? 'Audio mode switch timed out' : 'Audio mode switch failed',
        type: PlayerErrorType.lifecycle,
        error: error,
        stackTrace: stackTrace,
      );
    }

    // The native player transition above is authoritative. Android's media
    // notification/foreground-service initialization is a separate serialized
    // lane and may be delayed by the OS. It never blocks or rolls back the
    // headphone action.
    _scheduleAudioServiceSync(player, audioOnly, room: currentFloatRoom, sessionId: transitionSessionId);
  }

  void _scheduleNativeAudioOnlyCommit(UnifiedPlayer player, int sessionId) {
    _audioModeVideoWarmTimer?.cancel();
    final retention = audioModeVideoWarmRetention;
    // The normal foreground headphone action stays warm for its complete
    // lifetime. Android lifecycle will explicitly commit the low-power state
    // when the app backgrounds.
    if (retention == null) return;
    _audioModeVideoWarmTimer = Timer(retention, () {
      _audioModeVideoWarmTimer = null;
      unawaited(_commitNativeAudioOnly(player, sessionId));
    });
  }

  Future<void> _commitNativeAudioOnly(UnifiedPlayer player, int sessionId) async {
    if (_disposed ||
        _isClosing ||
        !_requestedAudioOnly ||
        !_runtimeAudioOnly ||
        !identical(_currentPlayer, player) ||
        sessionId != _sessionId) {
      return;
    }
    if (_nativeAudioOnly) return;
    try {
      await player.setAudioOnly(true).timeout(audioModeSwitchTimeout);
      if (!_disposed &&
          !_isClosing &&
          _requestedAudioOnly &&
          _runtimeAudioOnly &&
          identical(_currentPlayer, player) &&
          sessionId == _sessionId) {
        _nativeAudioOnly = true;
      }
    } catch (error, stackTrace) {
      // The room is already presenting and playing audio. Failure to enter the
      // delayed low-power state must not interrupt that usable session.
      log(
        'Delayed audio-only power-saving commit failed: $error',
        name: 'PlayerManager',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Ends the short manual-switch warm window immediately, e.g. when Android
  /// backgrounds the room. Long ASMR/background sessions still stop video
  /// decode, while a quick foreground toggle can restore without waiting for
  /// the next stream keyframe.
  Future<void> commitAudioOnlyPowerSaving() async {
    final player = _currentPlayer;
    if (player == null || !_requestedAudioOnly || !_runtimeAudioOnly) return;
    _audioModeVideoWarmTimer?.cancel();
    _audioModeVideoWarmTimer = null;
    await _commitNativeAudioOnly(player, _sessionId);
  }

  /// Prepares a manually selected audio room after returning to the foreground.
  /// The audio card remains visible while mpv catches the next keyframe, so a
  /// later headphone tap reveals an already-current video instead of starting
  /// the 1-3 second keyframe wait at tap time.
  Future<void> prepareAudioOnlyVideoRestore() async {
    final player = _currentPlayer;
    final sessionId = _sessionId;
    if (player == null || !_requestedAudioOnly || !_runtimeAudioOnly || !_nativeAudioOnly) return;
    try {
      // Prewarm silently behind the existing audio card. This deliberately
      // does not publish [isVideoRestorePending]: no user action is waiting and
      // showing a restore badge on every app resume would create visual noise.
      await player.setAudioOnly(false).timeout(audioModeSwitchTimeout);
      if (!_disposed &&
          !_isClosing &&
          _requestedAudioOnly &&
          _runtimeAudioOnly &&
          identical(_currentPlayer, player) &&
          sessionId == _sessionId) {
        _nativeAudioOnly = false;
      }
    } catch (error, stackTrace) {
      log('Foreground video warm-up failed: $error', name: 'PlayerManager', error: error, stackTrace: stackTrace);
    }
  }

  void _scheduleAudioServiceSync(UnifiedPlayer player, bool audioOnly, {LiveRoom? room, required int sessionId}) {
    unawaited(
      _audioServiceTransitions
          .submit(_AudioServiceRequest(player: player, audioOnly: audioOnly, room: room, sessionId: sessionId))
          .catchError((Object error, StackTrace stackTrace) {
            log(
              'Audio service synchronization failed: $error',
              name: 'PlayerManager',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  Future<void> _applyAudioServiceRequest(_AudioServiceRequest request) async {
    if (_disposed || _isClosing || !identical(_currentPlayer, request.player) || request.sessionId != _sessionId) {
      return;
    }

    try {
      final sync = _audioModeServiceSync;
      if (sync != null) {
        await sync(request.player, request.audioOnly);
      } else {
        await LiveAudioService.setPlayer(
          request.player,
          audioOnly: request.audioOnly,
          sessionId: request.sessionId,
          isSourceCurrent: () => _isPlayerEventCurrent(request.player, request.sessionId),
          targetVolume: () => currentFloatRoom?.getSavedVolume() ?? 1.0,
        );
      }
      if (_disposed || _isClosing || !identical(_currentPlayer, request.player) || request.sessionId != _sessionId) {
        return;
      }
      if (_requestedAudioOnly != request.audioOnly) return;
      final room = request.room;
      if (room != null && room.roomId != null && currentFloatRoom == room) {
        await _audioSessionStart(room);
      }
    } catch (error, stackTrace) {
      if (!identical(_currentPlayer, request.player) || _disposed || _isClosing || request.sessionId != _sessionId) {
        return;
      }
      log(
        'Audio service sync failed after mode change: $error',
        name: 'PlayerManager',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> switchEngine(PlayerEngine engine, {bool isManual = false, bool? audioOnly}) {
    return _enqueuePlayerLifecycle(() => _switchEngineInternal(engine, isManual: isManual, audioOnly: audioOnly));
  }

  Future<void> _switchEngineInternal(
    PlayerEngine engine, {
    bool isManual = false,
    bool? audioOnly,
    bool openCurrentSource = true,
    bool forceRecreate = false,
    bool Function()? isStillRequired,
  }) async {
    if (_disposed || _isClosing || isStillRequired?.call() == false) return;

    if (!forceRecreate && _runtimeEngine == engine && _currentPlayer != null) {
      return;
    }

    final sessionId = _sessionId;
    final oldPlayer = _currentPlayer;
    final oldEngine = _runtimeEngine;
    final oldDefaultEngine = _defaultEngine;
    final oldRuntimeAudioOnly = _runtimeAudioOnly;
    final oldRequestedAudioOnly = _requestedAudioOnly;
    final oldNativeAudioOnly = _nativeAudioOnly;
    final targetAudioOnly = audioOnly ?? _runtimeAudioOnly;
    final entryIntentRevision = _playbackIntentRevision;
    final sourceSelection = _sourceSelectionForCurrentCohort();
    UnifiedPlayer? candidate;
    var candidateInstalled = false;

    try {
      final suppressFallbackAudio =
          !isManual &&
          engine != PlayerEngine.mediaKit &&
          oldDefaultEngine == PlayerEngine.mediaKit &&
          _suppressAutomaticFallbackAudio();
      candidate = await _createPlayer(engine, audioOnly: targetAudioOnly, suppressAudioOutput: suppressFallbackAudio);
      if (forceRecreate && identical(candidate, oldPlayer)) {
        throw StateError('Forced player recreation returned the active player instance');
      }
      if (!_isSessionValid(sessionId) ||
          (openCurrentSource && !_isPlaybackCommandCurrent(entryIntentRevision)) ||
          isStillRequired?.call() == false) {
        await _safeDestroyPlayer(candidate);
        return;
      }

      final source = _currentSource;
      if (openCurrentSource && source != null) {
        if (candidate is SourceTransitionAwarePlayer) {
          (candidate as SourceTransitionAwarePlayer).beginSourceTransition();
        }
        await _openPlayerSource(
          candidate,
          source,
          List<String>.from(_currentPlayUrls),
          Map<String, String>.from(_currentHeaders),
          room: currentFloatRoom,
          audioOnly: targetAudioOnly,
          sourceQueryPolicy: sourceSelection?.sourceQueryPolicies[source.url],
        );
        if (!_isSessionValid(sessionId) ||
            (openCurrentSource && !_isPlaybackCommandCurrent(entryIntentRevision)) ||
            isStillRequired?.call() == false) {
          await _safeDestroyPlayer(candidate);
          return;
        }
      }

      // Commit only after the candidate has initialized and, for a live
      // switch, opened the active source. The previous decoder remains the
      // visible/playing owner until this point, so a failed engine no longer
      // turns a recoverable switch into a black screen.
      _currentPlayer = candidate;
      _runtimeEngine = engine;
      _runtimeAudioOnly = targetAudioOnly;
      _requestedAudioOnly = targetAudioOnly;
      _nativeAudioOnly = targetAudioOnly;

      if (isManual) {
        _defaultEngine = engine;
      }
      try {
        await _bindPlayerStreams(candidate, sessionId: sessionId);
        candidateInstalled = true;
      } catch (_) {
        // Stream binding is part of installing the replacement engine. Roll
        // the transaction back instead of leaking a half-installed native
        // player and abandoning the still-usable previous decoder.
        _currentPlayer = oldPlayer;
        _runtimeEngine = oldEngine;
        _defaultEngine = oldDefaultEngine;
        _runtimeAudioOnly = oldRuntimeAudioOnly;
        _requestedAudioOnly = oldRequestedAudioOnly;
        _nativeAudioOnly = oldNativeAudioOnly;
        if (oldPlayer != null) {
          try {
            await _bindPlayerStreams(oldPlayer, sessionId: sessionId);
          } catch (restoreError, restoreStackTrace) {
            log(
              'Restore previous player subscriptions failed: $restoreError',
              name: 'PlayerManager',
              error: restoreError,
              stackTrace: restoreStackTrace,
            );
          }
        }
        rethrow;
      }
      if (openCurrentSource && source != null) {
        _sourceOpened = true;
        _armSourceReadyDeadline(candidate, sessionId);
        // Candidate source events can be emitted synchronously while opening,
        // before its streams become the installed subscriptions. Replaying the
        // adapter's authoritative state here closes that hand-off gap. Without
        // it, a successful same-engine recovery inherited `loading=true` from
        // the failed transport, disabled the frame watchdog and never restored
        // its recovery budget.
        if (candidate.isPlayingNow) {
          _playingSubject.add(true);
          _loadingSubject.add(false);
          _stateSubject.add(PlayerState.playing);
          hasError.value = false;
          if (source.url != null) lineManager.markSuccess(source.url!);
          fallbackManager.reset(engine);
          _armVideoFrameStallRecovery(candidate, sessionId);
          _scheduleProactiveSourceRefresh(candidate, sessionId);
          _scheduleActiveContentProbe();
        } else {
          _playingSubject.add(false);
          _loadingSubject.add(true);
          _stateSubject.add(PlayerState.preparing);
        }
      }
      if (oldPlayer != null && !identical(oldPlayer, candidate)) {
        await _safeDestroyPlayer(oldPlayer);
      }
      // A replacement player is a new native/render generation. The same
      // diagnostic is meaningful again if the replacement also stalls.
      _errorDedupeSession = sessionId;
      _errorDedupeSignatures.clear();
      videoKey.value = ValueKey("video_${DateTime.now().millisecondsSinceEpoch}");
      _scheduleAudioServiceSync(candidate, targetAudioOnly, room: currentFloatRoom, sessionId: sessionId);
      _scheduleRecoveryBudgetReset(candidate, sessionId);
      if (openCurrentSource && source != null) {
        _publishSourceCommit(
          sessionId: sessionId,
          intentRevision: entryIntentRevision,
          room: currentFloatRoom,
          source: source,
          urls: _currentPlayUrls,
          headers: _currentHeaders,
          audioOnly: targetAudioOnly,
          selection: sourceSelection,
        );
      }
    } catch (e, s) {
      if (!candidateInstalled && candidate != null && !identical(candidate, oldPlayer)) {
        await _safeDestroyPlayer(candidate);
      }
      if (!candidateInstalled && identical(_currentPlayer, candidate)) {
        _currentPlayer = oldPlayer;
        _runtimeEngine = oldEngine;
        _defaultEngine = oldDefaultEngine;
        _runtimeAudioOnly = oldRuntimeAudioOnly;
        _requestedAudioOnly = oldRequestedAudioOnly;
        _nativeAudioOnly = oldNativeAudioOnly;
      }
      final exception = PlayerException(
        message: 'Switch engine failed: $e',
        type: PlayerErrorType.lifecycle,
        error: e,
        stackTrace: s,
      );
      if (isManual) _publishTerminalPlayerError(exception);
      throw exception;
    }
  }

  /// Opens a same-engine replacement off-screen and commits it only after the
  /// Windows renderer has presented a frame. The active texture remains the
  /// visible owner during DNS/TLS/demux/decoder startup, removing the black
  /// interval produced by `Player.open` on the active instance.
  Future<bool> _tryWarmSwapSource(
    PlaybackSource source,
    List<String> playUrls,
    Map<String, String> headers, {
    required LiveRoom? room,
    required bool audioOnly,
    required DateTime? sourceRefreshAt,
    PlaybackSourceQualitySelection? sourceSelection,
    bool replaceSourceSelection = false,
    bool Function()? isStillRequired,
    void Function()? beforeSourceReplacement,
  }) async {
    final url = source.url;
    final oldPlayer = _currentPlayer;
    final engine = _runtimeEngine;
    if (!PlatformUtils.isWindows || oldPlayer == null || engine == null || _disposed || _isClosing) return false;

    final oldSessionId = _sessionId;
    final oldSource = _currentSource;
    final oldSourceOpened = _sourceOpened;
    final oldUrls = List<String>.from(_currentPlayUrls);
    final oldHeaders = Map<String, String>.from(_currentHeaders);
    final oldRoom = currentFloatRoom;
    final oldRuntimeAudioOnly = _runtimeAudioOnly;
    final oldRequestedAudioOnly = _requestedAudioOnly;
    final oldNativeAudioOnly = _nativeAudioOnly;
    final oldSourceRefreshAt = _currentSourceRefreshAt;
    final expectedIntentRevision = _playbackIntentRevision;
    final committedSelection = replaceSourceSelection ? sourceSelection : _sourceSelectionForCurrentCohort();
    UnifiedPlayer? candidate;
    StreamSubscription<int>? frameSubscription;
    StreamSubscription<bool>? playingSubscription;
    StreamSubscription<PlayerException>? errorSubscription;
    // An error can arrive while native open is still awaited, before the
    // readiness Future has a listener. Carry the result as data until this
    // transaction awaits it; completeError here escaped to the root Zone.
    final ready = Completer<PlayerException?>();
    PlayerException? candidateError;
    var oldPausedForCommit = false;
    var installed = false;
    bool ownsTransaction() =>
        _isSessionValid(oldSessionId) &&
        identical(_currentPlayer, oldPlayer) &&
        _playbackIntentRevision == expectedIntentRevision &&
        _playbackRequested &&
        _playbackSuspensions.isEmpty;
    bool mayCommit() => ownsTransaction() && (isStillRequired?.call() ?? true);

    try {
      if (!mayCommit()) return true;
      candidate = await _takeWindowsWarmStandby(engine, audioOnly: audioOnly);
      if (identical(candidate, oldPlayer)) return false;
      if (!mayCommit()) return true;
      await candidate.setVolume(0);
      if (!mayCommit()) return true;

      if (candidate is VideoFrameProgressAwarePlayer &&
          (candidate as VideoFrameProgressAwarePlayer).supportsVideoFrameProgress &&
          !audioOnly) {
        frameSubscription = (candidate as VideoFrameProgressAwarePlayer).onVideoFrameProgress.listen((_) {
          if (!ready.isCompleted) ready.complete();
        });
      } else {
        playingSubscription = candidate.onPlaying.listen((playing) {
          if (playing && !ready.isCompleted) ready.complete();
        });
      }
      errorSubscription = candidate.onError.listen((error) {
        candidateError = error;
        if (!ready.isCompleted) ready.complete(error);
      });

      if (candidate is SourceTransitionAwarePlayer) {
        (candidate as SourceTransitionAwarePlayer).beginSourceTransition();
      }
      await _openPlayerSource(
        candidate,
        source,
        List<String>.from(playUrls),
        Map<String, String>.from(headers),
        room: room,
        audioOnly: audioOnly,
        sourceQueryPolicy: committedSelection?.sourceQueryPolicies[url],
      );
      final warmTimeout = sourceReadyTimeout > Duration.zero ? sourceReadyTimeout : const Duration(seconds: 8);
      final readyError = await ready.future.timeout(warmTimeout);
      if (readyError != null) throw readyError;
      if (candidateError != null) throw candidateError!;
      if (!mayCommit()) return true;

      var targetVolume = 1.0;
      if (room != null) {
        try {
          targetVolume = room.getSavedVolume().clamp(0.0, 1.0).toDouble();
        } catch (error, stackTrace) {
          log(
            'Restore room volume during warm source replacement failed: $error',
            name: 'PlayerManager',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      await oldPlayer.pause();
      oldPausedForCommit = true;
      if (!mayCommit()) return true;
      if (candidateError != null) throw candidateError!;
      await candidate.setVolume(targetVolume);
      if (!mayCommit()) return true;
      if (candidateError != null) throw candidateError!;

      beforeSourceReplacement?.call();
      final newSessionId = ++_sessionId;
      _currentPlayer = candidate;
      _runtimeEngine = engine;
      _runtimeAudioOnly = audioOnly;
      _requestedAudioOnly = audioOnly;
      _nativeAudioOnly = audioOnly;
      _currentSource = source;
      _sourceOpened = true;
      _currentPlayUrls = List<String>.from(playUrls);
      _currentHeaders = Map<String, String>.from(headers);
      _currentSourceRefreshAt = _effectiveSourceRefreshAt(sourceRefreshAt, url: url);
      currentFloatRoom = room;
      _beginVideoGeometrySession(room, selectedUrl: url);
      refreshPortraitPresentationPolicy(notifyController: false);
      await _bindPlayerStreams(candidate, sessionId: newSessionId);
      installed = true;
      _stateSubject.add(PlayerState.playing);
      _playingSubject.add(true);
      _loadingSubject.add(false);
      hasError.value = false;
      _errorDedupeSession = newSessionId;
      _errorDedupeSignatures.clear();
      videoKey.value = ValueKey('video_${DateTime.now().millisecondsSinceEpoch}');
      videoPresentationRevision.value++;
      _scheduleAudioServiceSync(candidate, audioOnly, room: room, sessionId: newSessionId);
      _scheduleSourceRefreshAttemptReset(candidate, newSessionId);
      _scheduleRecoveryBudgetReset(candidate, newSessionId);
      _scheduleProactiveSourceRefresh(candidate, newSessionId);
      await _parkWindowsWarmStandby(oldPlayer, audioOnly: oldNativeAudioOnly);
      _publishSourceCommit(
        sessionId: newSessionId,
        intentRevision: expectedIntentRevision,
        room: room,
        source: source,
        urls: playUrls,
        headers: headers,
        audioOnly: audioOnly,
        selection: committedSelection,
      );
      return true;
    } catch (error, stackTrace) {
      log(
        'Warm source replacement failed; retaining the active source: $error',
        name: 'PlayerManager',
        error: error,
        stackTrace: stackTrace,
      );
      if (candidate != null && identical(_currentPlayer, candidate)) {
        installed = false;
        final rollbackSessionId = ++_sessionId;
        _currentPlayer = oldPlayer;
        _runtimeEngine = engine;
        _runtimeAudioOnly = oldRuntimeAudioOnly;
        _requestedAudioOnly = oldRequestedAudioOnly;
        _nativeAudioOnly = oldNativeAudioOnly;
        _currentSource = oldSource;
        _sourceOpened = oldSourceOpened;
        _currentPlayUrls = oldUrls;
        _currentHeaders = oldHeaders;
        _currentSourceRefreshAt = oldSourceRefreshAt;
        currentFloatRoom = oldRoom;
        await _bindPlayerStreams(oldPlayer, sessionId: rollbackSessionId);
        // The source transaction failed and emits no commit, but the restored
        // source remains canonical under a new native event generation.
        _rebindSourceCommitToSession(rollbackSessionId);
      }
      // Cancellation is a consumed transaction, including on failure. A false
      // result permits the caller to reopen the active player destructively.
      return !mayCommit();
    } finally {
      await frameSubscription?.cancel();
      await playingSubscription?.cancel();
      await errorSubscription?.cancel();
      if (!installed && candidate != null && !identical(candidate, oldPlayer)) {
        await _safeDestroyPlayer(candidate);
      }
      if (!installed &&
          oldPausedForCommit &&
          identical(_currentPlayer, oldPlayer) &&
          !_disposed &&
          !_isClosing &&
          _playbackRequested &&
          _playbackSuspensions.isEmpty &&
          _playbackIntentRevision == expectedIntentRevision) {
        try {
          await oldPlayer.play();
        } catch (_) {}
      }
    }
  }

  Future<UnifiedPlayer> _takeWindowsWarmStandby(PlayerEngine engine, {required bool audioOnly}) async {
    final standby = _windowsWarmStandbyPlayer;
    final standbyAudioOnly = _windowsWarmStandbyAudioOnly;
    _windowsWarmStandbyPlayer = null;
    _windowsWarmStandbyAudioOnly = null;

    if (standby != null) {
      if (standby.engine == engine && standbyAudioOnly == audioOnly && standby.isInitialized && standby.isReusable) {
        return standby;
      }
      await _safeDestroyPlayer(standby);
    }
    return _createPlayer(engine, audioOnly: audioOnly);
  }

  Future<void> _parkWindowsWarmStandby(UnifiedPlayer player, {required bool audioOnly}) async {
    if (!PlatformUtils.isWindows || _disposed || _isClosing || !player.isInitialized || !player.isReusable) {
      await _safeDestroyPlayer(player);
      return;
    }

    try {
      await player.setVolume(0);
      // media_kit softStop unloads the active Media, closing the old HTTP
      // transport and releasing demux/decoder buffers while retaining the
      // initialized native Player and D3D renderer for the next hand-off.
      await player.softStop();
      await _closeSourceTransport(player);
    } catch (error, stackTrace) {
      log('Retiring Windows warm standby failed: $error', name: 'PlayerManager', error: error, stackTrace: stackTrace);
      await _safeDestroyPlayer(player);
      return;
    }

    if (_disposed || _isClosing || identical(_currentPlayer, player)) {
      await _safeDestroyPlayer(player);
      return;
    }

    final previous = _windowsWarmStandbyPlayer;
    _windowsWarmStandbyPlayer = player;
    _windowsWarmStandbyAudioOnly = audioOnly;
    if (previous != null && !identical(previous, player)) {
      await _safeDestroyPlayer(previous);
    }
  }

  Future<void> _disposeWindowsWarmStandby() async {
    final standby = _windowsWarmStandbyPlayer;
    _windowsWarmStandbyPlayer = null;
    _windowsWarmStandbyAudioOnly = null;
    if (standby != null && !identical(standby, _currentPlayer)) {
      await _safeDestroyPlayer(standby);
    }
  }

  Future<void> _openPlayerSource(
    UnifiedPlayer player,
    PlaybackSource source,
    List<String> playUrls,
    Map<String, String> headers, {
    required LiveRoom? room,
    required bool audioOnly,
    required HlsSourceQueryPolicy? sourceQueryPolicy,
  }) async {
    final transport = _sourceTransports.putIfAbsent(
      player,
      () => PlaybackSourceTransport(createInput: _sourceInputFactory),
    );
    Future<void> nativeOpen(String input, List<String> inputs, Map<String, String> inputHeaders, bool privateInput) {
      if (player is PrivateInputAwarePlayer) {
        (player as PrivateInputAwarePlayer).setPrivateInput(privateInput, sourceIdentity: source.identity);
      }
      return player.setDataSource(input, inputs, inputHeaders, room: room, audioOnly: audioOnly);
    }

    final refreshAt = _currentSourceRefreshAt;
    final renewFlv = source is UrlPlaybackSource && sourceQueryPolicy == null
        ? _flvLeaseRenewer(source.url, playUrls, refreshAt)
        : null;
    if (renewFlv != null) {
      _splicedLeasePlayers.add(player);
    } else {
      _splicedLeasePlayers.remove(player);
    }
    final sourceOpen = switch (source) {
      OwnedPlaybackSource() => transport.openOwned(createInput: source.createInput, nativeOpen: nativeOpen),
      UrlPlaybackSource() => transport.open(
        url: source.url,
        urls: playUrls,
        headers: headers,
        policy: sourceQueryPolicy,
        nativeOpen: nativeOpen,
        rewriteLegacyHevcFlv: player is MediaKitAdapter,
        refreshAt: refreshAt,
        renewFlv: renewFlv,
      ),
    };
    try {
      if (sourceOpenTimeout <= Duration.zero) {
        await sourceOpen;
        return;
      }
      await sourceOpen.timeout(
        sourceOpenTimeout,
        onTimeout: () {
          throw PlayerException(
            message: 'Native player did not finish opening the source before the deadline',
            type: PlayerErrorType.initialization,
            code: 'source_open_timeout',
          );
        },
      );
    } catch (_) {
      await transport.cancelPending();
      rethrow;
    }
  }

  Future<void> _closeSourceTransport(UnifiedPlayer player) async {
    _splicedLeasePlayers.remove(player);
    await _sourceTransports.remove(player)?.close();
  }

  /// Resolves the next URL of the same line and quality for a leased FLV
  /// source, or null when the source is not spliced.
  FlvSourceRenewer? _flvLeaseRenewer(String url, List<String> playUrls, DateTime? refreshAt) {
    final resolver = _sourceRefreshResolver;
    if (resolver == null || !FlvSpliceRelay.appliesTo(url, refreshAt: refreshAt)) return null;
    final lineIndex = playUrls.indexOf(url);
    return (current) async {
      final currentUrl = current.url.toString();
      final refreshed = await _resolvePlaybackSource(
        resolver,
        PlaybackSourceRefreshRequest(
          currentLineIndex: lineIndex < 0 ? 0 : lineIndex,
          advanceLine: false,
          currentUrl: currentUrl,
          currentSource: UrlPlaybackSource(currentUrl),
          currentQuality: _sourceSelectionForCurrentCohort()?.quality,
        ),
      );
      final urls = refreshed.urls.map((item) => item.trim()).where((item) => item.isNotEmpty).toList(growable: false);
      if (urls.isEmpty) throw StateError('No renewed FLV source');
      final next = urls[refreshed.preferredLineIndex.clamp(0, urls.length - 1)];
      return FlvLeasedSource(Uri.parse(next), refreshAt: refreshed.refreshAt);
    };
  }

  void _cancelPendingSourceInputs() {
    for (final transport in _sourceTransports.values) {
      unawaited(
        transport.cancelPending().catchError((Object error, StackTrace stackTrace) {
          log('Pending source input cleanup failed', name: 'PlayerManager', error: error, stackTrace: stackTrace);
        }),
      );
    }
  }

  Future<void> _disposePlayerWithTransport(UnifiedPlayer player) async {
    try {
      await _closeSourceTransport(player);
    } finally {
      await player.hardDispose();
    }
  }

  Future<void> _safeDestroyPlayer(UnifiedPlayer player) async {
    try {
      await _disposePlayerWithTransport(player);
    } catch (e, s) {
      log("destroy player error: $e", stackTrace: s);
    }
  }

  void _armSourceReadyDeadline(UnifiedPlayer player, int sessionId) {
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    if (sourceReadyTimeout <= Duration.zero || player.isPlayingNow || !_isPlayerEventCurrent(player, sessionId)) {
      return;
    }
    _sourceReadyTimer = Timer(sourceReadyTimeout, () {
      _sourceReadyTimer = null;
      if (!_isPlayerEventCurrent(player, sessionId) || player.isPlayingNow || _playingSubject.value) return;
      _schedulePlayerError(
        PlayerException(
          message: 'Source opened but produced no playable frame before the readiness deadline',
          type: PlayerErrorType.source,
          code: 'source_ready_timeout',
        ),
        sessionId,
        isStillRelevant: () => !player.isPlayingNow && !_playingSubject.value,
      );
    });
  }

  void _schedulePlayerError(PlayerException error, int sessionId, {bool Function()? isStillRelevant}) {
    final expectedPlayer = _currentPlayer;
    final expectedIntentRevision = _playbackIntentRevision;
    _traceWindowsRecovery('schedule', error: error, sessionId: sessionId);
    unawaited(
      _enqueuePlayerLifecycle(() async {
        // Queueing preserves native ownership but can outlive the observation:
        // a token request may still be in flight while media recovers or the
        // user pauses. Revalidate before changing loading, timers or sources.
        if (!_isSessionValid(sessionId) ||
            !identical(expectedPlayer, _currentPlayer) ||
            expectedIntentRevision != _playbackIntentRevision ||
            !_playbackRequested ||
            _playbackSuspensions.isNotEmpty ||
            (isStillRelevant != null && !isStillRelevant())) {
          return;
        }
        _traceWindowsRecovery('dispatch', error: error, sessionId: sessionId);
        await _handleError(error, sessionId: sessionId);
      }).catchError((Object failure, StackTrace stackTrace) {
        log(
          'Scheduled player recovery failed: $failure',
          name: 'PlayerManager',
          error: failure,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  bool get _isContinuousLiveSource {
    final room = currentFloatRoom;
    return room != null && room.isRecord != true && room.isCatchUp != true;
  }

  bool _shouldMaintainPlayback(UnifiedPlayer player, int sessionId) {
    return _shouldOwnContinuousPlayback(player, sessionId) && !_loadingSubject.value;
  }

  bool _shouldOwnContinuousPlayback(UnifiedPlayer player, int sessionId) {
    return _isPlayerEventCurrent(player, sessionId) &&
        _playbackRequested &&
        _playbackSuspensions.isEmpty &&
        _isContinuousLiveSource &&
        _currentSource != null &&
        !hasError.value;
  }

  void _cancelContinuityRecovery() {
    _continuityRevision++;
    _continuityTimer?.cancel();
    _continuityTimer = null;
    _bufferingStallTimer?.cancel();
    _bufferingStallTimer = null;
  }

  void _cancelTransientLiveRetry() {
    _transientLiveRetryRevision++;
    _transientLiveRetryTimer?.cancel();
    _transientLiveRetryTimer = null;
    _transientLiveRetryOwner = null;
  }

  void _cancelVideoFrameStallRecovery() {
    _videoFrameStallTimer?.cancel();
    _videoFrameStallTimer = null;
    _videoFrameDeadline = null;
    _videoFrameWatchdogClock
      ..stop()
      ..reset();
  }

  /// Marks whether the current route owns a mounted video presentation.
  ///
  /// Windows intentionally tears down its Flutter Texture while an opaque
  /// route (for example the recorder centre) covers the room. Native frame
  /// progress therefore stops even though the Huya transport is healthy. That
  /// absence is expected presentation lifecycle, not a playback stall; treating
  /// it as a stall needlessly opened a second signed CDN transport and could
  /// return to a black frame when the replacement hit 403/404.
  ///
  /// The transport and audio remain alive. Once the room surface is mounted
  /// again, the watchdog is re-armed and the native viewport is reasserted by
  /// the video widget.
  void setVideoPresentationVisible(bool visible) {
    if (_videoPresentationVisible == visible) return;
    _videoPresentationVisible = visible;
    if (!visible) {
      _cancelVideoFrameStallRecovery();
      return;
    }
    final player = _currentPlayer;
    if (player != null) {
      _armVideoFrameStallRecovery(player, _sessionId);
    }
  }

  bool _supportsVideoFrameProgress(UnifiedPlayer player) {
    return player is VideoFrameProgressAwarePlayer &&
        (player as VideoFrameProgressAwarePlayer).supportsVideoFrameProgress;
  }

  void _armVideoFrameStallRecovery(UnifiedPlayer player, int sessionId) {
    if (videoFrameStallTimeout <= Duration.zero ||
        !_videoPresentationVisible ||
        _runtimeAudioOnly ||
        !_supportsVideoFrameProgress(player) ||
        !_shouldOwnContinuousPlayback(player, sessionId) ||
        _loadingSubject.value ||
        (!player.isPlayingNow && !isPlayingNow)) {
      _cancelVideoFrameStallRecovery();
      return;
    }
    // Progress notifications move a monotonic deadline, not a Timer allocation.
    // Windows currently throttles them to 500 ms; other implementations may
    // emit more often. Check the remaining time only when the one pending
    // timer wakes, preserving the full timeout after the last notification
    // independently of wall-clock adjustments and notification frequency.
    _videoFrameWatchdogClock.start();
    _videoFrameDeadline = _videoFrameWatchdogClock.elapsed + videoFrameStallTimeout;
    if (_videoFrameStallTimer != null) return;

    void checkDeadline() {
      _videoFrameStallTimer = null;
      if (!_videoPresentationVisible ||
          _runtimeAudioOnly ||
          !_shouldOwnContinuousPlayback(player, sessionId) ||
          _loadingSubject.value ||
          (!player.isPlayingNow && !isPlayingNow)) {
        _cancelVideoFrameStallRecovery();
        return;
      }
      final deadline = _videoFrameDeadline;
      if (deadline == null) return;
      final remaining = deadline - _videoFrameWatchdogClock.elapsed;
      if (remaining > Duration.zero) {
        _videoFrameStallTimer = Timer(remaining, checkDeadline);
        return;
      }
      _cancelVideoFrameStallRecovery();
      final observedFrameRevision = _presentedFrameRevision;
      _schedulePlayerError(
        PlayerException(
          message: 'Live player remained active but presented no new video frame',
          type: PlayerErrorType.source,
          code: 'video_frame_stall_timeout',
        ),
        sessionId,
        isStillRelevant: () =>
            observedFrameRevision == _presentedFrameRevision &&
            _videoPresentationVisible &&
            !_runtimeAudioOnly &&
            !_loadingSubject.value &&
            (player.isPlayingNow || isPlayingNow),
      );
    }

    _videoFrameStallTimer = Timer(videoFrameStallTimeout, checkDeadline);
  }

  void _scheduleRecoveryBudgetReset(UnifiedPlayer player, int sessionId) {
    if (recoveryBudgetResetDelay <= Duration.zero ||
        (_sourceRefreshAttempts == 0 && _sameEngineRecoveryAttempts == 0 && _transientLiveRetryAttempts == 0)) {
      return;
    }
    _sourceRefreshAttemptResetTimer ??= Timer(recoveryBudgetResetDelay, () {
      _sourceRefreshAttemptResetTimer = null;
      if (!_isPlayerEventCurrent(player, sessionId) ||
          !player.isPlayingNow ||
          _loadingSubject.value ||
          hasError.value ||
          _playbackSuspensions.isNotEmpty) {
        return;
      }
      _sourceRefreshAttempts = 0;
      _sameEngineRecoveryAttempts = 0;
      _transientLiveRetryAttempts = 0;
      lineManager.reset();
      fallbackManager.resetAll();
      log('Sustained playback restored live recovery budgets', name: 'PlayerManager');
    });
  }

  void _notePresentedFrameProgress(UnifiedPlayer player, int sessionId) {
    if (!_isPlayerEventCurrent(player, sessionId)) return;
    _lastPresentedFrameAt = DateTime.now();
    _presentedFrameRevision++;
    _retireTransientLiveRetryForProgress(videoFrame: true);
    _scheduleRecoveryBudgetReset(player, sessionId);
  }

  void _retireTransientLiveRetryForProgress({
    bool videoFrame = false,
    bool bufferingEnded = false,
    bool playingResumed = false,
  }) {
    final retry = _transientLiveRetryOwner;
    if (retry == null) return;
    // Use the same evidence contract as immediate recovery. Buffered tail
    // frames or late texture notifications never refute an explicit EOF or a
    // terminal native error. Only the matching inferred stall is retired.
    final refuted = switch (retry.error.code) {
      'video_frame_stall_timeout' => videoFrame,
      'buffering_stall_timeout' => bufferingEnded,
      'unexpected_pause_resume_failed' || 'unexpected_pause_timeout' || 'source_ready_timeout' => playingResumed,
      _ => false,
    };
    if (!refuted) return;
    _cancelTransientLiveRetry();
    _errorDedupeSignatures.remove('${retry.error.type.name}:${retry.error.code ?? '-'}:${retry.error.message}');
    final playing = _currentPlayer?.isPlayingNow == true;
    _playingSubject.add(playing);
    _loadingSubject.add(_nativeLoading);
    _stateSubject.add(_nativeLoading ? PlayerState.buffering : (playing ? PlayerState.playing : PlayerState.paused));
    hasError.value = false;
  }

  void _scheduleBufferingStallRecovery(UnifiedPlayer player, int sessionId) {
    if (bufferingStallTimeout <= Duration.zero ||
        !_loadingSubject.value ||
        !_shouldOwnContinuousPlayback(player, sessionId) ||
        _bufferingStallTimer != null) {
      return;
    }
    // Own one deadline per uninterrupted buffering episode. Playing/paused
    // notifications do not prove media arrived; renewing the timer on each
    // notification could postpone recovery indefinitely. Loading=false,
    // explicit pause, a new source and disposal already cancel this owner.
    final revision = ++_continuityRevision;
    _bufferingStallTimer = Timer(bufferingStallTimeout, () {
      _bufferingStallTimer = null;
      if (revision != _continuityRevision ||
          !_loadingSubject.value ||
          !_shouldOwnContinuousPlayback(player, sessionId)) {
        return;
      }
      _schedulePlayerError(
        PlayerException(
          message: 'Live playback remained buffered without media progress',
          type: PlayerErrorType.source,
          code: 'buffering_stall_timeout',
        ),
        sessionId,
        isStillRelevant: () => revision == _continuityRevision && _loadingSubject.value,
      );
    });
  }

  void _scheduleContinuityRecovery(UnifiedPlayer player, int sessionId) {
    if (!_shouldMaintainPlayback(player, sessionId) || player.isPlayingNow || isPlayingNow) return;
    _continuityTimer?.cancel();
    final revision = ++_continuityRevision;
    _continuityTimer = Timer(unexpectedPauseGrace, () {
      _continuityTimer = null;
      unawaited(
        _enqueuePlayerLifecycle(() async {
          if (revision != _continuityRevision ||
              !_shouldMaintainPlayback(player, sessionId) ||
              player.isPlayingNow ||
              isPlayingNow) {
            return;
          }
          try {
            // Some native live players briefly publish `playing=false` after
            // an audio-focus hand-off or CDN discontinuity without raising an
            // error. Reassert the existing source once before escalating to
            // the normal line/engine recovery state machine.
            // A native resume acknowledgement may itself stall when the
            // decoder or platform channel is wedged. Bound this command before
            // handing the failure to the finite source/line/engine recovery
            // path; otherwise the lifecycle queue also blocks later work.
            await player.play().timeout(unexpectedPauseFailureGrace);
          } catch (error, stackTrace) {
            _schedulePlayerError(
              PlayerException(
                message: 'Live playback did not resume after an unexpected pause',
                type: PlayerErrorType.source,
                code: 'unexpected_pause_resume_failed',
                error: error,
                stackTrace: stackTrace,
              ),
              sessionId,
              isStillRelevant: () =>
                  revision == _continuityRevision &&
                  _shouldMaintainPlayback(player, sessionId) &&
                  !player.isPlayingNow &&
                  !isPlayingNow,
            );
            return;
          }
          if (player.isPlayingNow || isPlayingNow || !_shouldMaintainPlayback(player, sessionId)) return;
          final confirmationRevision = ++_continuityRevision;
          _continuityTimer = Timer(unexpectedPauseFailureGrace, () {
            _continuityTimer = null;
            if (confirmationRevision != _continuityRevision ||
                !_shouldMaintainPlayback(player, sessionId) ||
                player.isPlayingNow ||
                isPlayingNow) {
              return;
            }
            _schedulePlayerError(
              PlayerException(
                message: 'Live playback remained paused after the continuity retry',
                type: PlayerErrorType.source,
                code: 'unexpected_pause_timeout',
              ),
              sessionId,
              isStillRelevant: () =>
                  confirmationRevision == _continuityRevision &&
                  _shouldMaintainPlayback(player, sessionId) &&
                  !player.isPlayingNow &&
                  !isPlayingNow,
            );
          });
        }).catchError((Object error, StackTrace stackTrace) {
          log('Unexpected-pause recovery failed: $error', name: 'PlayerManager', stackTrace: stackTrace);
        }),
      );
    });
  }

  Future<void> togglePlayPause() async {
    if (_currentPlayer == null) return;
    if (isPlayingNow) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> pause() async {
    final player = _currentPlayer;
    _playbackRequested = false;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _cancelPendingSourceInputs();
    _playbackSuspensions.clear();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    await player?.pause();
  }

  Future<void> resume() async {
    // Pause can cancel metadata/seat/native creation before a usable source
    // exists. Resuming an empty decoder is not a media open; recreate the
    // retained recipe through the same queue and cancellation transaction.
    if (_currentSource != null && !_sourceOpened) {
      await replay();
      return;
    }
    final player = _currentPlayer;
    if (player == null) return;
    _playbackRequested = true;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _playbackSuspensions.clear();
    _cancelContinuityRecovery();
    await player.play();
    _armVideoFrameStallRecovery(player, _sessionId);
    _scheduleRecoveryBudgetReset(player, _sessionId);
    _scheduleProactiveSourceRefresh(player, _sessionId);
  }

  Future<void> stop() async {
    await close();
    await closeAppFloating();
  }

  Future<void> setVolume(double volume) async {
    await _currentPlayer?.setVolume(volume.clamp(0.0, 1.0));
  }

  double _savedRoomVolume() => (currentFloatRoom?.getSavedVolume() ?? 1.0).clamp(0.0, 1.0).toDouble();

  /// Last audible compact volume, used to restore a sensible level when the
  /// volume icon is pressed while muted.
  double? _compactLastAudibleVolume;

  /// Applies the ephemeral compact volume from the wheel or the volume bar.
  Future<void> setCompactVolumeDirect(double volume) async {
    final player = _currentPlayer;
    if (player == null || _isClosing || _disposed) return;
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    await player.setVolume(clamped);
    _compactVolumeOverride = clamped;
    if (clamped > 0.001) _compactLastAudibleVolume = clamped;
    isCompactMuted.value = clamped <= 0.001;
    compactVolumePreview.value = clamped;
  }

  /// Mouse-wheel volume step for the PiP/floating windows. One conventional
  /// wheel notch (~100 px delta) moves the volume by 5%.
  static const double _compactVolumeWheelStep = 0.05;

  /// Adjusts the ephemeral compact-mode volume by a pointer wheel delta.
  /// Scrolling up raises the volume. The change applies to this session only
  /// and is discarded when compact mode ends.
  Future<void> adjustCompactVolumeByWheel(double scrollDeltaDy) async {
    if (scrollDeltaDy == 0) return;
    final normalized = scrollDeltaDy.clamp(-100.0, 100.0) / 100.0;
    final current = isCompactMuted.value
        ? (_compactLastAudibleVolume ?? _savedRoomVolume())
        : (_compactVolumeOverride ?? _savedRoomVolume());
    await setCompactVolumeDirect(current - normalized * _compactVolumeWheelStep);
  }

  /// Toggles the compact-mode scoped mute used by the PiP/floating volume
  /// icon. Muting sets the live session to volume 0 without touching the
  /// room's saved preference; unmuting restores the last audible level.
  Future<void> toggleCompactMute() async {
    final player = _currentPlayer;
    if (player == null || _isClosing || _disposed) return;
    if (isCompactMuted.value) {
      final restore = (_compactVolumeOverride != null && _compactVolumeOverride! > 0.001)
          ? _compactVolumeOverride!
          : (_compactLastAudibleVolume ?? _savedRoomVolume());
      await setCompactVolumeDirect(restore);
    } else {
      // Remember the audible level so unmute can return to it.
      _compactLastAudibleVolume ??= _compactVolumeOverride ?? _savedRoomVolume();
      await setCompactVolumeDirect(0.0);
    }
  }

  /// Restores the room volume and clears all compact-only volume state.
  /// Called when a PiP/floating session ends so wheel volume and mute never
  /// leak back into the room.
  Future<void> resetCompactMute() async {
    final hadOverride = isCompactMuted.value || _compactVolumeOverride != null;
    isCompactMuted.value = false;
    _compactVolumeOverride = null;
    _compactLastAudibleVolume = null;
    compactVolumePreview.value = _savedRoomVolume();
    final player = _currentPlayer;
    if (!hadOverride || player == null || _isClosing || _disposed) return;
    try {
      await player.setVolume(_savedRoomVolume());
    } catch (error, stackTrace) {
      log('Restore room volume after compact mode failed', name: 'PlayerManager', error: error, stackTrace: stackTrace);
    }
  }

  /// 把当前 compact 会话音量（override 或房间保存音量；静音时为 0）重新施加
  /// 给刚由 play() 创建的全新原生播放器实例，保证实际音量与 UI 图标一致。
  Future<void> _reapplyCompactVolumeAfterReload() async {
    final player = _currentPlayer;
    if (player == null || _isClosing || _disposed) return;
    try {
      await player.setVolume(_compactVolumeValue().clamp(0.0, 1.0).toDouble());
    } catch (error, stackTrace) {
      log(
        'Reapply compact volume after floating reload failed',
        name: 'PlayerManager',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Flips the live topmost state of the current Windows PiP window. This does
  /// not change the `windowsPipAlwaysOnTop` default for future PiP sessions.
  Future<void> toggleWindowsPipAlwaysOnTop() async {
    if (!_usesWindowsPip || !isInPip.value || _pipTransitionInFlight) return;
    final next = !isPipAlwaysOnTop.value;
    try {
      await WindowHelper.instance.setPiPAlwaysOnTop(next);
      isPipAlwaysOnTop.value = next;
    } catch (error, stackTrace) {
      log('Windows PiP always-on-top toggle failed', name: 'PlayerManager', error: error, stackTrace: stackTrace);
      ToastUtil.show(i18n('windows_pip_always_on_top_apply_failed'));
    }
  }

  Future<void> seekTo(Duration position) async => await _currentPlayer?.seekTo(position);

  Future<void> seekRelative(Duration offset) async => await _currentPlayer?.seekRelative(offset);

  Future<void> seekToLiveEdge() async => await _currentPlayer?.seekToLiveEdge();

  Duration get currentPosition => _currentPlayer?.currentPosition ?? Duration.zero;

  Duration get liveEdgePosition => _currentPlayer?.liveEdgePosition ?? Duration.zero;

  /// Full live timeline length (mpv `duration`, keeps growing from stream
  /// start for live streams). [Duration.zero] when unavailable.
  Duration get streamDuration {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.streamDuration;
    return Duration.zero;
  }

  /// Playhead as a 0.0–1.0 fraction of the full timeline — equivalent to
  /// mpv's `percent-pos / 100`. `null` while no duration is known or for
  /// non-media-kit backends.
  double? get positionFraction {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.positionFraction;
    return null;
  }

  /// Cached seekable ranges projected onto the 0.0–1.0 timeline fraction.
  List<({double start, double end})> get seekableFractions {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.seekableFractions;
    return const [];
  }

  /// Seek to a 0.0–1.0 fraction of the full timeline. The target is snapped
  /// into the cached seekable ranges before reaching mpv, so this can never
  /// trigger a live-stream reconnect. No-op for non-media-kit backends.
  Future<void> seekToFraction(double fraction, {bool exact = false}) async {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) await player.seekToFraction(fraction, exact: exact);
  }

  Duration get streamStartPosition {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.streamStartPosition;
    return Duration.zero;
  }

  /// Estimated oldest still-cached frame position; content before this has
  /// been evicted from the back buffer. [Duration.zero] when no eviction has
  /// occurred or for non-media-kit backends.
  Duration get earliestCachedPosition {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.earliestCachedPosition;
    return Duration.zero;
  }

  bool get isUserSeekedBack {
    final player = _currentPlayer;
    if (player is MediaKitAdapter) return player.isUserSeekedBack;
    return false;
  }

  bool get canSeek => _currentPlayer?.canSeek ?? false;

  Stream<Duration> get positionStream {
    final player = _currentPlayer;
    if (player == null) return const Stream.empty();
    return player.positionStream;
  }

  void changeVideoFit(int index) {
    final fitList = SettingsService.to.player.videoFitArray;
    if (fitList.isEmpty || index < 0 || index >= fitList.length) return;
    videoFitIndex.value = index;
    _applyVideoFit(_currentPlayer, fitList[index]);
  }

  void _applyVideoFit(UnifiedPlayer? player, BoxFit fit) {
    if (player is! VideoFitAwarePlayer) return;
    (player as VideoFitAwarePlayer).setVideoFit(fit);
  }

  void _startAndroidPipObservation() {
    if (!_usesAndroidPip || _disposed || _isClosing || _currentPlayer == null || _pipSubscription != null) return;
    floating = _androidFloatingOverride ?? Floating();
    final generation = ++_pipObservationGeneration;
    _pipSubscription = floating.pipStatusStream.listen((status) {
      if (generation != _pipObservationGeneration || _disposed || _isClosing) return;
      _pipStatusRevision++;
      isInPip.value = status == PiPStatus.enabled;
    });
  }

  void _stopAndroidPipObservation() {
    _pipObservationGeneration++;
    final subscription = _pipSubscription;
    _pipSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void _cancelPipTransition() {
    _pipTransitionRevision++;
    _pipGeometryUpdateGeneration++;
    final cancellation = _pipTransitionCancellation;
    _pipTransitionCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) cancellation.complete();
    _pipTransitionInFlight = false;
    isPipPreparing.value = false;
  }

  Future<void> enablePip() async {
    if (_usesAndroidPip) {
      if (_pipTransitionInFlight ||
          _disposed ||
          _isClosing ||
          (_playbackIntentEstablished && !_playbackRequested) ||
          _currentPlayer == null ||
          !isInitialized.value) {
        return;
      }
      _startAndroidPipObservation();
      final sessionId = _sessionId;
      final intentRevision = _playbackIntentRevision;
      final player = _currentPlayer;
      final revision = ++_pipTransitionRevision;
      final cancellation = Completer<void>();
      _pipTransitionCancellation = cancellation;
      bool ownsTransition() =>
          revision == _pipTransitionRevision &&
          _isSessionValid(sessionId) &&
          intentRevision == _playbackIntentRevision &&
          identical(player, _currentPlayer);
      _pipTransitionInFlight = true;
      try {
        final status = await Future.any<PiPStatus?>([floating.pipStatus, cancellation.future.then((_) => null)]);
        if (!ownsTransition() || status != PiPStatus.disabled) return;

        // Android captures the Activity at the start of the PiP animation.
        // Build the compact video-only surface first, then enter PiP after a
        // rendered frame so Texture/PlatformView players do not show an app
        // icon or a black placeholder while being reattached.
        isPipPreparing.value = true;
        await Future.any<void>([SchedulerBinding.instance.endOfFrame, cancellation.future]);
        if (!ownsTransition()) return;

        final compactRatio = currentVideoRatio;
        final sourceRectHint = _currentPipSourceRect(contentAspectRatio: compactRatio);
        final pipRatio = PortraitPresentationPolicy.resolveAndroidPipAspectRatio(
          width: (compactRatio * 10000).round(),
          height: 10000,
          portraitFallback: isVerticalVideo.value,
        );
        final rational = Rational(pipRatio.width, pipRatio.height);
        final statusRevision = _pipStatusRevision;
        final result = await Future.any<PiPStatus?>([
          floating.enable(ImmediatePiP(aspectRatio: rational, sourceRectHint: sourceRectHint)),
          cancellation.future.then((_) => null),
        ]);
        // A later native status event (including a system restore) outranks
        // the reply to our earlier request to enter PiP.
        if (ownsTransition() && statusRevision == _pipStatusRevision && result == PiPStatus.enabled) {
          _lastAppliedPipAspectRatio = pipRatio.value;
          isInPip.value = true;
          // Start every compact session with controls hidden; the fresh
          // MouseRegion re-asserts hover when the pointer is already inside.
          isHovered.value = false;
        }
      } finally {
        if (revision == _pipTransitionRevision) {
          isPipPreparing.value = false;
          _pipTransitionInFlight = false;
          _pipTransitionCancellation = null;
        }
      }
    } else if (_usesWindowsPip) {
      if (_pipTransitionInFlight ||
          _disposed ||
          _isClosing ||
          (_playbackIntentEstablished && !_playbackRequested) ||
          _currentPlayer == null ||
          !isInitialized.value) {
        return;
      }
      if (isInPip.value) return;
      final revision = ++_pipTransitionRevision;
      final sessionId = _sessionId;
      final player = _currentPlayer;
      bool ownsTransition() =>
          revision == _pipTransitionRevision && _isSessionValid(sessionId) && identical(player, _currentPlayer);
      _pipTransitionInFlight = true;
      isPipPreparing.value = true;
      try {
        await _windowsPipEnter(
          currentVideoRatio,
          videoWidth: videoGeometry.value.width,
          videoHeight: videoGeometry.value.height,
        );
        if (!ownsTransition()) {
          if (!_pipTransitionInFlight && !isInPip.value) {
            await _restoreWindowsMainWindow();
          }
          return;
        }
        isInPip.value = true;
        // Start every compact session with controls hidden; the fresh
        // MouseRegion re-asserts hover when the pointer is already inside.
        isHovered.value = false;
        // Seed the ephemeral pin toggle from the setting every time PiP opens;
        // in-session flips must not survive into the next PiP session.
        isPipAlwaysOnTop.value = SettingsService.to.player.windowsPipAlwaysOnTop.value;
      } finally {
        if (revision == _pipTransitionRevision) {
          _pipTransitionInFlight = false;
          isPipPreparing.value = false;
        }
      }
    }
  }

  math.Rectangle<int>? _currentPipSourceRect({required double contentAspectRatio}) {
    final context = _pipSourceKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final view = View.maybeOf(context!);
    if (view == null) return null;
    final origin = renderObject.localToGlobal(Offset.zero);
    final visibleRect = resolveContainedVideoRect(
      container: origin & renderObject.size,
      contentAspectRatio: contentAspectRatio,
    );
    final ratio = view.devicePixelRatio;
    final left = (visibleRect.left * ratio).round();
    final top = (visibleRect.top * ratio).round();
    final width = (visibleRect.width * ratio).round();
    final height = (visibleRect.height * ratio).round();
    if (width <= 0 || height <= 0) return null;
    return math.Rectangle<int>(left, top, width, height);
  }

  Future<void> exitPip() async {
    if (_usesWindowsPip) {
      if (_pipTransitionInFlight || _disposed || _isClosing || !isInPip.value) return;
      final revision = ++_pipTransitionRevision;
      final sessionId = _sessionId;
      final player = _currentPlayer;
      bool ownsTransition() =>
          revision == _pipTransitionRevision && _isSessionValid(sessionId) && identical(player, _currentPlayer);
      _pipTransitionInFlight = true;
      isPipPreparing.value = true;
      try {
        await _windowsPipExit();
        if (!ownsTransition()) return;
        isInPip.value = false;
        isHovered.value = false;
        // The compact-only mute is scoped to the mini window: returning to
        // the room restores the room's saved volume.
        await resetCompactMute();
      } catch (error) {
        if (error is WindowsPipExitFailure && !error.hostIsInPip && ownsTransition()) {
          isInPip.value = false;
          isHovered.value = false;
          await resetCompactMute();
        }
        rethrow;
      } finally {
        if (revision == _pipTransitionRevision) {
          _pipTransitionInFlight = false;
          isPipPreparing.value = false;
        }
      }
    }
  }

  Future<void> _exitPipFromControl() async {
    try {
      await exitPip();
    } catch (error, stackTrace) {
      log('Windows PiP exit failed', error: error, stackTrace: stackTrace);
      ToastUtil.show(i18n('windows_pip_exit_failed'));
    }
  }

  Future<void> _restoreWindowsMainWindow() async {
    try {
      await _windowsPipExit();
    } catch (error, stackTrace) {
      log('Windows PiP main-window restoration failed', error: error, stackTrace: stackTrace);
    }
  }

  void showAppFloating() {
    // A delayed show is scheduled after the room route pops. Re-entering a
    // room during that delay closes the prepared session and must prevent the
    // stale callback from mounting the old player on top of the new route.
    if (!_appFloatingPrepared || _floatingCleanup != null) return;
    isFloatingVideoVisible.value = true;
    floatingManager.disposeFloating(_floatTag);
    _hideTimer?.cancel();
    // 长边在 Obx 内部读取 floatingLongSide，确保 Ctrl+滚轮缩放时立即重建尺寸。
    // This selects Flutter interaction behavior, not a native platform API.
    final touchControls =
        defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

    void resetHideTimer() {
      if (touchControls) {
        _hideTimer?.cancel();
        _hideTimer = Timer(const Duration(seconds: 3), () {
          isHovered.value = false;
        });
      }
    }

    // 若有记忆的位置则按绝对坐标定位，否则沿用默认右上角偏移。
    final savedPos = floatingSavedPosition.value;
    final hasSavedPosition = savedPos != null && Platform.isWindows;

    isFloatingVideoVisible.value = true;
    floatingManager.createFloating(
      _floatTag,
      FloatingOverlay(
        MouseRegion(
          onEnter: (_) {
            if (!touchControls && (Platform.isWindows || Platform.isMacOS)) isHovered.value = true;
          },
          onExit: (_) {
            if (!touchControls && (Platform.isWindows || Platform.isMacOS)) isHovered.value = false;
          },
          child: Obx(() {
            // The overlay is created before late decoder/frame evidence may
            // settle. Keep its outer bounds on the same reactive geometry as
            // the texture instead of freezing the entry-time 16:9 size.
            videoPresentationRevision.value;
            // 在 Obx 内读取 floatingLongSide，Ctrl+滚轮缩放时立即生效。
            final maxSide = Platform.isWindows
                ? floatingLongSide.value.clamp(floatingMinLongSide, floatingMaxLongSide)
                : 220.0;
            final floatingSize = resolveAppFloatingSize(aspectRatio: currentVideoRatio, maxSide: maxSide);
            return Container(
              key: _appFloatingContainerKey,
              width: floatingSize.width,
              height: floatingSize.height,
              clipBehavior: Clip.antiAlias,
              // Windows 悬停时描边，提示边缘可拖拽改变尺寸。
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.black,
                border: Platform.isWindows && isHovered.value ? Border.all(color: Colors.white30, width: 1) : null,
              ),
              child: _wrapCompactWheel(
                Stack(
                  children: [
                    Obx(
                      () => Positioned.fill(
                        child: isFloatingVideoVisible.value
                            ? getVideoWidget(
                                SettingsService.to.player.videoFitIndex.v,
                                fitList: SettingsService.to.player.videoFitArray,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                    // 左上角弹幕显隐按钮的会话级开关：外层 Obx 读取该值，
                    // 隐藏时弹幕层直接不挂载。仅作用于 app 悬浮窗。
                    Positioned.fill(
                      child: isCompactDanmakuHidden.value ? const SizedBox.shrink() : _buildCompactDanmaku(),
                    ),
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          // Mobile overlays hide their controls after a short
                          // delay.  Previously the next tap immediately opened
                          // the room, so the close/pause controls could never be
                          // revealed again without racing the three-second
                          // timer.  Match native PiP behaviour: the first tap
                          // reveals controls; a second tap resumes the room.
                          if (touchControls && !isHovered.value) {
                            isHovered.value = true;
                            resetHideTimer();
                            return;
                          }
                          final room = currentFloatRoom;
                          if (room != null) {
                            await AppNavigator.toLiveRoomDetail(liveRoom: room);
                          }
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // Windows 边缘拖拽改变尺寸（手柄在子树中优先于外层悬浮窗
                    // 的整体拖动手势）；控制条与关闭按钮在更上层，事件不冲突。
                    ..._buildFloatingResizeHandles(),
                    _buildCompactPlaybackControls(afterAction: resetHideTimer),
                    _buildCompactOverlayChrome(),
                    // 左上角弹幕显隐按钮：仅 app 悬浮窗可见，会话临时态，
                    // 不持久化（与 compact 音量/静音一致）。位于 Stack 上层，
                    // 点击不会冒泡到单击进房手势。
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Obx(
                        () => AnimatedOpacity(
                          opacity: isHovered.value ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(
                            ignoring: !isHovered.value,
                            child: IconButton(
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.all(8),
                              style: IconButton.styleFrom(backgroundColor: Colors.black45),
                              tooltip: i18n('mini_pip_toggle_danmaku'),
                              icon: Icon(
                                isCompactDanmakuHidden.value ? Icons.subtitles_off_outlined : Icons.subtitles_outlined,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                isCompactDanmakuHidden.value = !isCompactDanmakuHidden.value;
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Obx(
                        () => AnimatedOpacity(
                          opacity: isHovered.value ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(
                            ignoring: !isHovered.value,
                            child: IconButton(
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.all(4),
                              style: IconButton.styleFrom(backgroundColor: Colors.black45),
                              icon: const Icon(Icons.close, color: Colors.white, size: 20),
                              onPressed: () async {
                                await stop();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
        slideType: hasSavedPosition ? FloatingEdgeType.onPoint : FloatingEdgeType.onRightAndTop,
        top: hasSavedPosition ? null : 100,
        right: hasSavedPosition ? null : 50,
        position: hasSavedPosition ? FPosition(savedPos.dx, savedPos.dy) : null,
        params: FloatingParams(isSnapToEdge: false, snapToEdgeSpace: 10, dragOpacity: 0.8),
      ),
    );
    final overlay = floatingManager.getFloating(_floatTag);
    // 拖拽结束时记忆位置（仅 Windows，运行时不落盘）。
    if (Platform.isWindows) {
      overlay.addFloatingListener(
        FloatingEventListener()
          ..moveEndListener = (pos) {
            floatingSavedPosition.value = Offset(pos.x, pos.y);
          },
      );
    }
    final overlayContext = Get.overlayContext;
    if (overlayContext != null) {
      overlay.open(overlayContext);
    }
    if (overlayContext == null || !overlay.isShowing) {
      // Never keep decoding an invisible floating session. This also releases
      // the popped route's controllers when the target Overlay disappeared
      // during navigation.
      isFloating.value = false;
      unawaited(closeAppFloating().then((_) => close()));
      return;
    }
    isFloating.value = true;
    unawaited(_floatingPopupSubscription?.cancel());
    _floatingPopupSubscription = hideFloatingWhilePopupsOpen(overlay);
    if (touchControls) {
      isHovered.value = true;
      resetHideTimer();
    } else {
      // Desktop: never inherit hover state from a previous compact session.
      // The freshly mounted MouseRegion re-asserts it when the pointer is
      // already over the floating window.
      isHovered.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // App floating：Windows 边缘/四角拖拽改变尺寸
  //
  // flutter_floating 只支持整体拖动，不支持边缘 resize。这里在悬浮窗
  // Stack 内放置 4 条边 + 4 个角的手势手柄：命中测试中前层子节点的手势
  // 优先于 FloatingView 外层的整体拖动手势，因此手柄区域拖动会调整尺寸，
  // 其余区域仍是移动窗口。尺寸通过 floatingLongSide 驱动同一套 Obx 布局，
  // 并用 FloatingCommonController.setWAndH/scrollTopLeft 提前通知插件，
  // 锚定被拖拽边的对边，避免缩放时窗口跳动。
  // ---------------------------------------------------------------------------

  List<Widget> _buildFloatingResizeHandles() {
    if (!Platform.isWindows) return const <Widget>[];
    const double band = 6.0;
    const double corner = 12.0;
    return <Widget>[
      _resizeHandle(
        edge: _FloatingResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
        left: 0,
        top: corner,
        bottom: corner,
        width: band,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
        right: 0,
        top: corner,
        bottom: corner,
        width: band,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
        top: 0,
        left: corner,
        right: corner,
        height: band,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
        bottom: 0,
        left: corner,
        right: corner,
        height: band,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        left: 0,
        top: 0,
        width: corner,
        height: corner,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        right: 0,
        top: 0,
        width: corner,
        height: corner,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        left: 0,
        bottom: 0,
        width: corner,
        height: corner,
      ),
      _resizeHandle(
        edge: _FloatingResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        right: 0,
        bottom: 0,
        width: corner,
        height: corner,
      ),
    ];
  }

  Widget _resizeHandle({
    required _FloatingResizeEdge edge,
    required MouseCursor cursor,
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      child: Obx(
        () => IgnorePointer(
          ignoring: !isHovered.value,
          child: AnimatedOpacity(
            opacity: isHovered.value ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: MouseRegion(
              cursor: cursor,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) => _beginFloatingResize(edge, details),
                onPanUpdate: _updateFloatingResize,
                onPanEnd: (_) => _endFloatingResize(),
                onPanCancel: _endFloatingResize,
                child: SizedBox(width: width, height: height),
              ),
            ),
          ),
        ),
      ),
    );
  }

  FloatingCommonController? get _floatingOverlayController {
    if (!floatingManager.containsFloating(_floatTag)) return null;
    return floatingManager.getFloating(_floatTag).controller;
  }

  void _beginFloatingResize(_FloatingResizeEdge edge, DragStartDetails details) {
    final context = _appFloatingContainerKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (context == null || renderObject is! RenderBox) return;
    // flutter_floating 的定位命令（fx/fy、parentW/parentH、各 scroll* 的
    // inset）全部相对它内部承载悬浮窗的 Stack。该 Stack 位于 Overlay 中，
    // 在 Windows 上其上方可能还有自定义标题栏等区域，因此它与窗口根坐标
    // 之间存在恒定偏移（实测 Y=32）。若直接把 localToGlobal 的全局坐标
    // 当作 fx/fy/top inset 下发，凡涉及“顶边绝对定位”的方向都会把窗口
    // 向下顶出该偏移量（表现为拖非上边缘整体下移）。
    // 故起始矩形与“屏幕尺寸”一律换算成插件 Stack 自己的坐标系。
    final stackBox = context.findAncestorRenderObjectOfType<RenderStack>();
    if (stackBox == null) return;
    final stackOrigin = stackBox.localToGlobal(Offset.zero);
    final origin = renderObject.localToGlobal(Offset.zero) - stackOrigin;
    final session = _FloatingResizeSession(
      edge: edge,
      startRect: origin & renderObject.size,
      startLongSide: floatingLongSide.value,
      screenSize: stackBox.size,
    );
    session.targetX = origin.dx;
    session.targetY = origin.dy;
    session.targetWidth = renderObject.size.width;
    session.targetHeight = renderObject.size.height;
    _floatingResizeSession = session;
    // 拖拽过程中窗口立即跟随，不做位移动画。
    _floatingOverlayController?.scrollTime(0);
    // 插件在收到 setWAndH 后，其 sizeChange 会按“贴边/屏幕中线”启发式
    // 自行挪动窗口；在窗口位于屏幕下半部时它会保底边，与我们要的“锚定
    // 被拖拽边的对边”相冲突。每帧绘制结束后按会话目标位置再钉一次锚点
    // （命令 FIFO，晚于插件启发式生效），保证下一帧位置始终正确且误差
    // 不会逐帧累积。
    _scheduleFloatingResizeFrameGuard();
  }

  void _updateFloatingResize(DragUpdateDetails details) {
    final session = _floatingResizeSession;
    if (session == null || session.finalizing) return;
    session.accumulatedDx += details.delta.dx;
    session.accumulatedDy += details.delta.dy;

    final edge = session.edge;
    final start = session.startRect;
    var w = start.width;
    var h = start.height;
    if (edge.affectsLeft) {
      w = start.width - session.accumulatedDx;
    }
    if (edge.affectsRight) w = start.width + session.accumulatedDx;
    if (edge.affectsTop) {
      h = start.height - session.accumulatedDy;
    }
    if (edge.affectsBottom) h = start.height + session.accumulatedDy;

    // 沿长边等比缩放，宽高比始终与视频一致。
    final sx = start.width <= 0 ? 1.0 : w / start.width;
    final sy = start.height <= 0 ? 1.0 : h / start.height;
    final double scale;
    if (edge.affectsHorizontal && edge.affectsVertical) {
      scale = (sx + sy) / 2;
    } else if (edge.affectsHorizontal) {
      scale = sx;
    } else {
      scale = sy;
    }
    final longSide = (session.startLongSide * scale).clamp(floatingMinLongSide, floatingMaxLongSide).toDouble();
    final newSize = resolveAppFloatingSize(aspectRatio: currentVideoRatio, maxSide: longSide);

    // 锚定被拖拽边的对边/对角：拖左边/上边时反向修正左上角坐标。
    var nx = start.left;
    var ny = start.top;
    if (edge.affectsLeft) nx = start.right - newSize.width;
    if (edge.affectsTop) ny = start.bottom - newSize.height;

    // 限制在插件父容器范围内，避免窗口被拖出可视区域。
    const double margin = 10.0;
    final maxX = math.max(margin, session.screenSize.width - margin - newSize.width);
    final maxY = math.max(margin, session.screenSize.height - margin - newSize.height);
    nx = nx.clamp(margin, maxX).toDouble();
    ny = ny.clamp(margin, maxY).toDouble();

    session.targetX = nx;
    session.targetY = ny;
    session.targetWidth = newSize.width;
    session.targetHeight = newSize.height;

    final controller = _floatingOverlayController;
    // setWAndH 先把插件内部尺寸改成目标值（避免旧尺寸撑一帧闪烁），
    // 紧接着按拖拽方向下发对边锚点命令，命令按 FIFO 顺序执行。
    controller?.setWAndH(newSize.width, newSize.height);
    _sendFloatingAnchor(controller, session);
    // 与插件坐标系一致（moveEndListener 同样保存插件坐标），避免开窗位置
    // 被全局坐标污染后逐次下移。
    floatingSavedPosition.value = Offset(nx, ny);
    floatingLongSide.value = longSide;
  }

  /// 下发锚点定位命令。
  ///
  /// 所有 inset 均处于**插件 Stack 坐标系**（见 [_beginFloatingResize]）：
  /// 起始矩形与父尺寸都相对插件内部 Stack，不能使用窗口全局坐标，否则
  /// 标题栏等偏移会直接变成顶边定位误差。
  ///
  /// 锚点 inset 只能由会话起始矩形 [_FloatingResizeSession.startRect]
  /// 与插件父尺寸这些**常量**推导，不携带外部算出的新尺寸：插件执行
  /// scrollBottom*/scrollTopRight 时用它内部实测的
  /// `_fWidth/_fHeight/_parentWidth/_parentHeight` 换算，外部
  /// resolveAppFloatingSize 的尺寸与 MeasureSize 实测值若有偏差 Δ，
  /// 用“被拖拽边的对边与父边缘的恒定间距”可让 Δ 在插件内部闭环抵消。
  ///
  /// 方向映射（拖动的边 → 保持不动的对边）：
  /// - 右/下/右下角：保持上、左边 -> scrollTopLeft
  /// - 左/左下角：保持上、右边 -> scrollTopRight
  /// - 上边：保持下、左边 -> scrollBottomLeft
  /// - 左上：保持下、右边 -> scrollBottomRight
  /// - 右上：保持下、左边 -> scrollBottomLeft
  void _sendFloatingAnchor(FloatingCommonController? controller, _FloatingResizeSession session) {
    if (controller == null) return;
    final start = session.startRect;
    final screenW = session.screenSize.width;
    final screenH = session.screenSize.height;
    final edge = session.edge;

    // 四条“固定边”相对插件父边缘的恒定间距。
    final leftInset = start.left;
    final topInset = start.top;
    final rightInset = screenW - start.right;
    final bottomInset = screenH - start.bottom;

    // 越界保护：按目标尺寸估算插件将要渲染的左上角。正常缩放时固定边
    // 本就在范围内（起始位置合法），这里只在窗口贴边放大到超出对侧边缘
    // 时生效，退回绝对定位（极限场景，容忍 Δ）。
    const margin = 10.0;
    final w = session.targetWidth;
    final h = session.targetHeight;
    final predictedX = edge.affectsLeft ? screenW - rightInset - w : leftInset;
    final predictedY = edge.affectsTop ? screenH - bottomInset - h : topInset;
    final maxX = math.max(margin, screenW - margin - w);
    final maxY = math.max(margin, screenH - margin - h);
    final clampedX = predictedX.clamp(margin, maxX).toDouble();
    final clampedY = predictedY.clamp(margin, maxY).toDouble();
    if (clampedX != predictedX || clampedY != predictedY) {
      controller.scrollTopLeft(clampedY, clampedX);
      return;
    }

    if (edge.affectsTop && edge.affectsLeft) {
      controller.scrollBottomRight(bottomInset, rightInset);
    } else if (edge.affectsTop) {
      controller.scrollBottomLeft(bottomInset, leftInset);
    } else if (edge.affectsLeft) {
      controller.scrollTopRight(topInset, rightInset);
    } else {
      controller.scrollTopLeft(topInset, leftInset);
    }
  }

  /// 每帧绘制完成后重钉一次锚点，抵消插件尺寸变化启发式造成的位置漂移。
  void _scheduleFloatingResizeFrameGuard() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final session = _floatingResizeSession;
      if (session == null || session.finalizing) return;
      final controller = _floatingOverlayController;
      // 悬浮窗可能在拖拽过程中被关闭：没有控制器就终止整个校正链。
      if (controller == null) {
        _floatingResizeSession = null;
        return;
      }
      _sendFloatingAnchor(controller, session);
      _scheduleFloatingResizeFrameGuard();
    });
  }

  void _endFloatingResize() {
    final session = _floatingResizeSession;
    final controller = _floatingOverlayController;
    if (session == null) {
      controller?.scrollTime(300);
      return;
    }
    session.finalizing = true;
    // 终态再钉一次锚点；并在下一帧布局（含插件最后一次 sizeChange 回调）
    // 完成后补一次校正，随后再恢复 300ms 动画时长——命令 FIFO 保证校正
    // 仍以 scrollTime=0 瞬时生效，不会播放位移动画。
    _sendFloatingAnchor(controller, session);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final currentSession = _floatingResizeSession;
      final currentController = _floatingOverlayController;
      if (currentSession != null) {
        _sendFloatingAnchor(currentController, currentSession);
      }
      currentController?.scrollTime(300);
      _floatingResizeSession = null;
      // 以插件内部实测位置回写，避免外部几何计算与插件实测尺寸的偏差
      // 污染下次开窗位置。
      if (currentController != null) {
        unawaited(
          currentController
              .currentPosition()
              .then((position) {
                if (position != null) {
                  floatingSavedPosition.value = Offset(position.x, position.y);
                }
              })
              .catchError((_) => null),
        );
      }
    });
  }

  Future<void> closeAppFloating() async {
    _hideTimer?.cancel();
    _hideTimer = null;
    isHovered.value = false;
    // 悬浮窗即将移除：终止边缘缩放会话，帧末校正回调会随之停止，
    // 避免控制器销毁后回调仍在逐帧重排。
    _floatingResizeSession = null;
    unawaited(_floatingPopupSubscription?.cancel());
    _floatingPopupSubscription = null;
    final cleanupInFlight = _floatingCleanup;
    if (cleanupInFlight != null) {
      await cleanupInFlight;
      return;
    }
    if (!_appFloatingPrepared &&
        !isFloating.value &&
        _floatingResourceDisposers.isEmpty &&
        !floatingManager.containsFloating(_floatTag)) {
      return;
    }

    late final Future<void> cleanup;
    cleanup = () async {
      final hadOverlay = floatingManager.containsFloating(_floatTag);
      if (hadOverlay) {
        isFloatingVideoVisible.value = false;
        // Hiding the native view normally takes one frame, but Android can
        // stop producing vsync while the app backgrounds. Use the same bounded
        // fence as the later unmount step so cleanup cannot retain a decoder,
        // Surface and route subscriptions forever before it removes the
        // overlay.
        await _awaitBoundedWidgetUnmount();
        // OverlayEntry.remove() schedules unmount for the next frame. Calling
        // disposeFloating here would also dispose its controllers while the
        // FloatingView is still subscribed to them.
        floatingManager.getFloating(_floatTag).close();
      }
      isFloating.value = false;
      // Cancel a delayed showAppFloating callback immediately.
      _appFloatingPrepared = false;

      // The popped live route and its overlay can both still be in Flutter's
      // inactive element list. Let their Obx/StreamBuilder widgets unsubscribe
      // before closing the old room's Rx values and player controllers.
      await _awaitBoundedWidgetUnmount();

      if (hadOverlay && floatingManager.containsFloating(_floatTag)) {
        floatingManager.disposeFloating(_floatTag);
      }
      await _releaseAppFloatingResources();
      if (_pendingRoomReentry == null) {
        _appFloatingSession = null;
      }
      if (!isInPip.value) {
        _videoController?.clearPipDanmaku();
        // Both "tap to re-enter the room" and "close" finish here: drop the
        // compact-only mute and restore the room's saved volume.
        await resetCompactMute();
      }
    }();
    _floatingCleanup = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_floatingCleanup, cleanup)) _floatingCleanup = null;
    }
  }

  /// Fixed width of the compact volume track. The pill shrink-wraps its Row,
  /// so pointer ratios must be derived from this constant, not layout
  /// constraints (which are unbounded under MainAxisSize.min).
  static const double _compactVolumeTrackWidth = 124;

  /// Currently effective compact volume: the session override while one
  /// exists, otherwise the room's saved volume.
  double _compactVolumeValue() => _compactVolumeOverride ?? _savedRoomVolume();

  /// Centered play/pause + horizontal volume control shared by the Windows
  /// PiP overlay and the in-app floating window. Both fade in with the hover
  /// mask. [afterAction] is used by touch overlays to reset the auto-hide
  /// timer after an interaction.
  Widget _buildCompactPlaybackControls({VoidCallback? afterAction}) {
    // Keep the same footprint as the corner buttons (PiP pin / close):
    // default 24 px icon + 8 px padding => a 40 x 40 hit target.
    Widget pauseButton() {
      return StreamBuilder<bool>(
        stream: onPlaying,
        initialData: isPlayingNow,
        builder: (context, snapshot) {
          final isPlay = snapshot.data ?? true;
          return IconButton(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
            icon: Icon(isPlay ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white),
            onPressed: () {
              unawaited(togglePlayPause());
              afterAction?.call();
            },
          );
        },
      );
    }

    return Center(
      child: Obx(() {
        // Rebuild the volume pill whenever the preview/mute state changes.
        compactVolumePreview.value;
        isCompactMuted.value;
        return AnimatedOpacity(
          opacity: isHovered.value ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !isHovered.value,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pauseButton(),
                const SizedBox(width: 10),
                _buildCompactVolumeControl(afterAction: afterAction),
              ],
            ),
          ),
        );
      }),
    );
  }

  /// Horizontal volume pill: mute-toggle icon, draggable/clickable track and
  /// percentage. Styled after the full-player wheel volume OSD.
  Widget _buildCompactVolumeControl({VoidCallback? afterAction}) {
    final volume = _compactVolumeValue();
    final muted = volume <= 0.001;
    final icon = muted ? Icons.volume_off : (volume < 0.5 ? Icons.volume_down : Icons.volume_up);

    return GestureDetector(
      // Absorb competing gestures so interacting with the pill never falls
      // through to the video layer (floating tap-to-open / PiP double-tap
      // exit / window drag). The inner IconButton still wins taps on the
      // icon because child recognizers take the arena first.
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      onDoubleTap: () {},
      onHorizontalDragStart: (_) => afterAction?.call(),
      onHorizontalDragUpdate: (_) {},
      onHorizontalDragEnd: (_) {},
      onVerticalDragStart: (_) {},
      onVerticalDragUpdate: (_) {},
      onVerticalDragEnd: (_) {},
      child: Container(
        height: 40,
        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.only(left: 2, right: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(7),
              iconSize: 22,
              tooltip: i18n(muted ? 'cancel_mute' : 'mute'),
              icon: Icon(icon, color: Colors.white),
              onPressed: () {
                unawaited(toggleCompactMute());
                afterAction?.call();
              },
            ),
            _buildCompactVolumeTrack(volume, afterAction),
            const SizedBox(width: 8),
            Text(
              '${(volume * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactVolumeTrack(double volume, VoidCallback? afterAction) {
    void updateFromPosition(double dx) {
      final ratio = (dx / _compactVolumeTrackWidth).clamp(0.0, 1.0).toDouble();
      unawaited(setCompactVolumeDirect(ratio));
      afterAction?.call();
    }

    final clamped = volume.clamp(0.0, 1.0).toDouble();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => updateFromPosition(event.localPosition.dx),
        onPointerMove: (event) {
          if (event.buttons != 0) updateFromPosition(event.localPosition.dx);
        },
        child: SizedBox(
          width: _compactVolumeTrackWidth,
          height: 20,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: clamped,
                  minHeight: 5,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              Positioned(
                left: (clamped * _compactVolumeTrackWidth - 6).clamp(0.0, _compactVolumeTrackWidth - 12),
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black26),
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mouse wheel adjusts the ephemeral compact volume over the whole mini
  /// window surface (video, danmaku and empty areas all forward wheel events).
  Widget _wrapCompactWheel(Widget child) {
    return Builder(
      builder: (context) => Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
          // Ctrl + 滚轮：固定比例缩放窗口（仅 app floating；Windows PiP 已
          // 移除此快捷键，统一使用拖拽边缘按比例缩放）。
          if (HardwareKeyboard.instance.isControlPressed) {
            unawaited(_adjustCompactSizeByWheel(event.scrollDelta.dy));
            return;
          }
          // 普通滚轮：调节音量（原有行为）。
          unawaited(adjustCompactVolumeByWheel(event.scrollDelta.dy));
        },
        // While a button is held (e.g. dragging the volume track), Flutter
        // desktop does not update MouseRegion hover state, so a drag that
        // ends outside the window never delivers onExit and the controls get
        // stuck visible. Re-check the pointer position on release and force
        // the hover state off when it is already outside the mini window.
        onPointerUp: (event) => _compactReleaseHoverGuard(context, event.position),
        onPointerCancel: (event) => _compactReleaseHoverGuard(context, event.position),
        child: child,
      ),
    );
  }

  /// Ctrl+滚轮固定比例缩放紧凑窗口（仅 app floating）。
  /// Windows PiP 不再响应此快捷键：拖拽窗口边缘即可按锁定的画面比例缩放。
  /// - app floating：先向 flutter_floating 下发 setWAndH（插件会在同一帧
  ///   布局前完成尺寸与位置调整），再更新 [floatingLongSide] 触发 Obx 重建，
  ///   避免“新尺寸先在旧位置渲染一帧、下一帧才跳位”的卡顿。
  /// 步进取 14（鼠标一格约 100px delta），并按滚轮 delta 大小线性缩放，
  /// 触控板的小幅度平滑滚动因此更连续、跟手。
  Future<void> _adjustCompactSizeByWheel(double scrollDy) async {
    if (!Platform.isWindows || scrollDy == 0) return;
    // Windows PiP 模式下忽略 Ctrl+滚轮缩放，仅保留 app floating 的缩放。
    if (isInPip.value) return;
    const baseStep = 14.0;
    final factor = (scrollDy.abs() / 100.0).clamp(0.15, 2.0);
    final delta = -scrollDy.sign * baseStep * factor; // 向上滚放大，向下滚缩小

    final controller = _floatingOverlayController;
    final next = (floatingLongSide.value + delta).clamp(floatingMinLongSide, floatingMaxLongSide).toDouble();
    if ((next - floatingLongSide.value).abs() < 0.01) return;
    final newSize = resolveAppFloatingSize(aspectRatio: currentVideoRatio, maxSide: next);
    if (controller != null) {
      // 关键顺序：先通知插件新尺寸（插件内部按所在屏幕区域锚定位置），
      // 再让 Obx 重建子树，尺寸与位置在同一帧内生效。
      controller.setWAndH(newSize.width, newSize.height);
      floatingLongSide.value = next;
      // 记录插件启发式调整后的真实位置，供下次打开悬浮窗使用（否则旧位置
      // 配新尺寸可能让窗口超出屏幕右边/底边）。边缘拖拽会话进行中不干预。
      if (_floatingResizeSession == null) {
        try {
          final position = await controller.currentPosition();
          if (position != null && _floatingResizeSession == null) {
            floatingSavedPosition.value = Offset(position.x, position.y);
          }
        } catch (_) {
          // 读取位置失败不影响缩放本身。
        }
      }
    } else {
      floatingLongSide.value = next;
    }
  }

  void _compactReleaseHoverGuard(BuildContext context, Offset globalPosition) {
    if (!(Platform.isWindows || Platform.isMacOS)) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || box.size.isEmpty) return;
    final local = box.globalToLocal(globalPosition);
    final inside = local.dx >= 0 && local.dy >= 0 && local.dx <= box.size.width && local.dy <= box.size.height;
    if (!inside) isHovered.value = false;
  }

  /// Hover chrome shared by both compact windows: the platform logo and the
  /// streamer name fade in with the other controls.
  Widget _buildCompactOverlayChrome() {
    return Positioned(
      left: 8,
      right: 8,
      top: 8,
      child: Obx(
        () => AnimatedOpacity(
          opacity: isHovered.value ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            child: Row(
              children: [
                // Leave room for the PiP pin / floating close buttons.
                const SizedBox(width: 44),
                Expanded(
                  child: Align(alignment: Alignment.topCenter, child: _buildCompactRoomLabel()),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactRoomLabel() {
    final room = currentFloatRoom;
    var name = '';
    if (room != null) {
      final nick = room.nick?.trim() ?? '';
      final title = room.title?.trim() ?? '';
      name = nick.isNotEmpty ? nick : title;
    }
    if (name.isEmpty) return const SizedBox.shrink();
    final platform = room?.platform;
    final logo = platform != null ? Sites.logoOf(platform) : null;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (logo != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Image.asset(
                  logo,
                  width: 18,
                  height: 18,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPiPOverlay() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: MouseRegion(
        onEnter: (_) => isHovered.value = true,
        onExit: (_) => isHovered.value = false,
        child: _wrapCompactWheel(
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: const BoxDecoration(color: Colors.black),
            child: Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  onDoubleTap: isPipPreparing.value ? null : _exitPipFromControl,
                  child: Obx(
                    () => getVideoWidget(
                      0,
                      // Windows PiP 窗口保留 resize 边框，客户区比例与视频存在
                      // sub-pixel 偏差，BoxFit.contain 会出现细黑边。悬浮窗因
                      // 无边框故无此问题。这里对 contain 改用 cover，裁剪量 <1px
                      // 肉眼不可见，保证 PiP 画面铺满无黑边；用户显式选择的
                      // cover/fill 保持不变。
                      fitList: [
                        () {
                          final fit =
                              SettingsService.to.player.videoFitArray[SettingsService.to.player.resolvedVideoFitIndex];
                          return fit == BoxFit.contain ? BoxFit.cover : fit;
                        }(),
                      ],
                      trackPipSource: true,
                    ),
                  ),
                ),
                Positioned.fill(child: _buildCompactDanmaku()),
                _buildCompactPlaybackControls(),
                _buildCompactOverlayChrome(),
                // Windows only: live topmost toggle for the mini window. It is
                // seeded from the setting on PiP entry and is not persisted.
                if (_usesWindowsPip)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Obx(
                      () => AnimatedOpacity(
                        opacity: isHovered.value ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: IgnorePointer(
                          ignoring: !isHovered.value,
                          child: IconButton(
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.all(8),
                            style: IconButton.styleFrom(backgroundColor: Colors.black45),
                            tooltip: i18n(isPipAlwaysOnTop.value ? 'pip_cancel_always_on_top' : 'pip_always_on_top'),
                            icon: Icon(
                              isPipAlwaysOnTop.value ? Icons.push_pin : Icons.push_pin_outlined,
                              color: Colors.white,
                            ),
                            onPressed: isPipPreparing.value ? null : () => unawaited(toggleWindowsPipAlwaysOnTop()),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Obx(
                    () => AnimatedOpacity(
                      opacity: isHovered.value ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: isPipPreparing.value ? null : _exitPipFromControl,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildAudioOnlyUI(BuildContext context, LiveRoom? detail) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        final compact = maxHeight < 500;
        final avatarSize = compact ? (maxHeight * 0.22).clamp(50.0, 76.0) : 100.0;
        final titleSize = compact ? 14.0 : 22.0;
        final nickSize = compact ? 11.0 : 13.0;
        final badgeTextSize = compact ? 11.0 : 13.0;
        final gapLarge = compact ? 10.0 : 24.0;
        final gapMedium = compact ? 8.0 : 16.0;
        final gapSmall = compact ? 4.0 : 8.0;

        final avatar = detail?.avatar ?? '';
        final title = detail?.title ?? '';
        final nick = detail?.nick ?? '';

        final background = avatar.isEmpty
            ? const SizedBox.expand()
            : Positioned.fill(
                child: Opacity(
                  opacity: 0.22,
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.mode(Color(0xFF273047), BlendMode.modulate),
                    child: Image.network(avatar, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.expand()),
                  ),
                ),
              );

        return Stack(
          fit: StackFit.expand,
          children: [
            background,
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xE8121827), Color(0xF20B0E16), Color(0xF0151020)],
                ),
              ),
            ),
            Container(
              width: maxWidth,
              height: maxHeight,
              alignment: Alignment.center,
              child: SingleChildScrollView(
                physics: compact ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24, vertical: compact ? 4 : 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? maxWidth : 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.95, end: 1.05),
                        duration: const Duration(milliseconds: 1500),
                        curve: Curves.easeInOut,
                        builder: (context, scale, child) {
                          return Transform.scale(scale: scale, child: child);
                        },
                        child: Container(
                          width: avatarSize,
                          height: avatarSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.04),
                                blurRadius: compact ? 10 : 20,
                                spreadRadius: compact ? 4 : 8,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: avatar.isNotEmpty
                                ? Image.network(
                                    avatar,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) =>
                                        const Icon(Remix.user_3_line, color: Colors.white24),
                                  )
                                : const Icon(Remix.user_3_line, color: Colors.white24),
                          ),
                        ),
                      ),
                      SizedBox(height: gapLarge),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 24),
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: compact ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: titleSize,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      SizedBox(height: gapSmall),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 14, vertical: compact ? 2 : 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        child: Text(
                          nick,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: nickSize,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      SizedBox(height: gapMedium),
                      Obx(() {
                        final restoring = isVideoRestorePending.value;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: compact ? 5 : 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(30),
                            color: restoring
                                ? const Color(0xFF5B67F1).withValues(alpha: 0.28)
                                : Colors.white.withValues(alpha: 0.08),
                            border: Border.all(
                              color: restoring
                                  ? const Color(0xFF8B94FF).withValues(alpha: 0.62)
                                  : Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: Row(
                              key: ValueKey<bool>(restoring),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (restoring)
                                  SizedBox.square(
                                    dimension: compact ? 12 : 15,
                                    child: const CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white),
                                  )
                                else
                                  Icon(
                                    Remix.headphone_line,
                                    color: Colors.white.withValues(alpha: 0.85),
                                    size: compact ? 12 : 16,
                                  ),
                                SizedBox(width: compact ? 4 : 8),
                                Text(
                                  i18n(restoring ? "restoring_live_video" : "audio_only_mode"),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: badgeTextSize,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget getVideoWidget(
    int fitIndex, {
    Widget? controls,
    required List<BoxFit> fitList,
    bool trackPipSource = false,
    bool? audioOnlyOverride,
    Color surfaceColor = Colors.black,
    double? videoViewportAspectRatio,
    PortraitFullscreenDisplayMode? portraitFullscreenDisplayMode,
  }) {
    // Floating/PiP callers already wrap this factory in Obx; keep their
    // dependency registered while the inner observer covers direct callers.
    videoPresentationRevision.value;
    return Obx(() {
      // Runtime audio-only state is intentionally non-reactive because native
      // mode changes are serialized. The revision publishes only the final
      // presentation state while preserving the same texture/surface element.
      videoPresentationRevision.value;
      final initialized = isInitialized.value;
      final showAudioOnly = audioOnlyOverride ?? _runtimeAudioOnly;
      final player = _currentPlayer;

      if (!initialized || _disposed || _isClosing || player == null) {
        return _buildPlaceholder(surfaceColor: surfaceColor);
      }
      final safeFitIndex = fitList.isEmpty ? 0 : fitIndex.clamp(0, fitList.length - 1);
      final boxFit = fitList.isEmpty ? BoxFit.contain : fitList[safeFitIndex];
      return RepaintBoundary(
        key: trackPipSource ? _pipSourceKey : null,
        child: PureLivePipWidget(
          child: Container(
            color: surfaceColor,
            padding: EdgeInsets.zero,
            child: KeyedSubtree(
              key: videoKey.value,
              child: Container(
                color: surfaceColor,
                width: double.infinity,
                height: double.infinity,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Offstage(
                        offstage: showAudioOnly,
                        child: Container(
                          color: surfaceColor,
                          child: buildPresentationVideoViewport(
                            aspectRatio: videoViewportAspectRatio,
                            mode: portraitFullscreenDisplayMode,
                            child: _buildVideoWidget(
                              player,
                              portraitFullscreenDisplayMode == PortraitFullscreenDisplayMode.cover
                                  ? BoxFit.cover
                                  : boxFit,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showAudioOnly)
                      Positioned.fill(
                        child: Builder(builder: (context) => buildAudioOnlyUI(context, currentFloatRoom)),
                      ),
                    if (controls != null) Positioned.fill(child: controls),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildVideoWidget(UnifiedPlayer player, BoxFit boxFit) {
    if (!PlatformUtils.isMobile) {
      // Desktop adapters retain their native aspect and visible-viewport
      // policies, including the bounded Windows texture implementation.
      return player.getVideoWidget(fit: boxFit);
    }

    // The native player is the only fit owner for ordinary frames. media_kit,
    // FijkPlayer and BetterPlayer already size their texture/surface from the
    // decoded frame. Wrapping that view in another aspect-ratio FittedBox made
    // a transient 16:9 manager snapshot multiply with the native 9:16 fit and
    // produced the persistent narrow-strip portrait regression.
    final geometry = currentPresentationGeometry;
    return buildUnifiedMobileVideoPresentation(
      aspectRatio: geometry.contentAspectRatio,
      encodedAspectRatio: geometry.canvasAspectRatio,
      contentInsets: geometry.contentInsets,
      fit: boxFit,
      nativeVideoBuilder: (nativeFit) => player.getVideoWidget(fit: nativeFit),
    );
  }

  Widget _buildPlaceholder({Color surfaceColor = Colors.black}) {
    return Container(
      color: surfaceColor,
      child: AppStatusView(type: AppStatusType.loading, title: "", subtitle: "", iconColor: Colors.white, isMini: true),
    );
  }

  Future<void> close() {
    if (_disposed) return Future<void>.value();
    final restoreWindowsWindow = _usesWindowsPip && isInPip.value;
    _cancelPipTransition();
    _stopAndroidPipObservation();
    if (_usesAndroidPip || restoreWindowsWindow) isInPip.value = false;
    // Compact-only controls never outlive the playback session.
    isCompactMuted.value = false;
    isCompactDanmakuHidden.value = false;
    isPipAlwaysOnTop.value = false;
    // Intent changes belong to dispatch, not native teardown. A pending source
    // open/recovery must lose ownership as soon as close is requested. Waiting
    // for the lifecycle queue used to let it become audible first, and a later
    // close callback could overwrite a newer play() already in the queue.
    _cancelIdlePlayerRelease();
    _playbackRequested = false;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _sessionId++;
    _clearSourceCommitState();
    _cancelPendingSourceInputs();
    _playbackSuspensions.clear();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    return _enqueuePlayerLifecycle(() async {
      if (restoreWindowsWindow) {
        await _restoreWindowsMainWindow();
      }
      await _closeInternal();
    });
  }

  Future<void> _closeInternal() async {
    if (_disposed) return;
    _cancelIdlePlayerRelease();
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    _audioModeVideoWarmTimer?.cancel();
    _audioModeVideoWarmTimer = null;
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    _proactiveSourceRefreshTimer?.cancel();
    _proactiveSourceRefreshTimer = null;
    _currentSourceRefreshAt = null;
    _sourceRefreshResolver = null;
    _sourceRefreshAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _prefetchedSourceRefresh = null;
    _pendingRoomReentry = null;
    _appFloatingSession = null;
    _clearSourceCommitState();
    _isClosing = true;
    _sourceOpened = false;
    isVideoRestorePending.value = false;
    // Let route/overlay widgets release their listeners before native teardown,
    // but keep the fence bounded. endOfFrame stays pending when close is called
    // while no frame is scheduled (background, tests, shutdown), which would
    // otherwise leave close/play serialized behind a Future that never ends.
    await _awaitBoundedWidgetUnmount();
    try {
      await LiveAudioService.stop();
      if (_useHardStopOnExit()) {
        await _hardDisposeInternal();
      } else {
        await softStop();
        _scheduleIdlePlayerRelease();
      }
    } finally {
      _isClosing = false;
    }
  }

  void _cancelIdlePlayerRelease() {
    _idlePlayerReleaseTimer?.cancel();
    _idlePlayerReleaseTimer = null;
  }

  void _scheduleIdlePlayerRelease() {
    _cancelIdlePlayerRelease();
    if (_disposed || _currentPlayer == null) return;

    final closedSessionId = _sessionId;
    if (idlePlayerReleaseDelay <= Duration.zero) {
      unawaited(_releaseIdlePlayer(closedSessionId));
      return;
    }

    _idlePlayerReleaseTimer = Timer(idlePlayerReleaseDelay, () {
      _idlePlayerReleaseTimer = null;
      unawaited(_releaseIdlePlayer(closedSessionId));
    });
  }

  Future<void> _releaseIdlePlayer(int closedSessionId) {
    return _enqueuePlayerLifecycle(() async {
      if (_disposed ||
          _isClosing ||
          _playbackRequested ||
          _sessionId != closedSessionId ||
          isCompactModeActive ||
          isAppFloatingActive) {
        return;
      }
      await _hardDisposeInternal();
    });
  }

  Future<void> softStop() async {
    lineManager.reset();
    try {
      if (_stateSubject.value == PlayerState.error) {
        await _hardDisposeInternal();
        return;
      }
      await _disposeWindowsWarmStandby();
      final player = _currentPlayer;
      await player?.softStop();
      if (player != null) await _closeSourceTransport(player);
      _stateSubject.add(PlayerState.idle);
      _playingSubject.add(false);
    } catch (e) {
      await _hardDisposeInternal();
    }
  }

  Future<void> _hardDisposeInternal() async {
    _cancelPipTransition();
    _stopAndroidPipObservation();
    _cancelIdlePlayerRelease();
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    _proactiveSourceRefreshTimer?.cancel();
    _proactiveSourceRefreshTimer = null;
    _currentSourceRefreshAt = null;
    _sourceRefreshResolver = null;
    _sourceRefreshAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _prefetchedSourceRefresh = null;
    _clearSourceCommitState();
    _sessionId++;
    lineManager.reset();
    await _clearSubscriptions();
    await _disposeWindowsWarmStandby();
    final player = _currentPlayer;

    if (player != null) {
      await _disposePlayerWithTransport(player);
    }
    _currentPlayer = null;
    _runtimeEngine = null;
    _runtimeAudioOnly = false;
    _requestedAudioOnly = false;
    _nativeAudioOnly = false;
    _sameEngineRecoveryAttempts = 0;
    isVideoRestorePending.value = false;
    _pendingRoomReentry = null;
    _appFloatingSession = null;
    isInitialized.value = false;
    // The stream-forwarding subscriptions were just cleared, so the destroyed
    // native player can never report playing=false by itself. Reset the
    // aggregated state here or observers of onPlaying/onLoading (e.g. watch
    // time tracking) keep believing the session is still playing after the
    // room has been closed.
    _playingSubject.add(false);
    _loadingSubject.add(false);
  }

  Future<void> retry() {
    _cancelIdlePlayerRelease();
    _playbackRequested = true;
    _playbackIntentEstablished = true;
    _playbackIntentRevision++;
    _cancelPendingSourceInputs();
    _playbackSuspensions.clear();
    _sameEngineRecoveryAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _cancelTransientLiveRetry();
    _cancelContinuityRecovery();
    final intentRevision = _playbackIntentRevision;
    return _enqueuePlayerLifecycle(() async {
      if (!_isPlaybackCommandCurrent(intentRevision)) return;
      final source = _currentSource;
      if (source == null) return;
      await _playInternal(
        source,
        _currentPlayUrls,
        _currentHeaders,
        room: currentFloatRoom,
        audioOnly: _runtimeAudioOnly,
      );
    });
  }

  Future<void> _handleError(PlayerException error, {int? sessionId}) async {
    if (_disposed || _isClosing) return;
    final mySessionId = sessionId ?? _sessionId;
    if (!_isSessionValid(mySessionId)) return;
    final request = _PendingPlayerError(error: error, sessionId: mySessionId);
    // Reject duplicates before touching any watchdog or backoff owner. Native
    // layers can repeat the same failure after its first recovery was queued.
    if (!_registerPlayerError(request)) {
      log('skip duplicated source-generation error: ${error.message}', name: 'PlayerManager');
      return;
    }
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    _traceWindowsRecovery('handle', error: error, sessionId: mySessionId);
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;

    if (_isHandlingError) {
      // A replacement line/engine can fail synchronously while the previous
      // recovery is still on the stack. Dropping that event left the second
      // source loading forever. Keep the newest source-generation failure and
      // drain it as soon as the current recovery step returns.
      _pendingPlayerError = request;
      return;
    }

    _isHandlingError = true;
    try {
      _PendingPlayerError? current = request;
      while (current != null && !_disposed && !_isClosing) {
        _pendingPlayerError = null;
        await _recoverOrPublishPlayerError(current);
        current = _pendingPlayerError;
      }
    } finally {
      _isHandlingError = false;
      final pending = _pendingPlayerError;
      _pendingPlayerError = null;
      if (pending != null && _isSessionValid(pending.sessionId)) {
        unawaited(_handleError(pending.error, sessionId: pending.sessionId));
      }
    }
  }

  bool _registerPlayerError(_PendingPlayerError request) {
    if (_errorDedupeSession != request.sessionId) {
      _errorDedupeSession = request.sessionId;
      _errorDedupeSignatures.clear();
    }
    return _errorDedupeSignatures.add(
      '${request.error.type.name}:${request.error.code ?? '-'}:${request.error.message}',
    );
  }

  Future<void> _recoverOrPublishPlayerError(_PendingPlayerError request) async {
    if (!_isSessionValid(request.sessionId)) return;
    final error = request.error;
    final activeAtStart = _currentPlayer;
    final intentAtStart = _playbackIntentRevision;
    final bufferRecoveryAtStart = _bufferingRecoveryRevision;
    final playingRecoveryAtStart = _playingRecoveryRevision;
    final frameAtStart = _presentedFrameRevision;
    final sourceAttemptsAtStart = _sourceRefreshAttempts;
    final engineAttemptsAtStart = _sameEngineRecoveryAttempts;
    bool isStillRequired() {
      if (!_isSessionValid(request.sessionId) ||
          !identical(_currentPlayer, activeAtStart) ||
          _playbackIntentRevision != intentAtStart ||
          !_playbackRequested ||
          _playbackSuspensions.isNotEmpty) {
        return false;
      }
      // Only inferred stalls can be refuted by new progress. A real EOF or
      // native error still needs recovery even while buffered frames drain.
      return switch (error.code) {
        'buffering_stall_timeout' => bufferRecoveryAtStart == _bufferingRecoveryRevision,
        'video_frame_stall_timeout' =>
          frameAtStart == _presentedFrameRevision && _videoPresentationVisible && !_runtimeAudioOnly,
        'unexpected_pause_resume_failed' ||
        'unexpected_pause_timeout' ||
        'source_ready_timeout' => playingRecoveryAtStart == _playingRecoveryRevision,
        _ => true,
      };
    }

    if (!isStillRequired()) return;
    _traceWindowsRecovery('recover', error: error, sessionId: request.sessionId);
    _loadingSubject.add(true);
    _stateSubject.add(PlayerState.buffering);

    try {
      if ((error.type == PlayerErrorType.network || error.type == PlayerErrorType.source) &&
          await _tryRefreshSignedPlaybackSource(isStillRequired: isStillRequired)) {
        return;
      }
      if (!isStillRequired()) return;
      final currentUrl = _currentUrl;
      if ((error.type == PlayerErrorType.network || error.type == PlayerErrorType.source) &&
          currentUrl != null &&
          _currentPlayUrls.length > 1) {
        lineManager.markFailed(currentUrl);
        if (lineManager.hasAvailable(_currentPlayUrls)) {
          final nextLine = lineManager.next(_currentPlayUrls);
          if (nextLine != currentUrl) {
            log('recover playback with next line', name: 'PlayerManager');
            await _playInternal(
              UrlPlaybackSource(nextLine),
              _currentPlayUrls,
              _currentHeaders,
              room: currentFloatRoom,
              audioOnly: _runtimeAudioOnly,
            );
            return;
          }
        }
      }

      // A presented-frame stall means the current transport is already no
      // longer producing visible content. With alternate CDNs available,
      // switching source on the existing engine is both faster and safer than
      // opening the same signed URL concurrently on a replacement engine.
      // The single-line case still gets the bounded same-engine recreation.
      if (error.code == 'video_frame_stall_timeout' &&
          await _tryRecreateCurrentEngineForStall(error, isStillRequired: isStillRequired)) {
        return;
      }
      if (!isStillRequired()) return;

      final activePlayer = _currentPlayer;
      final currentDecoderSource = _currentSource;
      if (error.type == PlayerErrorType.codec &&
          error.code?.startsWith('audio_') != true &&
          activePlayer is DecoderRecoveryAwarePlayer &&
          currentDecoderSource != null &&
          await (activePlayer as DecoderRecoveryAwarePlayer).prepareSoftwareDecoderFallback(error)) {
        if (!isStillRequired()) return;
        log('recover playback with software decoder on the current engine', name: 'PlayerManager');
        await _playInternal(
          currentDecoderSource,
          _currentPlayUrls,
          _currentHeaders,
          room: currentFloatRoom,
          audioOnly: _runtimeAudioOnly,
        );
        return;
      }
      if (!isStillRequired()) return;

      if (fallbackManager.shouldFallback(error)) {
        final activeEngine = _runtimeEngine;
        if (activeEngine != null) {
          var engineCursor = activeEngine;
          var engineError = error;
          while (true) {
            final nextEngine = await fallbackManager.fallback(engineCursor, engineError);
            if (!isStillRequired()) return;
            if (nextEngine == engineCursor) break;
            log('recover playback with engine: ${engineCursor.name} -> ${nextEngine.name}', name: 'PlayerManager');
            _isSwitchingDueToFallback = true;
            try {
              await _switchEngineInternal(
                nextEngine,
                isManual: false,
                audioOnly: _runtimeAudioOnly,
                isStillRequired: isStillRequired,
              );
            } catch (switchError, stackTrace) {
              // Initialization can fail before the replacement engine owns a
              // source. Continue through the remaining engines instead of
              // leaving the old engine marked as switching forever.
              _isSwitchingDueToFallback = false;
              if (!isStillRequired()) return;
              engineCursor = nextEngine;
              engineError = switchError is PlayerException
                  ? switchError
                  : PlayerException(
                      message: 'Switch engine failed: $switchError',
                      type: PlayerErrorType.initialization,
                      error: switchError,
                      stackTrace: stackTrace,
                    );
              continue;
            }
            return;
          }
        }
      }
      if (!isStillRequired()) return;
      if (_shouldRecreateCurrentEngine(error) &&
          await _tryRecreateCurrentEngineForStall(error, isStillRequired: isStillRequired)) {
        return;
      }
      if (!isStillRequired()) return;
      _isSwitchingDueToFallback = false;
      if (_scheduleTransientLiveRetry(error)) return;
      _publishTerminalPlayerError(error);
    } catch (fallbackError, stackTrace) {
      _isSwitchingDueToFallback = false;
      if (!isStillRequired()) return;
      log('player recovery exhausted: $fallbackError', name: 'PlayerManager', stackTrace: stackTrace);
      if (_scheduleTransientLiveRetry(error)) return;
      _publishTerminalPlayerError(fallbackError is PlayerException ? fallbackError : error);
    } finally {
      if (activeAtStart != null &&
          !hasError.value &&
          !isStillRequired() &&
          _isPlayerEventCurrent(activeAtStart, request.sessionId)) {
        // Retire only this obsolete diagnostic; a later independent stall in
        // the same source generation must not be swallowed by deduplication.
        _errorDedupeSignatures.remove('${error.type.name}:${error.code ?? '-'}:${error.message}');
        // An aborted transaction is not an exhausted repair attempt. Keep
        // earlier real failures, but refund this uncommitted transaction.
        _sourceRefreshAttempts = sourceAttemptsAtStart;
        _sameEngineRecoveryAttempts = engineAttemptsAtStart;
        fallbackManager.reset(activeAtStart.engine);
        _isSwitchingDueToFallback = false;
        final loading = _playbackRequested && _playbackSuspensions.isEmpty && _nativeLoading;
        final playing = activeAtStart.isPlayingNow;
        _loadingSubject.add(loading);
        _playingSubject.add(playing);
        _stateSubject.add(loading ? PlayerState.buffering : (playing ? PlayerState.playing : PlayerState.paused));
        if (loading) {
          _scheduleBufferingStallRecovery(activeAtStart, request.sessionId);
        } else {
          _armVideoFrameStallRecovery(activeAtStart, request.sessionId);
          _scheduleContinuityRecovery(activeAtStart, request.sessionId);
          _scheduleRecoveryBudgetReset(activeAtStart, request.sessionId);
        }
        _traceWindowsRecovery('retire-obsolete', error: error, sessionId: request.sessionId);
      }
    }
  }

  /// Keeps a continuous live session recoverable across a short network/TLS
  /// interruption without spinning through every source and decoder in the
  /// same failing millisecond. Immediate line/engine recovery above still runs
  /// first. Only after it is exhausted do we schedule the finite backoff rounds
  /// configured by [transientLiveRetryDelays].
  bool _scheduleTransientLiveRetry(PlayerException error) {
    if ((error.type != PlayerErrorType.network && error.type != PlayerErrorType.source) ||
        !_isContinuousLiveSource ||
        !_playbackRequested ||
        _playbackSuspensions.isNotEmpty ||
        _currentSource == null ||
        _transientLiveRetryAttempts >= transientLiveRetryDelays.length) {
      return false;
    }

    final delay = transientLiveRetryDelays[_transientLiveRetryAttempts++];
    final expectedSessionId = _sessionId;
    final expectedIntentRevision = _playbackIntentRevision;
    final expectedRoom = currentFloatRoom;
    final expectedPlayer = _currentPlayer;
    final revision = ++_transientLiveRetryRevision;
    _transientLiveRetryTimer?.cancel();
    _transientLiveRetryOwner = _PendingPlayerError(error: error, sessionId: expectedSessionId);
    hasError.value = false;
    _loadingSubject.add(true);
    _stateSubject.add(PlayerState.buffering);
    log('Immediate live recovery exhausted; retrying after ${delay.inMilliseconds} ms', name: 'PlayerManager');

    bool isStillRequired() =>
        revision == _transientLiveRetryRevision &&
        !_disposed &&
        !_isClosing &&
        _playbackRequested &&
        _playbackSuspensions.isEmpty &&
        _playbackIntentRevision == expectedIntentRevision &&
        _sessionId == expectedSessionId &&
        identical(_currentPlayer, expectedPlayer) &&
        currentFloatRoom == expectedRoom;

    _transientLiveRetryTimer = Timer(delay, () {
      _transientLiveRetryTimer = null;
      if (!isStillRequired()) {
        if (revision == _transientLiveRetryRevision) _transientLiveRetryOwner = null;
        return;
      }
      unawaited(
        _enqueuePlayerLifecycle(() async {
              if (!isStillRequired()) return;

              // A new recovery round receives fresh bounded line/engine budgets.
              // The delayed-round budget itself remains monotonic until sustained
              // playback proves the transport healthy again.
              _sameEngineRecoveryAttempts = 0;
              _sourceRefreshAttempts = 0;
              _prefetchedSourceRefresh = null;
              lineManager.reset();
              fallbackManager.resetAll();

              if (await _tryRefreshSignedPlaybackSource(isStillRequired: isStillRequired)) return;
              if (!isStillRequired()) return;
              final retrySource = _currentSource;
              if (retrySource == null) return;
              await _playInternal(
                retrySource,
                _currentPlayUrls,
                _currentHeaders,
                room: currentFloatRoom,
                audioOnly: _runtimeAudioOnly,
              );
            })
            .catchError((Object retryError, StackTrace stackTrace) {
              log(
                'Delayed live recovery failed: $retryError',
                name: 'PlayerManager',
                error: retryError,
                stackTrace: stackTrace,
              );
            })
            .whenComplete(() {
              if (revision == _transientLiveRetryRevision) _transientLiveRetryOwner = null;
            }),
      );
    });
    return true;
  }

  Future<bool> _tryRefreshSignedPlaybackSource({bool proactive = false, bool Function()? isStillRequired}) async {
    if (isStillRequired?.call() == false) return true;
    final resolver = _sourceRefreshResolver;
    final currentSource = _currentSource;
    final currentUrl = currentSource?.url;
    if (resolver == null || currentSource == null || (!proactive && _sourceRefreshAttempts >= 2)) {
      return false;
    }

    final expectedSessionId = _sessionId;
    final expectedIntentRevision = _playbackIntentRevision;
    final currentIndex = currentUrl == null ? 0 : _currentPlayUrls.indexOf(currentUrl);
    final currentSelection = _sourceSelectionForCurrentCohort();
    final attempt = proactive ? 0 : _sourceRefreshAttempts++;
    bool requestIsCurrent() =>
        _isSessionValid(expectedSessionId) &&
        _playbackIntentRevision == expectedIntentRevision &&
        _playbackRequested &&
        _playbackSuspensions.isEmpty &&
        (isStillRequired?.call() ?? true);
    try {
      PlaybackSourceRefreshResult refreshed;
      if (!proactive) {
        // A credential-only prefetch has no native ownership. An actual EOF
        // can consume its result instead of launching a duplicate signer call,
        // but a new room/intent must never wait for the old request.
        final prefetch = _credentialPrefetch;
        if (attempt == 0 && prefetch?.belongsTo(expectedSessionId, expectedIntentRevision) == true) {
          await prefetch!.operation;
          if (!requestIsCurrent()) return true;
        }
        final cached = _prefetchedSourceRefresh;
        final invalidAt = cached?.invalidAt?.toUtc();
        final cacheUsable =
            cached != null && cached.hasSources && (invalidAt == null || invalidAt.isAfter(DateTime.now().toUtc()));
        if (cacheUsable && attempt == 0) {
          refreshed = cached;
          _prefetchedSourceRefresh = null;
        } else {
          if (!cacheUsable) _prefetchedSourceRefresh = null;
          refreshed = await _resolvePlaybackSource(
            resolver,
            PlaybackSourceRefreshRequest(
              currentLineIndex: currentIndex < 0 ? 0 : currentIndex,
              advanceLine: attempt > 0,
              currentUrl: currentUrl,
              currentSource: currentSource,
              currentQuality: currentSelection?.quality,
            ),
          );
        }
      } else {
        refreshed = await _resolvePlaybackSource(
          resolver,
          PlaybackSourceRefreshRequest(
            currentLineIndex: currentIndex < 0 ? 0 : currentIndex,
            advanceLine: false,
            currentUrl: currentUrl,
            currentSource: currentSource,
            currentQuality: currentSelection?.quality,
          ),
        );
      }
      // A resolver may finish after pause, close or a newer playback request.
      // Consume stale recovery without handing it to the fallback/reopen path.
      if (!requestIsCurrent()) {
        return true;
      }
      final urls = refreshed.urls.map((url) => url.trim()).where((url) => url.isNotEmpty).toList(growable: false);
      if (urls.isEmpty && refreshed.ownedSource == null) return false;
      final selectedIndex = urls.isEmpty ? 0 : refreshed.preferredLineIndex.clamp(0, urls.length - 1);
      final PlaybackSource selectedSource = refreshed.ownedSource ?? UrlPlaybackSource(urls[selectedIndex]);
      final refreshedHeaders = selectedSource is OwnedPlaybackSource ? const <String, String>{} : _currentHeaders;
      final selectedMetadata = refreshed.selection ?? currentSelection;
      final refreshedSelection = selectedSource is OwnedPlaybackSource && selectedMetadata != null
          ? PlaybackSourceQualitySelection(
              qualities: selectedMetadata.qualities,
              currentQuality: selectedMetadata.currentQuality,
            )
          : selectedMetadata;
      if (proactive) {
        if (PlatformUtils.isWindows && currentUrl != null && HuyaTransportPolicy.hasShortTransportLease(currentUrl)) {
          // Huya edge transports have been observed ending after roughly two
          // minutes on both FLV and HLS, even when wsTime remains valid much
          // longer. This is runtime evidence rather than a published SLA.
          // Start the fresh transport off-screen while the old one is still
          // presenting, then commit only after the candidate's first frame.
          // This reduces the black recovery interval. A ready candidate does
          // not prove timestamp alignment or a gap-free visible hand-off.
          _prefetchedSourceRefresh = null;
          final activePlayer = _currentPlayer;
          if (activePlayer == null) return false;
          final handoffStopwatch = Stopwatch()..start();
          _traceWindowsRecovery('proactive-handoff-start', sessionId: _sessionId);
          final handedOff = await _tryWarmSwapSource(
            selectedSource,
            urls,
            refreshedHeaders,
            room: currentFloatRoom,
            audioOnly: _runtimeAudioOnly,
            sourceRefreshAt: refreshed.refreshAt,
            sourceSelection: refreshedSelection,
            replaceSourceSelection: true,
          );
          if (handedOff) {
            final committed =
                !_disposed &&
                !_isClosing &&
                _currentPlayer != null &&
                !identical(_currentPlayer, activePlayer) &&
                _currentSource == selectedSource;
            _traceWindowsRecovery(
              committed ? 'proactive-handoff-commit' : 'proactive-handoff-cancelled',
              sessionId: _sessionId,
              elapsedMilliseconds: handoffStopwatch.elapsedMilliseconds,
            );
            if (committed) log('Completed the expiring Windows live transport handoff', name: 'PlayerManager');
            return true;
          }

          // A proactive transaction is best-effort. If DNS/TLS/demux/decoder
          // startup for the candidate fails, the current renderer is still
          // healthy and must remain the owner. Falling through to
          // `_playInternal` here would tear it down and recreate the exact
          // black interval this path exists to prevent. Retry while the old
          // transport still has headroom before Huya closes it.
          _traceWindowsRecovery(
            'proactive-handoff-retained-active',
            sessionId: _sessionId,
            elapsedMilliseconds: handoffStopwatch.elapsedMilliseconds,
          );
          if (identical(_currentPlayer, activePlayer) && !_disposed && !_isClosing) {
            _currentSourceRefreshAt = DateTime.now().toUtc().add(const Duration(seconds: 10));
            _scheduleProactiveSourceRefresh(activePlayer, _sessionId);
          }
          return false;
        }
        // Credential expiry is not necessarily an active transport deadline.
        // Native Huya FLV (on Windows too) and other platforms keep the current
        // connection while preparing credentials for an actual reconnect.
        _prefetchedSourceRefresh = refreshed.ownedSource != null
            ? PlaybackSourceRefreshResult.owned(
                source: refreshed.ownedSource!,
                refreshAt: refreshed.refreshAt?.toUtc(),
                invalidAt: refreshed.invalidAt?.toUtc(),
                selection: refreshedSelection,
              )
            : PlaybackSourceRefreshResult(
                urls: List<String>.unmodifiable(urls),
                preferredLineIndex: selectedIndex,
                refreshAt: refreshed.refreshAt?.toUtc(),
                invalidAt: refreshed.invalidAt?.toUtc(),
                selection: refreshedSelection,
              );
        log('Prefetched signed playback lease without replacing the active transport', name: 'PlayerManager');
        final nextRefreshAt = refreshed.refreshAt?.toUtc();
        _currentSourceRefreshAt = nextRefreshAt != null && nextRefreshAt.isAfter(DateTime.now().toUtc())
            ? nextRefreshAt
            : DateTime.now().toUtc().add(const Duration(seconds: 10));
        final player = _currentPlayer;
        if (player != null) _scheduleProactiveSourceRefresh(player, _sessionId);
        return true;
      }
      // URL equality only proves that the signer returned the same lease. It
      // says nothing about the health of the native TLS/demux transport. In
      // particular Huya may return the still-valid URL after a Windows socket
      // EOF. Treating equality as recovery success left the dead player and
      // black texture installed forever. A reactive refresh always opens a
      // new transport; on Windows this remains a first-frame-gated warm swap.
      final forceTransportRestart = selectedSource == currentSource;
      if (refreshed.invalidAt != null) {
        log('Consuming a refreshed signed playback lease after transport failure', name: 'PlayerManager');
      }
      log('Refreshing signed playback source (${attempt == 0 ? 'same line' : 'next line'})', name: 'PlayerManager');
      await _playResolvedSourceInternal(
        selectedSource,
        urls,
        refreshedHeaders,
        room: currentFloatRoom,
        audioOnly: _runtimeAudioOnly,
        allowWarmSwap: true,
        sourceRefreshAt: refreshed.refreshAt,
        sourceSelection: refreshedSelection,
        replaceSourceSelection: true,
        forceTransportRestart: forceTransportRestart,
        isStillRequired: isStillRequired,
      );
      return true;
    } catch (error, stackTrace) {
      // Failure is also an asynchronous result. A stale failed prefetch must
      // not overwrite the new session's refresh deadline or restart retries.
      if (!requestIsCurrent()) return true;
      log('Signed playback source refresh failed: $error', name: 'PlayerManager', error: error, stackTrace: stackTrace);
      if (proactive) {
        _currentSourceRefreshAt = DateTime.now().toUtc().add(const Duration(seconds: 10));
        final player = _currentPlayer;
        if (player != null) _scheduleProactiveSourceRefresh(player, _sessionId);
      }
      return false;
    }
  }

  Future<PlaybackSourceRefreshResult> _resolvePlaybackSource(
    PlaybackSourceResolver resolver,
    PlaybackSourceRefreshRequest request,
  ) {
    final operation = Future<PlaybackSourceRefreshResult>.sync(() => resolver(request));
    if (sourceRefreshTimeout <= Duration.zero) return operation;
    return operation.timeout(
      sourceRefreshTimeout,
      onTimeout: () {
        throw PlayerException(
          message: 'Playback source refresh did not finish before the recovery deadline',
          type: PlayerErrorType.source,
          code: 'source_refresh_timeout',
        );
      },
    );
  }

  void _publishTerminalPlayerError(PlayerException error) {
    _cancelTransientLiveRetry();
    _playbackRequested = false;
    _playbackSuspensions.clear();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    hasError.value = true;
    _loadingSubject.add(false);
    _errorSubject.add(error);
    _stateSubject.add(PlayerState.error);
  }

  bool _shouldRecreateCurrentEngine(PlayerException error) {
    if (error.type != PlayerErrorType.source) return false;
    return const <String>{
      'buffering_stall_timeout',
      'live_source_completed',
      'unexpected_pause_resume_failed',
      'unexpected_pause_timeout',
      'video_frame_stall_timeout',
    }.contains(error.code);
  }

  Future<bool> _tryRecreateCurrentEngineForStall(PlayerException error, {bool Function()? isStillRequired}) async {
    if (isStillRequired?.call() == false) return true;
    if (!_shouldRecreateCurrentEngine(error) || _sameEngineRecoveryAttempts >= 1) return false;
    final activeEngine = _runtimeEngine;
    final activePlayer = _currentPlayer;
    final currentSource = _currentSource;
    if (activeEngine == null || activePlayer == null || currentSource == null) return false;
    _sameEngineRecoveryAttempts++;
    _traceWindowsRecovery('warm-swap-request', error: error, sessionId: _sessionId);
    log('recover runtime live stall with a presentation-ready replacement', name: 'PlayerManager');
    try {
      // A successful `Player.open` only proves that libmpv accepted the URL. It
      // does not prove that the CDN returned video or that the Windows renderer
      // obtained a non-zero texture. Installing such a candidate destroyed the
      // last presented frame and left the room permanently black with a 0x0
      // `VideoOutput` when Huya returned 403/404 during token recovery.
      //
      // Windows media_kit exposes a native frame heartbeat, so use the same
      // first-frame transaction as signed-source refreshes. The active player
      // remains the presentation owner until the replacement has produced a
      // real frame; a candidate which stays at 0x0 is disposed instead of being
      // committed. Other platforms/engines retain the existing bounded recreate
      // path because they do not expose an equivalent presentation fence.
      if (PlatformUtils.isWindows && _supportsVideoFrameProgress(activePlayer)) {
        return await _tryWarmSwapSource(
          currentSource,
          List<String>.from(_currentPlayUrls),
          Map<String, String>.from(_currentHeaders),
          room: currentFloatRoom,
          audioOnly: _runtimeAudioOnly,
          sourceRefreshAt: _currentSourceRefreshAt,
          isStillRequired: isStillRequired,
        );
      }
      await _switchEngineInternal(
        activeEngine,
        isManual: false,
        audioOnly: _runtimeAudioOnly,
        forceRecreate: true,
        isStillRequired: isStillRequired,
      );
      return true;
    } catch (recreateError, recreateStackTrace) {
      log(
        'same-engine recreation failed: $recreateError',
        name: 'PlayerManager',
        error: recreateError,
        stackTrace: recreateStackTrace,
      );
      return false;
    }
  }

  bool _isPlayerEventCurrent(UnifiedPlayer player, int sessionId) {
    return _isSessionValid(sessionId) && identical(player, _currentPlayer);
  }

  Future<void> _bindPlayerStreams(UnifiedPlayer player, {required int sessionId}) async {
    await _clearSubscriptions();
    _nativeLoading = false;
    if (_supportsVideoFrameProgress(player)) {
      final frameAwarePlayer = player as VideoFrameProgressAwarePlayer;
      _subscriptions.add(
        frameAwarePlayer.onVideoFrameProgress.listen((_) {
          if (!_isPlayerEventCurrent(player, sessionId)) return;
          _notePresentedFrameProgress(player, sessionId);
          _armVideoFrameStallRecovery(player, sessionId);
        }),
      );
    }
    _subscriptions.add(
      player.onPlaying.distinct().listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        _traceWindowsRecovery('playing=$event', sessionId: sessionId);
        _playingSubject.add(event);
        if (event) {
          _playingRecoveryRevision++;
          _retireTransientLiveRetryForProgress(playingResumed: true);
          _sourceReadyTimer?.cancel();
          _sourceReadyTimer = null;
          hasError.value = false;
          if (_loadingSubject.value) {
            // libmpv may keep `playing=true` while the demuxer is starved.
            // Persistent buffering is the authoritative progress signal; the
            // former playing guard cancelled the only watchdog and left a
            // black Windows texture on screen indefinitely.
            _continuityTimer?.cancel();
            _continuityTimer = null;
            _stateSubject.add(PlayerState.buffering);
            _scheduleBufferingStallRecovery(player, sessionId);
          } else {
            _cancelContinuityRecovery();
            _stateSubject.add(PlayerState.playing);
            _armVideoFrameStallRecovery(player, sessionId);
          }
          final currentUrl = _currentUrl;
          if (currentUrl != null) lineManager.markSuccess(currentUrl);
          final runtimeEngine = _runtimeEngine;
          if (runtimeEngine != null) fallbackManager.reset(runtimeEngine);
          if (_isSwitchingDueToFallback) {
            _isSwitchingDueToFallback = false;
          }
          _scheduleSourceRefreshAttemptReset(player, sessionId);
          if (!_supportsVideoFrameProgress(player) || _runtimeAudioOnly) {
            _scheduleRecoveryBudgetReset(player, sessionId);
          }
          _scheduleProactiveSourceRefresh(player, sessionId);
          _scheduleActiveContentProbe();
        } else {
          _cancelVideoFrameStallRecovery();
          // A transient native `playing=false` is not a user pause while the
          // room still owns continuous playback. Keep the visible state in
          // transport recovery instead of flashing (or getting stuck on) the
          // paused control state. Explicit pause paths clear playback intent
          // before invoking the native player and therefore still publish
          // paused here.
          final transportOwnsPause = _shouldOwnContinuousPlayback(player, sessionId);
          if (!transportOwnsPause &&
              _stateSubject.value != PlayerState.preparing &&
              _stateSubject.value != PlayerState.buffering) {
            _stateSubject.add(PlayerState.paused);
          }
          // Native players commonly publish buffering=true before
          // playing=false. The first event still observes the player's old
          // playing flag; schedule the watchdog again after false becomes the
          // authoritative state instead of leaving the stream buffered for
          // the rest of the room session.
          if (_loadingSubject.value) {
            _scheduleBufferingStallRecovery(player, sessionId);
          } else {
            _scheduleContinuityRecovery(player, sessionId);
          }
        }
      }),
    );
    _subscriptions.add(
      player.onLoading.distinct().listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        _traceWindowsRecovery('loading=$event', sessionId: sessionId);
        if (!event && _nativeLoading) _bufferingRecoveryRevision++;
        _nativeLoading = event;
        if (!event) _retireTransientLiveRetryForProgress(bufferingEnded: true);
        _loadingSubject.add(event);
        if (event) {
          _cancelVideoFrameStallRecovery();
          _cancelContinuityRecovery();
          if (_stateSubject.value != PlayerState.buffering) {
            _stateSubject.add(PlayerState.buffering);
          }
          _scheduleBufferingStallRecovery(player, sessionId);
        } else {
          _cancelContinuityRecovery();
          if (player.isPlayingNow || isPlayingNow) {
            _stateSubject.add(PlayerState.playing);
            _armVideoFrameStallRecovery(player, sessionId);
          } else {
            _scheduleContinuityRecovery(player, sessionId);
          }
        }
      }),
    );
    _subscriptions.add(
      player.onComplete.distinct().listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        if (event) _traceWindowsRecovery('complete=true', sessionId: sessionId);
        _completeSubject.add(event);
        if (event &&
            _playbackRequested &&
            _playbackSuspensions.isEmpty &&
            _isContinuousLiveSource &&
            _stateSubject.value != PlayerState.preparing) {
          _cancelContinuityRecovery();
          _schedulePlayerError(
            PlayerException(
              message: 'Live source ended unexpectedly',
              type: PlayerErrorType.source,
              code: 'live_source_completed',
            ),
            sessionId,
          );
        }
      }),
    );
    _subscriptions.add(
      player.onStateChanged.listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        // media_kit can publish PlayerState.paused after onLoading(true) or
        // after a transient onPlaying(false). For a live source whose owner
        // still requests playback this is transport state, not user intent.
        // Publishing it directly changes the control icon to "paused" and
        // makes a short CDN/audio-focus discontinuity look like a random
        // automatic pause. Preserve buffering/recovery state; explicit user,
        // lifecycle and audio-interruption pauses all bypass this branch.
        if (event == PlayerState.paused && _shouldOwnContinuousPlayback(player, sessionId)) {
          if (_loadingSubject.value) {
            if (_stateSubject.value != PlayerState.buffering) {
              _stateSubject.add(PlayerState.buffering);
            }
            _scheduleBufferingStallRecovery(player, sessionId);
          } else {
            _scheduleContinuityRecovery(player, sessionId);
          }
          return;
        }
        _stateSubject.add(event);
      }),
    );
    _subscriptions.add(
      player.onError.listen((error) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        _traceWindowsRecovery('native-error', error: error, sessionId: sessionId);
        _schedulePlayerError(error, sessionId);
      }),
    );
    _subscriptions.add(
      player.width.listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        _widthSubject.add(event);
        _scheduleVideoGeometryObservation();
      }),
    );
    _subscriptions.add(
      player.height.listen((event) {
        if (!_isPlayerEventCurrent(player, sessionId)) return;
        _heightSubject.add(event);
        _scheduleVideoGeometryObservation();
      }),
    );
    _armVideoFrameStallRecovery(player, sessionId);
  }

  DateTime? _effectiveSourceRefreshAt(DateTime? advertisedRefreshAt, {required String? url}) {
    final advertised = advertisedRefreshAt?.toUtc();
    if (!PlatformUtils.isWindows || windowsHuyaProactiveRefreshInterval <= Duration.zero) return advertised;

    if (url == null || !HuyaTransportPolicy.hasShortTransportLease(url)) return advertised;

    final earlyWarmAt = DateTime.now().toUtc().add(windowsHuyaProactiveRefreshInterval);
    if (advertised == null || earlyWarmAt.isBefore(advertised)) return earlyWarmAt;
    return advertised;
  }

  /// Release-visible, token-safe playback diagnostics for the Windows Huya
  /// continuity investigation. Only protocol, host, state and timing are
  /// emitted; the signed path/query and viewer identity never leave memory.
  void _traceWindowsRecovery(String event, {PlayerException? error, int? sessionId, int? elapsedMilliseconds}) {
    if (!PlatformUtils.isWindows) return;
    final now = DateTime.now();
    final frameAt = _lastPresentedFrameAt;
    final frameAgeMs = frameAt == null ? -1 : now.difference(frameAt).inMilliseconds;
    final uri = Uri.tryParse(_currentUrl ?? '');
    final path = uri?.path.toLowerCase() ?? '';
    final protocol = path.endsWith('.m3u8') ? 'hls' : (path.endsWith('.flv') ? 'flv' : 'other');
    final code = error?.code ?? '-';
    final type = error?.type.name ?? '-';
    // ignore: avoid_print
    print(
      '[PlayerRecovery] ${now.toIso8601String()} event=$event session=${sessionId ?? _sessionId} '
      'protocol=$protocol host=${uri?.host ?? '-'} playing=$isPlayingNow loading=${_loadingSubject.value} '
      'presentation=$_videoPresentationVisible frameRevision=$_presentedFrameRevision frameAgeMs=$frameAgeMs '
      'elapsedMs=${elapsedMilliseconds ?? -1} errorType=$type errorCode=$code',
    );
  }

  Future<void> _clearSubscriptions() async {
    _cancelVideoFrameStallRecovery();
    if (_subscriptions.isEmpty) return;
    final subscriptions = List<StreamSubscription>.of(_subscriptions);
    // Detach ownership before awaiting cancellation so a synchronous source
    // callback cannot append into the list being drained. Cancel independent
    // streams concurrently; the previous serial loop added one event-loop turn
    // per subject during every quality, line and engine transition.
    _subscriptions.clear();
    await Future.wait<void>(subscriptions.map((item) => item.cancel()));
  }

  void _scheduleSourceRefreshAttemptReset(UnifiedPlayer player, int sessionId) {
    _scheduleRecoveryBudgetReset(player, sessionId);
  }

  void _scheduleProactiveSourceRefresh(UnifiedPlayer player, int sessionId) {
    _proactiveSourceRefreshTimer?.cancel();
    _proactiveSourceRefreshTimer = null;
    final refreshAt = _currentSourceRefreshAt;
    if (refreshAt == null || _sourceRefreshResolver == null || !_isPlayerEventCurrent(player, sessionId)) return;
    // The splice relay renews this lease underneath the native connection.
    if (_splicedLeasePlayers.contains(player)) return;

    final remaining = refreshAt.difference(DateTime.now().toUtc());
    final delay = remaining > const Duration(seconds: 1) ? remaining : const Duration(seconds: 1);
    _proactiveSourceRefreshTimer = Timer(delay, () {
      _proactiveSourceRefreshTimer = null;
      if (!_isPlayerEventCurrent(player, sessionId) || !_playbackRequested || _playbackSuspensions.isNotEmpty) return;
      final intentRevision = _playbackIntentRevision;
      if (!PlatformUtils.isWindows || !HuyaTransportPolicy.hasShortTransportLease(_currentUrl ?? '')) {
        // Fetching a standby credential is network work, not a player command.
        // Holding the native queue here made slow HTTP block room changes and
        // close even though the active native FLV transport remained healthy.
        unawaited(_prefetchPlaybackCredential(player, sessionId, intentRevision));
        return;
      }
      unawaited(
        _enqueuePlayerLifecycle(() async {
          if (!_isPlayerEventCurrent(player, sessionId) ||
              intentRevision != _playbackIntentRevision ||
              !_playbackRequested ||
              _playbackSuspensions.isNotEmpty) {
            return;
          }
          // Windows web/HLS compatibility handoffs still touch two native
          // players and therefore retain serialized ownership.
          await _tryRefreshSignedPlaybackSource(proactive: true);
        }),
      );
    });
  }

  Future<void> _prefetchPlaybackCredential(UnifiedPlayer player, int sessionId, int intentRevision) async {
    if (!_isPlayerEventCurrent(player, sessionId) ||
        intentRevision != _playbackIntentRevision ||
        !_playbackRequested ||
        _playbackSuspensions.isNotEmpty ||
        _credentialPrefetch?.belongsTo(sessionId, intentRevision) == true) {
      return;
    }
    final prefetch = _PlaybackCredentialPrefetch(
      sessionId,
      intentRevision,
      _tryRefreshSignedPlaybackSource(proactive: true),
    );
    _credentialPrefetch = prefetch;
    try {
      await prefetch.operation;
    } finally {
      // A new session may already have its own in-flight credential request.
      if (identical(_credentialPrefetch, prefetch)) _credentialPrefetch = null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _isClosing = true;
    final restoreWindowsWindow = _usesWindowsPip && isInPip.value;
    _cancelPipTransition();
    _stopAndroidPipObservation();
    if (_usesAndroidPip || restoreWindowsWindow) isInPip.value = false;
    // Compact-only controls never outlive the playback session.
    _compactVolumeOverride = null;
    _compactLastAudibleVolume = null;
    isCompactMuted.value = false;
    isCompactDanmakuHidden.value = false;
    isPipAlwaysOnTop.value = false;
    if (restoreWindowsWindow) {
      await _restoreWindowsMainWindow();
    }
    _disposed = true;
    _currentSource = null;
    _sourceOpened = false;
    _cancelPendingSourceInputs();
    _playbackRequested = false;
    _playbackSuspensions.clear();
    _cancelContinuityRecovery();
    _cancelVideoFrameStallRecovery();
    _cancelTransientLiveRetry();
    _sessionId++;
    _pendingPlayerError = null;
    _errorDedupeSignatures.clear();
    _hideTimer?.cancel();
    _sourceReadyTimer?.cancel();
    _sourceReadyTimer = null;
    _geometryObservationTimer?.cancel();
    _geometryStabilityTimer?.cancel();
    _contentProbeTimer?.cancel();
    _audioModeVideoWarmTimer?.cancel();
    _sourceRefreshAttemptResetTimer?.cancel();
    _sourceRefreshAttemptResetTimer = null;
    _proactiveSourceRefreshTimer?.cancel();
    _proactiveSourceRefreshTimer = null;
    _currentSourceRefreshAt = null;
    _sourceRefreshResolver = null;
    _sourceRefreshAttempts = 0;
    _transientLiveRetryAttempts = 0;
    _prefetchedSourceRefresh = null;
    _clearSourceCommitState();
    _cancelIdlePlayerRelease();
    await closeAppFloating();
    await _pipSubscription?.cancel();
    await _pipStateSubscription?.cancel();
    await _clearSubscriptions();
    await _hardDisposeInternal();
    await Future.wait([
      _stateSubject.close(),
      _playingSubject.close(),
      _loadingSubject.close(),
      _completeSubject.close(),
      _errorSubject.close(),
      _widthSubject.close(),
      _heightSubject.close(),
      _sourceCommitController.close(),
    ]);
  }
}

/// Resolves application-floating bounds from the same aspect used by the
/// normal player and Android PiP. Keeping this pure makes late portrait
/// detection and size clamping deterministic in widget-free tests.
@visibleForTesting
Size resolveAppFloatingSize({
  required double aspectRatio,
  required double maxSide,
  double minimumWidth = 120,
  double portraitHeightFactor = 1.2,
}) {
  final safeMaxSide = maxSide.isFinite && maxSide > 0 ? maxSide : 220.0;
  final safeMinimumWidth = minimumWidth.isFinite && minimumWidth > 0 ? minimumWidth : 120.0;
  final ratio = aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio.clamp(PortraitPresentationPolicy.androidPipMinimumAspectRatio, 4.0).toDouble()
      : 16 / 9;
  if (ratio >= 1) return Size(safeMaxSide, safeMaxSide / ratio);

  var height = safeMaxSide * (portraitHeightFactor.isFinite && portraitHeightFactor > 0 ? portraitHeightFactor : 1.2);
  var width = height * ratio;
  if (width < safeMinimumWidth) {
    width = safeMinimumWidth;
    height = width / ratio;
  }
  return Size(width, height);
}

/// Returns the visible contain-fitted video bounds used as Android's PiP
/// transition hint. The system expects this rectangle and the requested PiP
/// aspect to describe the same pixels.
@visibleForTesting
Rect resolveContainedVideoRect({required Rect container, required double contentAspectRatio}) {
  if (container.isEmpty || !contentAspectRatio.isFinite || contentAspectRatio <= 0) return container;
  final containerRatio = container.width / container.height;
  if ((containerRatio - contentAspectRatio).abs() <= 0.001) return container;
  if (containerRatio > contentAspectRatio) {
    final width = container.height * contentAspectRatio;
    return Rect.fromLTWH(container.left + (container.width - width) / 2, container.top, width, container.height);
  }
  final height = container.width / contentAspectRatio;
  return Rect.fromLTWH(container.left, container.top + (container.height - height) / 2, container.width, height);
}

/// Selects exactly one owner for mobile scaling.
///
/// Ordinary decoded frames are returned directly and the native player owns
/// [fit]. A confirmed active-content crop is the only case that adds a Flutter
/// viewport: the native surface fills its measured raw canvas, then one outer
/// transform applies the crop and requested fit. Keeping the builder here also
/// lets widget tests reproduce media_kit's internal FittedBox contract.
@visibleForTesting
Widget buildUnifiedMobileVideoPresentation({
  required double aspectRatio,
  required BoxFit fit,
  required Widget Function(BoxFit fit) nativeVideoBuilder,
  double? encodedAspectRatio,
  NormalizedVideoInsets contentInsets = NormalizedVideoInsets.none,
}) {
  final safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  final safeEncodedRatio = encodedAspectRatio != null && encodedAspectRatio.isFinite && encodedAspectRatio > 0
      ? encodedAspectRatio
      : safeAspectRatio;
  final safeContentInsets = resolveConsistentVideoContentInsets(
    encodedAspectRatio: safeEncodedRatio,
    presentationAspectRatio: safeAspectRatio,
    contentInsets: contentInsets,
  );
  if (!safeContentInsets.hasCrop) return nativeVideoBuilder(fit);
  return buildUnifiedMobileVideoFrame(
    aspectRatio: safeAspectRatio,
    encodedAspectRatio: safeEncodedRatio,
    contentInsets: safeContentInsets,
    fit: fit,
    child: nativeVideoBuilder(BoxFit.fill),
  );
}

/// Builds the exceptional measured-crop viewport used by
/// [buildUnifiedMobileVideoPresentation].
@visibleForTesting
Widget buildUnifiedMobileVideoFrame({
  required double aspectRatio,
  required BoxFit fit,
  required Widget child,
  double? encodedAspectRatio,
  NormalizedVideoInsets contentInsets = NormalizedVideoInsets.none,
}) {
  final safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  final safeEncodedRatio = encodedAspectRatio != null && encodedAspectRatio.isFinite && encodedAspectRatio > 0
      ? encodedAspectRatio
      : safeAspectRatio;
  const basis = 1000.0;
  final safeContentInsets = resolveConsistentVideoContentInsets(
    encodedAspectRatio: safeEncodedRatio,
    presentationAspectRatio: safeAspectRatio,
    contentInsets: contentInsets,
  );
  final useActiveCrop = safeContentInsets.hasCrop;
  // Always size the native texture from its actual canvas. Presentation ratio
  // may come from platform metadata, a room override or visual content, none of
  // which is permission to stretch the decoded pixels. A measured crop changes
  // only the viewport below.
  final rawWidth = basis * safeEncodedRatio;
  final rawHeight = basis;
  final viewportWidth = useActiveCrop ? rawWidth * safeContentInsets.widthFraction : rawWidth;
  final viewportHeight = useActiveCrop ? rawHeight * safeContentInsets.heightFraction : rawHeight;
  final videoFrame = useActiveCrop
      ? SizedBox(
          key: const ValueKey('active-video-content-viewport'),
          width: viewportWidth,
          height: viewportHeight,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: -rawWidth * safeContentInsets.left,
                  top: -rawHeight * safeContentInsets.top,
                  width: rawWidth,
                  height: rawHeight,
                  child: child,
                ),
              ],
            ),
          ),
        )
      : SizedBox(width: rawWidth, height: rawHeight, child: child);
  return ClipRect(
    child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: videoFrame),
  );
}

/// Constrains only the decoded-video layer while leaving sibling controls on
/// the complete presentation surface.
///
/// This is intentionally outside [UnifiedPlayer]. Fullscreen portrait layout
/// is a route-local concern; writing a special fit into the shared native
/// player/controller lets inactive normal, fullscreen and floating trees race
/// over one adapter state during transitions.
@visibleForTesting
Widget buildPresentationVideoViewport({
  required Widget child,
  double? aspectRatio,
  PortraitFullscreenDisplayMode? mode,
}) {
  if (aspectRatio == null || !aspectRatio.isFinite || aspectRatio <= 0) return child;
  if (mode == PortraitFullscreenDisplayMode.cover) {
    return SizedBox.expand(key: const ValueKey('presentation-video-cover'), child: child);
  }
  final viewport = AspectRatio(
    key: const ValueKey('presentation-video-viewport'),
    aspectRatio: aspectRatio,
    child: child,
  );
  if (mode != PortraitFullscreenDisplayMode.balanced) return Center(child: viewport);
  return LayoutBuilder(
    builder: (context, constraints) {
      final scale = resolvePortraitFullscreenBalancedScale(
        viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
        contentAspectRatio: aspectRatio,
      );
      return ClipRect(
        key: const ValueKey('presentation-video-balanced-clip'),
        child: Center(
          child: Transform.scale(
            key: const ValueKey('presentation-video-balanced-scale'),
            scale: scale,
            child: viewport,
          ),
        ),
      );
    },
  );
}

/// Applies only enough zoom to soften a phone's letterbox gap while keeping a
/// strict crop budget. The rest of the gap remains available for the ambient
/// background, so a very tall display never silently discards 20% of a stream.
@visibleForTesting
double resolvePortraitFullscreenBalancedScale({
  required Size viewportSize,
  required double contentAspectRatio,
  double maximumScale = 1.08,
}) {
  if (viewportSize.isEmpty ||
      !viewportSize.width.isFinite ||
      !viewportSize.height.isFinite ||
      !contentAspectRatio.isFinite ||
      contentAspectRatio <= 0 ||
      !maximumScale.isFinite ||
      maximumScale <= 1) {
    return 1;
  }
  final viewportAspectRatio = viewportSize.width / viewportSize.height;
  final coverScale = viewportAspectRatio < contentAspectRatio
      ? contentAspectRatio / viewportAspectRatio
      : viewportAspectRatio / contentAspectRatio;
  return coverScale.clamp(1.0, maximumScale).toDouble();
}

class _AudioServiceRequest {
  const _AudioServiceRequest({
    required this.player,
    required this.audioOnly,
    required this.room,
    required this.sessionId,
  });

  final UnifiedPlayer player;
  final bool audioOnly;
  final LiveRoom? room;
  final int sessionId;
}

class _PendingPlayerError {
  const _PendingPlayerError({required this.error, required this.sessionId});

  final PlayerException error;
  final int sessionId;
}

/// Immutable presentation state transferred from the popped live-room route to
/// the route opened from the in-app floating player.
///
/// The native player remains owned by [PlayerManager]. This object deliberately
/// contains room/UI metadata and optional recreation recipes, never a live
/// input or old route owner. Re-entry attaches without reopening the stream.
class RoomSessionSnapshot {
  static const _notProvided = Object();
  const RoomSessionSnapshot({
    required this.room,
    required this.qualities,
    required this.currentQuality,
    required this.playUrls,
    this.sourceQueryPolicies = const {},
    this.ownedSource,
    required this.currentLineIndex,
    required this.headers,
    required this.isAudioOnly,
    required this.isLiving,
    this.dataSource = '',
    this.hasUseDefaultResolution = true,
  });

  final LiveRoom room;
  final List<LivePlayQuality> qualities;
  final int currentQuality;
  final List<String> playUrls;
  final Map<String, HlsSourceQueryPolicy> sourceQueryPolicies;
  final OwnedPlaybackSource? ownedSource;
  final int currentLineIndex;
  final Map<String, String> headers;
  final bool isAudioOnly;
  final bool isLiving;
  final String dataSource;
  final bool hasUseDefaultResolution;

  RoomSessionSnapshot copyWith({
    LiveRoom? room,
    List<LivePlayQuality>? qualities,
    int? currentQuality,
    List<String>? playUrls,
    Map<String, HlsSourceQueryPolicy>? sourceQueryPolicies,
    Object? ownedSource = _notProvided,
    int? currentLineIndex,
    Map<String, String>? headers,
    bool? isAudioOnly,
    bool? isLiving,
    String? dataSource,
    bool? hasUseDefaultResolution,
  }) {
    return RoomSessionSnapshot(
      room: room ?? this.room,
      qualities: qualities ?? this.qualities,
      currentQuality: currentQuality ?? this.currentQuality,
      playUrls: playUrls ?? this.playUrls,
      ownedSource: identical(ownedSource, _notProvided)
          ? (playUrls == null &&
                    dataSource == null &&
                    qualities == null &&
                    (currentQuality == null || currentQuality == this.currentQuality) &&
                    (room == null || room == this.room)
                ? this.ownedSource
                : null)
          : ownedSource as OwnedPlaybackSource?,
      sourceQueryPolicies: Map<String, HlsSourceQueryPolicy>.unmodifiable(
        sourceQueryPolicies ?? (playUrls == null ? this.sourceQueryPolicies : const {}),
      ),
      currentLineIndex: currentLineIndex ?? this.currentLineIndex,
      headers: headers ?? this.headers,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
      isLiving: isLiving ?? this.isLiving,
      dataSource: dataSource ?? this.dataSource,
      hasUseDefaultResolution: hasUseDefaultResolution ?? this.hasUseDefaultResolution,
    );
  }
}

/// 悬浮窗边缘拖拽缩放的手柄方向。
enum _FloatingResizeEdge {
  left,
  top,
  right,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get affectsLeft => this == left || this == topLeft || this == bottomLeft;
  bool get affectsRight => this == right || this == topRight || this == bottomRight;
  bool get affectsTop => this == top || this == topLeft || this == topRight;
  bool get affectsBottom => this == bottom || this == bottomLeft || this == bottomRight;
  bool get affectsHorizontal => affectsLeft || affectsRight;
  bool get affectsVertical => affectsTop || affectsBottom;
}

/// 一次悬浮窗边缘拖拽缩放过程的快照与累计位移。
class _FloatingResizeSession {
  _FloatingResizeSession({
    required this.edge,
    required this.startRect,
    required this.startLongSide,
    required this.screenSize,
  });

  final _FloatingResizeEdge edge;
  final Rect startRect;
  final double startLongSide;
  final Size screenSize;
  double accumulatedDx = 0;
  double accumulatedDy = 0;

  /// 最新一帧的期望几何位置（屏幕 margin 钳制后）。帧末校正回调据此
  /// 重新向插件下发锚点命令，抵消插件 sizeChange 启发式的位移。
  double targetX = 0;
  double targetY = 0;
  double targetWidth = 0;
  double targetHeight = 0;

  /// 手势已结束：正在等待最后一帧完成终态校正，之后恢复动画时长。
  bool finalizing = false;
}
