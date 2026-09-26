import 'dart:async';
import 'dart:collection';

import 'package:pure_live/common/models/live_message.dart';

/// Aggregates a burst of identical chat text into a "原文 ×N" summary.
///
/// The first message of a text key is NEVER held: [offer] returns true so the
/// caller emits it through the normal path with zero latency. Duplicates that
/// arrive inside the window are swallowed and counted. When the window
/// closes, groups with more than one copy emit one synthesized "原文 ×N"
/// summary carrying the first sender's metadata; singleton groups emit
/// nothing (their message is already visible).
///
/// Local messages bypass aggregation. Because pending groups belong to one
/// room session, session switches must call [clear]; user-facing toggles
/// should call [setConfig], which flushes summaries on disable.
class DanmakuAggregator {
  DanmakuAggregator({this.maxPendingKeys = 512, this.timerFactory = Timer.new});

  final int maxPendingKeys;

  /// Injectable so tests can drive window expiry without real async time.
  final Timer Function(Duration duration, void Function() callback) timerFactory;

  /// Called for "原文 ×N" summaries when a window closes. Window expiry and
  /// the pending-cap overflow in [offer] may invoke it synchronously.
  void Function(LiveMessage message)? onEmit;

  bool _enabled = false;
  Duration _window = const Duration(seconds: 5);

  final LinkedHashMap<String, _PendingGroup> _pending = LinkedHashMap<String, _PendingGroup>();

  bool get isHoldingMessages => _pending.isNotEmpty;
  int get pendingKeyCount => _pending.length;

  void setConfig({required bool enabled, required Duration window}) {
    final wasEnabled = _enabled;
    _enabled = enabled;
    if (window > Duration.zero) _window = window;
    if (wasEnabled && !enabled) flushAll();
  }

  /// Returns true when the caller should emit [message] itself (disabled,
  /// local or empty-text messages pass through untouched, and the FIRST copy
  /// of a new text key is emitted immediately). Returns false when the
  /// aggregator swallowed the message as a duplicate inside a pending group.
  bool offer(LiveMessage message) {
    if (!_enabled) return true;
    if (message.type != LiveMessageType.chat || message.isLocal) return true;

    final normalized = normalize(message.message);
    if (normalized.isEmpty) return true;

    final existing = _pending.remove(normalized);
    if (existing != null) {
      existing.count++;
      _pending[normalized] = existing;
      return false;
    }

    // Bound memory on pathological floods: release the oldest group instead of
    // queueing a new key behind an unbounded set.
    while (_pending.length >= maxPendingKeys) {
      final oldestKey = _pending.keys.first;
      _flushGroup(oldestKey);
    }

    _pending[normalized] = _PendingGroup(first: message, timer: timerFactory(_window, () => _flushGroup(normalized)));
    return true;
  }

  /// Emits a summary for every multi-copy pending group, in arrival order.
  void flushAll() {
    final keys = _pending.keys.toList(growable: false);
    for (final key in keys) {
      _flushGroup(key);
    }
  }

  /// Drops every pending group without emitting (room/session switches). The
  /// first copy of each group was already emitted, so nothing is lost.
  void clear() {
    for (final group in _pending.values) {
      group.timer.cancel();
    }
    _pending.clear();
  }

  void _flushGroup(String key) {
    final group = _pending.remove(key);
    if (group == null) return;
    group.timer.cancel();
    final callback = onEmit;
    if (callback == null) return;
    // Singleton groups are already on screen; only real bursts add a summary.
    if (group.count > 1) callback(_synthesize(group.first, group.count));
  }

  LiveMessage _synthesize(LiveMessage first, int count) {
    return LiveMessage(
      type: first.type,
      userName: first.userName,
      userId: first.userId,
      messageId: 'aggregate:${first.messageId.isEmpty ? first.message.hashCode : first.messageId}:$count',
      message: first.message,
      color: first.color,
      userLevel: first.userLevel,
      fansLevel: first.fansLevel,
      fansName: first.fansName,
      isLocal: false,
      sentAt: first.sentAt,
      style: first.style,
      repeatCount: count,
    );
  }

  static String normalize(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

class _PendingGroup {
  _PendingGroup({required this.first, required this.timer});

  final LiveMessage first;
  Timer timer;
  int count = 1;
}
