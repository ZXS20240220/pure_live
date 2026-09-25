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

  test('holds the first message and releases it unchanged when no duplicate arrives', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('加油')), isFalse);
    expect(emitted, isEmpty);

    expireWindows(timers);
    expect(emitted, hasLength(1));
    expect(emitted.single.message, '加油');
    expect(emitted.single.userName, 'u1');
  });

  test('merges duplicates into "原文 ×N" carrying the first sender metadata', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('666')), isFalse);
    expect(aggregator.offer(message('666', user: 'u2')), isFalse);
    expect(aggregator.offer(message('  666  ', user: 'u3')), isFalse);

    expireWindows(timers);
    expect(emitted, hasLength(1));
    expect(emitted.single.message, '666 ×3');
    expect(emitted.single.userName, 'u1');
    expect(emitted.single.isLocal, isFalse);
  });

  test('duplicate bursts after a flush start a new group', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('666')), isFalse);
    expireWindows(timers);
    expect(aggregator.offer(message('666', user: 'u2')), isFalse);
    expireWindows(timers);

    expect(emitted, hasLength(2));
    expect(emitted[0].message, '666');
    expect(emitted[1].message, '666 ×2');
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

  test('disabling via setConfig flushes held groups in arrival order', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isFalse);
    expect(aggregator.offer(message('b')), isFalse);
    expect(aggregator.offer(message('a')), isFalse);

    aggregator.setConfig(enabled: false, window: const Duration(seconds: 5));

    expect(emitted, hasLength(2));
    expect(emitted[0].message, 'a ×2');
    expect(emitted[1].message, 'b');
    expect(aggregator.pendingKeyCount, 0);
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });

  test('clear drops pending groups without emitting (session switch)', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isFalse);
    aggregator.clear();
    expect(aggregator.pendingKeyCount, 0);

    expireWindows(timers);
    expect(emitted, isEmpty);
  });

  test('overflowing the pending cap releases the oldest group immediately', () {
    final emitted = <LiveMessage>[];
    final (aggregator, timers) = build(maxPendingKeys: 2, onEmit: emitted.add);

    expect(aggregator.offer(message('a')), isFalse);
    expect(aggregator.offer(message('b')), isFalse);
    expect(aggregator.offer(message('c')), isFalse);

    expect(aggregator.pendingKeyCount, 2);
    expect(emitted, hasLength(1));
    expect(emitted.single.message, 'a');

    expireWindows(timers);
    expect(emitted, hasLength(3));
  });
}
