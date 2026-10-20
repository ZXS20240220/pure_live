import 'dart:async';

import 'package:pure_live/get/get.dart';

/// 追踪应用自启动以来的运行时间，每秒更新一次 [uptimeText]。
///
/// 在 [AppUptimeTracker.start] 被调用后，Timer 会持续运行直到应用进程结束。
/// 调用 [dispose] 可显式停止（主要用于测试）。
class AppUptimeTracker {
  static final AppUptimeTracker instance = AppUptimeTracker._internal();

  AppUptimeTracker._internal();

  DateTime? _startTime;
  Timer? _timer;

  /// 自应用启动以来的格式化运行时间文本，每秒更新。
  /// 格式示例：`1小时23分45秒` / `2分30秒` / `45秒`
  final RxString uptimeText = ''.obs;

  /// 启动时间（首次调用 [start] 时的时间戳）。
  DateTime? get startTime => _startTime;

  /// 是否已启动。
  bool get isRunning => _timer != null && _startTime != null;

  /// 记录启动时间并启动每秒更新的 Timer。
  /// 重复调用安全，会返回第一次启动的结果。
  void start() {
    if (isRunning) return;
    _startTime = DateTime.now();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _update());
  }

  void _update() {
    final start = _startTime;
    if (start == null) return;
    final elapsed = DateTime.now().difference(start);
    uptimeText.value = _formatDuration(elapsed);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _startTime = null;
    uptimeText.value = '';
  }

  /// 将 Duration 格式化为紧凑的中文运行时间字符串。
  static String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '$hours小时${minutes.toString().padLeft(2, '0')}分${seconds.toString().padLeft(2, '0')}秒';
    } else if (minutes > 0) {
      return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
    } else {
      return '$seconds秒';
    }
  }
}
