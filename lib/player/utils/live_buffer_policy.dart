/// Bounded low-latency buffer budget for live streams with timeshift support.
///
/// Forward media is bounded by both bytes and time, rather than inheriting
/// media_kit's disk cache (where byte limits only bound packet metadata).
/// This is a demux buffer budget, not a bound on decoder/GPU/process memory.
/// The back buffer stays large so timeshift seeking inside `cache-secs`
/// never has to reconnect the live source.
abstract final class LiveBufferPolicy {
  // Forward cap kept close to mpv's default (~143 MB) so the playhead stays
  // near the live edge instead of being pushed left by a huge pre-read
  // buffer. The back buffer remains large for timeshift seeking.
  static const int forwardBytes = 150 * 1024 * 1024;
  static const int backBytes = 256 * 1024 * 1024;
  static const int readaheadSeconds = 5;
  static const int cacheSeconds = 6;

  /// 弱网预设：更大的缓存与重读缓冲，牺牲延迟换稳定。
  static const int weakForwardBytes = 300 * 1024 * 1024;
  static const int weakBackBytes = 512 * 1024 * 1024;
  static const int weakReadaheadSeconds = 30;
  static const int weakCacheSeconds = 120;

  /// 低延迟预设：极小缓存，前向丢帧，追求接近实时。
  static const int lowLatencyForwardBytes = 8 * 1024 * 1024;
  static const int lowLatencyBackBytes = 64 * 1024 * 1024;
  static const int lowLatencyReadaheadSeconds = 1;
  static const int lowLatencyCacheSeconds = 1;

  static Future<void> apply(
    Future<void> Function(String name, String value) setProperty, {
    String preset = 'balanced',
  }) async {
    final int forward;
    final int back;
    final int readahead;
    final int cache;
    switch (preset) {
      case 'weakNetwork':
        forward = weakForwardBytes;
        back = weakBackBytes;
        readahead = weakReadaheadSeconds;
        cache = weakCacheSeconds;
        break;
      case 'lowLatency':
        forward = lowLatencyForwardBytes;
        back = lowLatencyBackBytes;
        readahead = lowLatencyReadaheadSeconds;
        cache = lowLatencyCacheSeconds;
        break;
      case 'balanced':
      default:
        forward = forwardBytes;
        back = backBytes;
        readahead = readaheadSeconds;
        cache = cacheSeconds;
        break;
    }

    // Network cache-secs takes precedence over the smaller base readahead.
    // Set the whole contract before opening media, including inherited values.
    await setProperty('cache', 'yes');
    await setProperty('cache-on-disk', 'no');
    await setProperty('cache-secs', cache.toString());
    await setProperty('demuxer-max-bytes', forward.toString());
    await setProperty('demuxer-max-back-bytes', back.toString());
    // Past media must not borrow the unused forward reserve. Otherwise low
    // bitrate live streams keep accumulating minutes of unwanted back cache.
    await setProperty('demuxer-donate-buffer', 'no');
    await setProperty('demuxer-readahead-secs', readahead.toString());

    // 低延迟模式：开启前向丢帧，丢弃过期的缓存帧以追赶直播边缘。
    if (preset == 'lowLatency') {
      await setProperty('cache-pause', 'no');
    }
  }
}
