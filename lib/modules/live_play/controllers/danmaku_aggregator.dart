import 'dart:async';
import 'dart:collection';

import 'package:pure_live/common/models/live_message.dart';

/// Aggregates a burst of identical chat text into one "原文 ×N" message.
///
/// Unlike [RepeatedDanmakuFilter], which drops every duplicate, this optional
/// upgrade keeps the information: the first message of a text key is held
/// until the window closes. If more copies arrived meanwhile, a synthesized
/// message carrying the first sender's metadata and the "×N" suffix is
/// emitted; otherwise the original message is released unchanged.
///
/// Local messages bypass aggregation. Because held messages belong to one
/// room session, session switches must call [clear] (drop without emitting);
/// user-facing toggles should call [setConfig], which flushes on disable.
class DanmakuAggregator {
  DanmakuAggregator({this.maxPendingKeys = 512, this.timerFactory = Timer.new});

  final int maxPendingKeys;

  /// Injectable so tests can drive window expiry without real async time.
  final Timer Function(Duration duration, void Function() callback) timerFactory;

  /// Called on the UI/release path for flushed groups. Window expiry and the
  /// pending-cap overflow in [offer] may invoke it synchronously.
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
  /// local or empty-text messages pass through untouched). Returns false when
  /// the aggregator consumed the message into a pending group.
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
    return false;
  }

  /// Emits every pending group now, in arrival order.
  void flushAll() {
    final keys = _pending.keys.toList(growable: false);
    for (final key in keys) {
      _flushGroup(key);
    }
  }

  /// Drops every pending group without emitting (room/session switches).
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
    callback(group.count > 1 ? _synthesize(group.first, group.count) : group.first);
  }

  LiveMessage _synthesize(LiveMessage first, int count) {
    return LiveMessage(
      type: first.type,
      userName: first.userName,
      userId: first.userId,
      // A fresh identity keeps replay suppression and list diffing from
      // treating the aggregate as a duplicate of the original message.
      messageId: 'aggregate:${first.messageId.isEmpty ? first.message.hashCode : first.messageId}:$count',
      message: '${first.message} ×$count',
      color: first.color,
      userLevel: first.userLevel,
      fansLevel: first.fansLevel,
      fansName: first.fansName,
      isLocal: false,
      sentAt: first.sentAt,
      style: first.style,
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
