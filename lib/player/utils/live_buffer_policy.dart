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

  static Future<void> apply(Future<void> Function(String name, String value) setProperty) async {
    // Network cache-secs takes precedence over the smaller base readahead.
    // Set the whole contract before opening media, including inherited values.
    await setProperty('cache', 'yes');
    await setProperty('cache-on-disk', 'no');
    await setProperty('cache-secs', cacheSeconds.toString());
    await setProperty('demuxer-max-bytes', forwardBytes.toString());
    await setProperty('demuxer-max-back-bytes', backBytes.toString());
    // Past media must not borrow the unused forward reserve. Otherwise low
    // bitrate live streams keep accumulating minutes of unwanted back cache.
    await setProperty('demuxer-donate-buffer', 'no');
    await setProperty('demuxer-readahead-secs', readaheadSeconds.toString());
  }
}
