import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';

void main() {
  group('refresh settings migration', () {
    test('keeps automatic thumbnail refresh opt-in for older backups', () {
      final config = RefreshConfigController.extractConfig({
        'refresh': {'autoRefreshFavorite': true},
      });

      expect(config['autoRefreshFavorite'], isTrue);
      expect(config['refreshFavoriteOnResume'], isTrue);
      expect(config['autoRefreshThumbnails'], isFalse);
      expect(config['thumbnailRefreshInterval'], 30);
      expect(config['maxConcurrentRefresh'], RefreshConfigController.defaultMaxConcurrentRefresh);
    });

    test('preserves unrelated refresh and root settings', () {
      final root = <String, dynamic>{
        'refresh': {'autoRefreshFavorite': true},
        'player': {'engine': 'mediaKit'},
      };

      final merged = RefreshConfigController.mergeConfig(root, {
        'autoRefreshThumbnails': true,
        'thumbnailRefreshInterval': 60,
      });

      expect(merged['player'], {'engine': 'mediaKit'});
      expect(merged['refresh']['autoRefreshFavorite'], isTrue);
      expect(merged['refresh']['autoRefreshThumbnails'], isTrue);
      expect(merged['refresh']['thumbnailRefreshInterval'], 60);
    });

    test('normalizes invalid concurrency without hiding advanced values', () {
      expect(RefreshConfigController.normalizeMaxConcurrentRefresh(0), 1);
      expect(RefreshConfigController.normalizeMaxConcurrentRefresh(6), 6);
      expect(
        RefreshConfigController.normalizeMaxConcurrentRefresh(99),
        RefreshConfigController.maxAllowedConcurrentRefresh,
      );
    });

    test('keeps refresh timers inside the supported operating window', () {
      expect(RefreshConfigController.normalizeRefreshInterval(-1), RefreshConfigController.minRefreshInterval);
      expect(RefreshConfigController.normalizeRefreshInterval(90), 90);
      expect(RefreshConfigController.normalizeRefreshInterval(999), RefreshConfigController.maxRefreshInterval);

      final parsed = RefreshConfigController.parseConfig({'autoRefreshInterval': 0, 'thumbnailRefreshInterval': 999});
      expect(parsed['autoRefreshInterval'], RefreshConfigController.minRefreshInterval);
      expect(parsed['thumbnailRefreshInterval'], RefreshConfigController.maxRefreshInterval);
    });

    test('clamps cooldown settings into the 0-60 window and defaults when absent', () {
      expect(RefreshConfigController.normalizeSuccessCooldownSeconds(null), 15);
      expect(RefreshConfigController.normalizeSuccessCooldownSeconds(-5), 0);
      expect(RefreshConfigController.normalizeSuccessCooldownSeconds(45), 45);
      expect(RefreshConfigController.normalizeSuccessCooldownSeconds(999), 60);

      expect(RefreshConfigController.normalizeFailureRetryMinutes(null), 5);
      expect(RefreshConfigController.normalizeFailureRetryMinutes(-5), 0);
      expect(RefreshConfigController.normalizeFailureRetryMinutes(12), 12);
      expect(RefreshConfigController.normalizeFailureRetryMinutes(999), 60);

      final parsed = RefreshConfigController.parseConfig({
        'refreshSuccessCooldownSeconds': -1,
        'refreshFailureRetryMinutes': 999,
      });
      expect(parsed['refreshSuccessCooldownSeconds'], 0);
      expect(parsed['refreshFailureRetryMinutes'], 60);

      final extracted = RefreshConfigController.extractConfig({'refresh': <String, dynamic>{}});
      expect(extracted['refreshSuccessCooldownSeconds'], RefreshConfigController.defaultSuccessCooldownSeconds);
      expect(extracted['refreshFailureRetryMinutes'], RefreshConfigController.defaultFailureRetryMinutes);
    });

    test('normalizes legacy refresh intervals while preserving unrelated fields', () {
      final config = RefreshConfigController.extractConfig({
        'refresh': {'autoRefreshFavorite': true, 'autoRefreshInterval': -30, 'thumbnailRefreshInterval': 10000},
      });

      expect(config['autoRefreshFavorite'], isTrue);
      expect(config['autoRefreshInterval'], RefreshConfigController.minRefreshInterval);
      expect(config['thumbnailRefreshInterval'], RefreshConfigController.maxRefreshInterval);
    });
  });
}
