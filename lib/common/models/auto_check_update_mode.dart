enum AutoCheckUpdateMode {
  /// Do not automatically check for updates.
  off('off'),

  /// Check for all updates including stable and pre-release.
  all('all'),

  /// Only check for stable releases; ignore pre-release versions.
  stableOnly('stable_only');

  const AutoCheckUpdateMode(this.storageValue);

  final String storageValue;

  static AutoCheckUpdateMode parse(Object? value, {AutoCheckUpdateMode fallback = AutoCheckUpdateMode.all}) {
    final normalized = value?.toString().trim();
    for (final mode in values) {
      if (mode.storageValue == normalized) return mode;
    }
    return fallback;
  }
}
