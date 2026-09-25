import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/modules/live_play/controllers/danmaku_aggregator.dart';

/// Manual stand-in for [Timer] so tests can fire window expiry deterministically.
class ManualTimer implements Timer {
  ManualTimer(this._callback);

  final void Function() _callback;
  bool _cancelled = false;

  void fire() {
    if (_cancelled) return;
    _cancelled = true;
    _callback();
  }

  @override
  void cancel() => _cancelled = true;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;
}

void main() {
  LiveMessage message(String text, {String user = 'u1', bool local = false}) => LiveMessage(
    type: LiveMessageType.chat,
    userName: user,
    userId: user,
    message: text,
    color: LiveMessageColor.white,
    isLocal: local,
  );

  /// Builds an aggregator whose window timers are collected into [timers].
  (DanmakuAggregator, List<ManualTimer>) build({int maxPendingKeys = 512, required void Function(LiveMessage) onEmit}) {
    final timers = <ManualTimer>[];
    final aggregator = DanmakuAggregator(
      maxPendingKeys: maxPendingKeys,
      timerFactory: (duration, callback) {
        final timer = ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
    )..setConfig(enabled: true, window: const Duration(seconds: 5));
    aggregator.onEmit = onEmit;
    return (aggregator, timers);
  }

  /// Fires every still-active window timer once (snapshot before firing, so
  /// cascaded flushes do not double-fire).
  void expireWindows(List<ManualTimer> timers) {
    final active = timers.where((timer) => timer.isActive).toList(growable: false);
    for (final timer in active) {
      timer.fire();
    }
  }

  test('first copy of a text key returns true for immediate emission with zero latency', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    // The caller emits the first copy through the normal path; the aggregator
    // only tracks it for potential duplicates.
    expect(aggregator.offer(message('加油')), isTrue);
    expect(emitted, isEmpty);

    expireWindows(timers);
    // Singleton group: message already visible, no summary needed.
    expect(emitted, isEmpty);
  });

  test('swallows duplicates inside the window and appends one "原文 ×N" summary', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('666')), isTrue);
    expect(aggregator.offer(message('666', user: 'u2')), isFalse);
    expect(aggregator.offer(message('  666  ', user: 'u3')), isFalse);

    expireWindows(timers);
    expect(emitted, hasLength(1));
    expect(emitted.single.message, '666 ×3');
    expect(emitted.single.userName, 'u1');
    expect(emitted.single.isLocal, isFalse);
  });

  test('duplicate bursts after a flush start a fresh group', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('666')), isTrue);
    expireWindows(timers);
    // A copy after the flush is the first copy of a new group again.
    expect(aggregator.offer(message('666', user: 'u2')), isTrue);
    expect(aggregator.offer(message('666', user: 'u3')), isFalse);
    expireWindows(timers);

    expect(emitted, hasLength(1));
    expect(emitted.single.message, '666 ×2');
  });

  test('local messages bypass aggregation and disabled state passes through', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('hi', local: true)), isTrue);
    expect(aggregator.pendingKeyCount, 0);

    aggregator.setConfig(enabled: false, window: const Duration(seconds: 5));
    expect(aggregator.offer(message('hi')), isTrue);
    expect(aggregator.pendingKeyCount, 0);
    expect(emitted, isEmpty);
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });

  test('disabling via setConfig flushes multi-copy summaries in arrival order', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isTrue);
    expect(aggregator.offer(message('b')), isTrue);
    expect(aggregator.offer(message('a')), isFalse);

    aggregator.setConfig(enabled: false, window: const Duration(seconds: 5));

    // Only the group with real duplicates produces a summary; the singleton
    // was already visible.
    expect(emitted, hasLength(1));
    expect(emitted.single.message, 'a ×2');
    expect(aggregator.pendingKeyCount, 0);
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });

  test('clear drops pending groups without emitting (session switch)', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isTrue);
    aggregator.clear();
    expect(aggregator.pendingKeyCount, 0);

    expireWindows(timers);
    expect(emitted, isEmpty);
  });

  test('overflowing the pending cap releases the oldest group immediately', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(maxPendingKeys: 2, onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isTrue);
    expect(aggregator.offer(message('b')), isTrue);
    // 'c' evicts the oldest single-copy group without a summary.
    expect(aggregator.offer(message('c')), isTrue);

    expect(aggregator.pendingKeyCount, 2);
    expect(emitted, isEmpty);

    expireWindows(timers);
    expect(aggregator.pendingKeyCount, 0);
    expect(emitted, isEmpty);
  });
}
