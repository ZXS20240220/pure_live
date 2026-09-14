import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';

/// Live stream cache-aware progress bar, modelled after mpv's built-in OSC.
///
/// Coordinate system
/// -----------------
/// The whole track maps to mpv's full timeline `[0, duration]`. For live
/// streams `duration` keeps growing from the moment the stream opened
/// (highest buffered PTS - start time), exactly the scale the native OSC
/// maps `percent-pos` onto. The handle therefore starts at the left,
/// advances quickly, and then settles near the right edge.
///
/// Only the cached seekable ranges (`demuxer-cache-state/seekable-ranges`,
/// projected onto the same scale) are actually seekable. Everything left of
/// the window has been evicted from the back-buffer ("dead zone"); seeking
/// there would make mpv drop its cache and reconnect the live stream, which
/// restarts the PTS timeline at 0 and throws the handle back to the far
/// left. User input inside a dead zone is therefore snapped to the nearest
/// range boundary instead of being forwarded to mpv.
class LiveProgressBar extends StatefulWidget {
  const LiveProgressBar({super.key, required this.controller});

  final VideoController controller;

  @override
  State<LiveProgressBar> createState() => _LiveProgressBarState();
}

class _LiveProgressBarState extends State<LiveProgressBar> {
  static const Duration _tickInterval = Duration(milliseconds: 200);
  static const Duration _dragSeekThrottle = Duration(milliseconds: 80);
  static const double _hitAreaHeight = 22.0;
  static const double _barHeight = 3.5;

  Timer? _tickTimer;
  Object? _boundPlayerId;

  /// Playhead fraction on the full timeline (0.0–1.0), equivalent to
  /// mpv's `percent-pos / 100`.
  double _currentFrac = 0.0;

  /// Cached seekable window on the same 0.0–1.0 scale.
  List<({double start, double end})> _ranges = const [];

  bool _userSeeked = false;

  bool _isDragging = false;
  double? _dragFrac;
  DateTime _lastDragSeek = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final player = GlobalPlayerService.instance.player;

    // Detect player instance changes (engine swap) and reset local state.
    final playerId = identityHashCode(player);
    if (_boundPlayerId != playerId) {
      _boundPlayerId = playerId;
      _currentFrac = 0.0;
      _ranges = const [];
      _userSeeked = false;
    }

    if (!player.canSeek) {
      if (_currentFrac != 0.0 || _ranges.isNotEmpty || _userSeeked) {
        setState(() {
          _currentFrac = 0.0;
          _ranges = const [];
          _userSeeked = false;
        });
      }
      return;
    }

    final frac = player.positionFraction ?? 0.0;
    final ranges = player.seekableFractions;
    final seeked = player.isUserSeekedBack;
    if (frac != _currentFrac || seeked != _userSeeked || !_rangesEqual(ranges, _ranges)) {
      setState(() {
        _currentFrac = frac;
        _ranges = ranges;
        _userSeeked = seeked;
      });
    }
  }

  static bool _rangesEqual(
    List<({double start, double end})> a,
    List<({double start, double end})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i].start - b[i].start).abs() > 1e-6 || (a[i].end - b[i].end).abs() > 1e-6) {
        return false;
      }
    }
    return true;
  }

  /// Snaps a fraction into the seekable window, mirroring the protection in
  /// the adapter so the handle can never be dragged into a dead zone. When no
  /// ranges are known (VOD or a just-started live stream) the whole track is
  /// considered seekable and the fraction is returned unchanged.
  double _snapFraction(double frac) {
    if (_ranges.isEmpty) return frac;
    for (final r in _ranges) {
      if (frac >= r.start && frac <= r.end) return frac;
    }
    var nearest = _ranges.first.start;
    var nearestDistance = double.infinity;
    for (final r in _ranges) {
      for (final boundary in [r.start, r.end]) {
        final distance = (boundary - frac).abs();
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearest = boundary;
        }
      }
    }
    return nearest;
  }

  double _fracFromGlobalPosition(Offset globalPosition) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || renderBox.size.width <= 0) return 0.0;
    final local = renderBox.globalToLocal(globalPosition);
    return (local.dx / renderBox.size.width).clamp(0.0, 1.0);
  }

  void _onTapDown(TapDownDetails details) {
    final player = GlobalPlayerService.instance.player;
    if (!player.canSeek) return;
    widget.controller.enableController();
    final frac = _snapFraction(_fracFromGlobalPosition(details.globalPosition));
    // OSC uses exact seeks on click. The handle moves to the target on the
    // next tick once time-pos catches up; no local drag state needed.
    player.seekToFraction(frac, exact: true);
  }

  void _onDragStart(DragStartDetails details) {
    final player = GlobalPlayerService.instance.player;
    if (!player.canSeek) return;
    widget.controller.holdController();
    setState(() {
      _isDragging = true;
      _dragFrac = _snapFraction(_fracFromGlobalPosition(details.globalPosition));
    });
    _lastDragSeek = DateTime.now();
    player.seekToFraction(_dragFrac!, exact: false);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    final player = GlobalPlayerService.instance.player;
    final raw = _fracFromGlobalPosition(details.globalPosition);
    final frac = _snapFraction(raw);
    setState(() => _dragFrac = frac);
    // Keyframe seeks while dragging (cheap, local), throttled like the OSC.
    final now = DateTime.now();
    if (now.difference(_lastDragSeek) >= _dragSeekThrottle) {
      _lastDragSeek = now;
      player.seekToFraction(frac, exact: false);
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    // Final exact seek on release for precise positioning.
    if (_dragFrac != null) {
      GlobalPlayerService.instance.player.seekToFraction(_dragFrac!, exact: true);
    }
    setState(() {
      _isDragging = false;
      _dragFrac = null;
    });
    widget.controller.releaseController();
  }

  @override
  Widget build(BuildContext context) {
    final player = GlobalPlayerService.instance.player;
    if (!player.canSeek) {
      return const SizedBox.shrink();
    }

    final rawFrac = _isDragging && _dragFrac != null ? _dragFrac! : _currentFrac;
    final effectiveFrac = _isDragging ? _snapFraction(rawFrac) : rawFrac;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 2),
        child: SizedBox(
          height: _hitAreaHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _onTapDown,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: Center(
              child: SizedBox(
                height: _barHeight,
                child: CustomPaint(
                  painter: _LiveProgressPainter(
                    ranges: _ranges,
                    currentFrac: effectiveFrac,
                    isUserSeeked: _userSeeked,
                    isDragging: _isDragging,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// mpv-lazy style progress bar: a thin line with no circular handle.
///
/// Segments from left to right:
///   * played     — opaque white (already played, still cached)
///   * buffered   — translucent white (downloaded but not yet played)
///   * track      — very translucent white (uncached / future)
///
/// When the user has seeked back from the live edge, the played colour shifts
/// to orange so the timeshift state is visible at a glance. A tiny red notch
/// marks the live edge of the cached window.
class _LiveProgressPainter extends CustomPainter {
  _LiveProgressPainter({
    required this.ranges,
    required this.currentFrac,
    required this.isUserSeeked,
    required this.isDragging,
  });

  final List<({double start, double end})> ranges;
  final double currentFrac;
  final bool isUserSeeked;
  final bool isDragging;

  // Colours are tuned to match mpv-lazy's OSC look: a thin, mostly-transparent
  // track with a bright played segment and a dimmer buffered segment.
  static final Color _trackColor = Colors.white.withValues(alpha: 0.18);
  static final Color _bufferedColor = Colors.white.withValues(alpha: 0.32);
  static final Color _playedColor = Colors.white.withValues(alpha: 0.92);
  static final Color _playedSeekedColor = Colors.orangeAccent.withValues(alpha: 0.92);
  static final Color _liveEdgeColor = const Color(0xFFFF4444);

  void _segment(Canvas canvas, double y, double w, double h, double from, double to, Paint paint) {
    final x1 = (from.clamp(0.0, 1.0)) * w;
    final x2 = (to.clamp(0.0, 1.0)) * w;
    if (x2 <= x1) return;
    canvas.drawLine(Offset(x1, y), Offset(x2, y), paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final y = h / 2;
    final frac = currentFrac.clamp(0.0, 1.0);

    // Dragging makes the bar a touch thicker for easier hit feedback.
    final stroke = isDragging ? h + 3.0 : h;

    final trackPaint = Paint()
      ..color = _trackColor
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final bufferedPaint = Paint()
      ..color = _bufferedColor
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final playedPaint = Paint()
      ..color = isUserSeeked ? _playedSeekedColor : _playedColor
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // 1. Background track — the full uncached timeline.
    canvas.drawLine(Offset(0, y), Offset(w, y), trackPaint);

    // No cached ranges (VOD or a just-started live stream): the whole
    // timeline is seekable, so draw it as buffered with the played portion
    // on top.
    if (ranges.isEmpty) {
      _segment(canvas, y, w, h, 0, 1, bufferedPaint);
      if (frac > 0) _segment(canvas, y, w, h, 0, frac, playedPaint);
      return;
    }

    for (final r in ranges) {
      final rStart = r.start.clamp(0.0, 1.0);
      final rEnd = r.end.clamp(0.0, 1.0);

      // 2. Played segment — the part of the cached window left of the
      //    playhead. Opaque (or orange when timeshifted).
      if (frac > rStart) {
        _segment(canvas, y, w, h, rStart, frac < rEnd ? frac : rEnd, playedPaint);
      }
      // 3. Buffered segment — the part of the cached window right of the
      //    playhead (downloaded but not yet played).
      if (frac < rEnd) {
        _segment(canvas, y, w, h, frac > rStart ? frac : rStart, rEnd, bufferedPaint);
      }
      // 4. Tiny notch at the live edge (newest cached point).
      final edgeX = rEnd * w;
      final edgePaint = Paint()
        ..color = _liveEdgeColor
        ..strokeWidth = stroke + 1
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(edgeX - 1, y), Offset(edgeX + 1, y), edgePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveProgressPainter oldDelegate) {
    return currentFrac != oldDelegate.currentFrac ||
        isUserSeeked != oldDelegate.isUserSeeked ||
        isDragging != oldDelegate.isDragging ||
        !_rangesEqual(ranges, oldDelegate.ranges);
  }

  static bool _rangesEqual(
    List<({double start, double end})> a,
    List<({double start, double end})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }
}
