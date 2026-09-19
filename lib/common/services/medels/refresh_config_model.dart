class RefreshConfig {
  final bool autoRefreshFavorite;
  final bool refreshFavoriteOnResume;
  final int autoRefreshInterval;
  final int maxConcurrentRefresh;
  final bool autoRefreshThumbnails;
  final int thumbnailRefreshInterval;

  /// 刷新成功保护间隔（秒）：同一房间刷新成功后的最短请求间隔。
  final int successCooldownSeconds;

  /// 刷新失败保护间隔（分钟）：刷新失败后的重试等待时间。
  final int failureRetryMinutes;

  RefreshConfig({
    required this.autoRefreshFavorite,
    required this.refreshFavoriteOnResume,
    required this.autoRefreshInterval,
    required this.maxConcurrentRefresh,
    required this.autoRefreshThumbnails,
    required this.thumbnailRefreshInterval,
    required this.successCooldownSeconds,
    required this.failureRetryMinutes,
  });
}
