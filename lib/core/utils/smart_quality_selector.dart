import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:pure_live/model/live_play_quality.dart';

enum _QualityTier {
  original(99999),
  bluray(1080),
  superHD(720),
  high(540),
  standard(360),
  smooth(240),
  unknown(0);

  final int tierHeight;
  const _QualityTier(this.tierHeight);
}

class _ParsedQuality {
  final LivePlayQuality source;
  final _QualityTier tier;
  final int height;
  final int bitrateMbps;
  final int fps;

  const _ParsedQuality({
    required this.source,
    required this.tier,
    required this.height,
    required this.bitrateMbps,
    required this.fps,
  });

  int get sortHeight => tier.tierHeight > 0 ? tier.tierHeight : height;
}

class SmartQualitySelector {
  static const String sentinel = '__smart__';

  static Future<int> select({required List<LivePlayQuality> qualities}) async {
    if (qualities.isEmpty) return -1;
    if (qualities.length == 1) return 0;

    final targetHeight = await _deviceShortEdgeHeight();
    if (targetHeight <= 0) return 0;

    final parsed = qualities.map(_parseQuality).toList(growable: false);
    return _pickIndex(parsed, targetHeight);
  }

  static int selectSync({required List<LivePlayQuality> qualities, int targetHeightOverride = 0}) {
    if (qualities.isEmpty) return -1;
    if (qualities.length == 1) return 0;

    final targetHeight = targetHeightOverride > 0 ? targetHeightOverride : _deviceShortEdgeHeightSync();

    final parsed = qualities.map(_parseQuality).toList(growable: false);
    return _pickIndex(parsed, targetHeight);
  }

  static int _pickIndex(List<_ParsedQuality> parsed, int targetHeight) {
    final candidates = parsed.where((q) => q.sortHeight >= targetHeight).toList(growable: false);

    final pool = candidates.isNotEmpty ? candidates : parsed;

    pool.sort((a, b) {
      final hc = a.sortHeight.compareTo(b.sortHeight);
      if (hc != 0) return hc;
      final bc = a.bitrateMbps.compareTo(b.bitrateMbps);
      if (bc != 0) return bc;
      final fc = a.fps.compareTo(b.fps);
      if (fc != 0) return fc;
      return 0;
    });

    final chosen = pool.first;
    return parsed.indexOf(chosen);
  }

  static _ParsedQuality _parseQuality(LivePlayQuality q) {
    final label = q.quality;
    final tier = _detectTier(label);
    final height = _extractHeight(label);
    final bitrateMbps = _extractBitrateMbps(label);
    final fps = _extractFps(label);

    return _ParsedQuality(source: q, tier: tier, height: height, bitrateMbps: bitrateMbps, fps: fps);
  }

  static _QualityTier _detectTier(String label) {
    final lc = label.toLowerCase();

    if (_hasAny(lc, ['原画', 'original', 'origin', 'source'])) return _QualityTier.original;
    if (_hasAny(lc, ['蓝光', 'bluray', 'blueray', 'blue'])) return _QualityTier.bluray;
    if (_hasAny(lc, ['超清', 'fullhd', 'fhd'])) return _QualityTier.superHD;
    if (_hasAny(lc, ['高清', 'hd', 'high'])) return _QualityTier.high;
    if (_hasAny(lc, ['标清', 'sd', 'standard'])) return _QualityTier.standard;
    if (_hasAny(lc, ['流畅', 'smooth', 'fluent', 'ld', 'low'])) return _QualityTier.smooth;

    return _QualityTier.unknown;
  }

  static int _extractHeight(String label) {
    final m = RegExp(r'(\d{3,5})\s*[x×]\s*(\d{3,5})', caseSensitive: false).firstMatch(label);
    if (m != null) {
      final w = int.tryParse(m.group(1) ?? '') ?? 0;
      final h = int.tryParse(m.group(2) ?? '') ?? 0;
      return min(w, h);
    }

    final p = RegExp(r'(\d{3,5})\s*[pP]').firstMatch(label);
    if (p != null) return int.tryParse(p.group(1) ?? '') ?? 0;

    return 0;
  }

  static int _extractBitrateMbps(String label) {
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*[Mm][Bb]?(?:[Pp]?[Ss])?').firstMatch(label);
    if (m != null) {
      final val = double.tryParse(m.group(1) ?? '') ?? 0;
      if (val > 0 && val < 1000) return val.round();
    }

    final k = RegExp(r'(\d{4,})\s*[Kk][Bb]?(?:[Pp]?[Ss])?').firstMatch(label);
    if (k != null) {
      final val = int.tryParse(k.group(1) ?? '') ?? 0;
      if (val > 0) return (val / 1000).round();
    }

    final b = RegExp(r'(\d{6,})\s*[Bb][Pp][Ss]?').firstMatch(label);
    if (b != null) {
      final val = int.tryParse(b.group(1) ?? '') ?? 0;
      if (val > 0) return (val / 1000000).round();
    }

    return 0;
  }

  static int _extractFps(String label) {
    final m = RegExp(r'(\d{2,3})\s*[Ff][Pp][Ss]?').firstMatch(label);
    if (m != null) return int.tryParse(m.group(1) ?? '') ?? 0;
    return 0;
  }

  static bool _hasAny(String haystack, List<String> needles) {
    for (final n in needles) {
      if (haystack.contains(n.toLowerCase())) return true;
    }
    return false;
  }

  static Future<int> _deviceShortEdgeHeight() async => _deviceShortEdgeHeightSync();

  static int _deviceShortEdgeHeightSync() {
    try {
      final displays = PlatformDispatcher.instance.displays;
      if (displays.isEmpty) return 1080;
      int maxShort = 0;
      for (final d in displays) {
        final w = d.size.width.round();
        final h = d.size.height.round();
        final shortSide = min(w, h);
        if (shortSide > maxShort) maxShort = shortSide;
      }
      return maxShort > 0 ? maxShort : 1080;
    } catch (_) {
      return 1080;
    }
  }
}
