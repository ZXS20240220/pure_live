import 'dart:async';
import 'dart:math' as math;

Future<List<R?>> boundedAsyncMap<T, R>(
  Iterable<T> items, {
  required int maxConcurrent,
  required Future<R?> Function(T item) task,
  bool Function()? shouldCancel,
}) async {
  final source = List<T>.of(items, growable: false);
  if (source.isEmpty) return <R?>[];

  final results = List<R?>.filled(source.length, null, growable: false);
  final workerCount = math.min(math.max(1, maxConcurrent), source.length);
  var nextIndex = 0;

  final cancelSignal = Completer<void>.sync();
  Timer? cancelPoller;
  if (shouldCancel != null) {
    final cancelFn = shouldCancel;
    void poll() {
      if (cancelFn()) {
        if (!cancelSignal.isCompleted) cancelSignal.complete();
        return;
      }
      cancelPoller = Timer(const Duration(milliseconds: 30), poll);
    }

    poll();
  }

  Future<void> worker() async {
    while (true) {
      if (shouldCancel?.call() == true) return;
      final index = nextIndex++;
      if (index >= source.length) return;
      final taskFuture = task(source[index]);
      if (shouldCancel == null) {
        results[index] = await taskFuture;
      } else {
        final taskDone = taskFuture.then((_) => true);
        final cancelled = cancelSignal.future.then((_) => false);
        final wasCancelled = !(await Future.any([taskDone, cancelled]));
        if (wasCancelled) return;
        results[index] = await taskFuture;
      }
    }
  }

  try {
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
  } finally {
    cancelPoller?.cancel();
    if (!cancelSignal.isCompleted) cancelSignal.complete();
  }
  return results;
}
