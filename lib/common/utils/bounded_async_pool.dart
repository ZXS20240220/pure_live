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

  final cancelSignal = StreamController<void>.broadcast(sync: true);
  StreamSubscription<void>? cancelListener;
  if (shouldCancel != null) {
    final cancelFn = shouldCancel;
    cancelListener = Stream.periodic(const Duration(milliseconds: 30))
        .takeWhile((_) => !cancelFn())
        .listen(
          null,
          onDone: () {
            if (cancelFn() && !cancelSignal.isClosed) {
              cancelSignal.add(null);
            }
          },
        );
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
        final cancelled = cancelSignal.stream.first.then((_) => false);
        final wasCancelled = !(await Future.any([taskDone, cancelled]));
        if (wasCancelled) return;
        if (shouldCancel()) return;
        results[index] = await taskFuture;
      }
    }
  }

  try {
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
  } finally {
    await cancelListener?.cancel();
    await cancelSignal.close();
  }
  return results;
}
