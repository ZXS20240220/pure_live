import 'dart:convert';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';

/// 房间卡片外观配置（单一配置，桌面端唯一）。
///
/// 基础版只有 Windows 桌面端，不再区分 mobile/desktop 两套，
/// 也不再提供预设（compact/standard/detailed/custom）和"自动"平台徽章模式。
/// 所有显示项都是独立开关 + 一个圆角滑块，结构扁平。
@immutable
class RoomCardAppearance {
  const RoomCardAppearance({
    required this.showAvatar,
    required this.showAnchorName,
    required this.showPlatformBadge,
    required this.showAudience,
    required this.showReplayBadge,
    required this.showPinBadge,
    required this.showWatchTimeBadge,
    required this.showLastLiveTime,
    required this.cornerRadius,
  });

  static const double defaultCornerRadius = 20;
  static const double minCornerRadius = 0;
  static const double maxCornerRadius = 32;

  /// 与旧"标准预设"视觉接近的默认值，也是 reset 按钮恢复的目标。
  static const RoomCardAppearance standard = RoomCardAppearance(
    showAvatar: true,
    showAnchorName: true,
    showPlatformBadge: false,
    showAudience: true,
    showReplayBadge: true,
    showPinBadge: true,
    showWatchTimeBadge: true,
    showLastLiveTime: true,
    cornerRadius: defaultCornerRadius,
  );

  final bool showAvatar;
  final bool showAnchorName;

  /// 平台徽章（简单开关）：true → 始终显示；false → 隐藏。
  /// 旧的"自动/始终/隐藏"三档已合并为单一开关。
  final bool showPlatformBadge;

  /// 观众热度 / 人气数值开关（紧凑列表和标准卡片共用）。
  final bool showAudience;

  /// 回放徽章（录播房间）：仅标准卡片封面使用。
  final bool showReplayBadge;

  /// 置顶徽章（右上角 pin）：仅当卡片被判定为置顶时渲染（与是否开启此开关无关）。
  final bool showPinBadge;

  /// 累计观看时长徽章（标准卡片封面左下角）。
  final bool showWatchTimeBadge;

  /// 上次直播时间及遮罩（标准卡片封面未开播时）。
  final bool showLastLiveTime;

  final double cornerRadius;

  static double normalizeCornerRadius(num value) {
    final converted = value.toDouble();
    if (!converted.isFinite) return defaultCornerRadius;
    return converted.clamp(minCornerRadius, maxCornerRadius).toDouble();
  }

  static RoomCardAppearance fromJson(
    Map<String, dynamic> json, {
    RoomCardAppearance fallback = standard,
    bool strict = false,
  }) {
    bool readBool(String currentKey, String legacyKey, bool defaultValue) {
      final value = json.containsKey(currentKey) ? json[currentKey] : json[legacyKey];
      if (value == null) return defaultValue;
      if (strict && value is! bool) throw FormatException('$currentKey must be a boolean');
      return value is bool ? value : defaultValue;
    }

    double readRadius() {
      final value = json['cornerRadius'] ?? json['cardBorderRadius'];
      if (value == null) return fallback.cornerRadius;
      if (strict && value is! num) throw const FormatException('cornerRadius must be numeric');
      if (value is! num) return fallback.cornerRadius;
      if (strict && !value.toDouble().isFinite) throw const FormatException('cornerRadius must be finite');
      return normalizeCornerRadius(value);
    }

    // 旧格式会带 automaticPlatformBadge —— 既然已经删除自动模式，
    // 旧的 automaticPlatformBadge=true 表示"自动显示"，现在统一降级为 showPlatformBadge=false（隐藏）。
    final hasExplicitPlatformValue = json.containsKey('showPlatformBadge') || json.containsKey('showPlatform');
    final showPlatformBadge = readBool('showPlatformBadge', 'showPlatform', fallback.showPlatformBadge);
    final legacyAuto = json['automaticPlatformBadge'];
    final migratedPlatformBadge = hasExplicitPlatformValue
        ? showPlatformBadge
        : (legacyAuto == true ? false : showPlatformBadge);

    return RoomCardAppearance(
      showAvatar: readBool('showAvatar', 'showAvatar', fallback.showAvatar),
      showAnchorName: readBool('showAnchorName', 'showSubtitle', fallback.showAnchorName),
      showPlatformBadge: migratedPlatformBadge,
      showAudience: readBool('showAudience', 'showAudience', fallback.showAudience),
      showReplayBadge: readBool('showReplayBadge', 'showRecordBadge', fallback.showReplayBadge),
      showPinBadge: readBool('showPinBadge', 'showPinBadge', fallback.showPinBadge),
      showWatchTimeBadge: readBool('showWatchTimeBadge', 'showWatchTimeBadge', fallback.showWatchTimeBadge),
      showLastLiveTime: readBool('showLastLiveTime', 'showLastLiveTime', fallback.showLastLiveTime),
      cornerRadius: readRadius(),
    );
  }

  RoomCardAppearance copyWith({
    bool? showAvatar,
    bool? showAnchorName,
    bool? showPlatformBadge,
    bool? showAudience,
    bool? showReplayBadge,
    bool? showPinBadge,
    bool? showWatchTimeBadge,
    bool? showLastLiveTime,
    double? cornerRadius,
  }) {
    return RoomCardAppearance(
      showAvatar: showAvatar ?? this.showAvatar,
      showAnchorName: showAnchorName ?? this.showAnchorName,
      showPlatformBadge: showPlatformBadge ?? this.showPlatformBadge,
      showAudience: showAudience ?? this.showAudience,
      showReplayBadge: showReplayBadge ?? this.showReplayBadge,
      showPinBadge: showPinBadge ?? this.showPinBadge,
      showWatchTimeBadge: showWatchTimeBadge ?? this.showWatchTimeBadge,
      showLastLiveTime: showLastLiveTime ?? this.showLastLiveTime,
      cornerRadius: normalizeCornerRadius(cornerRadius ?? this.cornerRadius),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'showAvatar': showAvatar,
      'showAnchorName': showAnchorName,
      'showPlatformBadge': showPlatformBadge,
      'showAudience': showAudience,
      'showReplayBadge': showReplayBadge,
      'showPinBadge': showPinBadge,
      'showWatchTimeBadge': showWatchTimeBadge,
      'showLastLiveTime': showLastLiveTime,
      'cornerRadius': normalizeCornerRadius(cornerRadius),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is RoomCardAppearance &&
        other.showAvatar == showAvatar &&
        other.showAnchorName == showAnchorName &&
        other.showPlatformBadge == showPlatformBadge &&
        other.showAudience == showAudience &&
        other.showReplayBadge == showReplayBadge &&
        other.showPinBadge == showPinBadge &&
        other.showWatchTimeBadge == showWatchTimeBadge &&
        other.showLastLiveTime == showLastLiveTime &&
        other.cornerRadius == cornerRadius;
  }

  @override
  int get hashCode => Object.hash(
    showAvatar,
    showAnchorName,
    showPlatformBadge,
    showAudience,
    showReplayBadge,
    showPinBadge,
    showWatchTimeBadge,
    showLastLiveTime,
    cornerRadius,
  );
}

class RoomCardSettingsController extends GetxController {
  RoomCardSettingsController()
    : config = hiveObject<RoomCardAppearance>(
        // 沿用旧 desktop 存储键，避免 Hive 里静默产生新键但旧配置未被发现；
        // 如果旧键不存在，fallback 就是 standard。
        'room_card_desktop_config',
        _legacyFallback(),
        fromJson: (json) => RoomCardAppearance.fromJson(json, fallback: _legacyFallback()),
        toJson: (value) => value.toJson(),
      );

  static RoomCardSettingsController get to => Get.find<RoomCardSettingsController>();

  /// 旧格式迁移：尝试从旧键读取 desktopConfig → mobileConfig，
  /// 两个都没有就返回 standard。
  static RoomCardAppearance _legacyFallback() {
    for (final key in const ['room_card_desktop_config', 'room_card_mobile_config']) {
      final raw = HivePrefUtil.getString(key);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            return RoomCardAppearance.fromJson(decoded, fallback: RoomCardAppearance.standard);
          }
        } catch (_) {
          // 旧值损坏，跳过
        }
      }
    }
    return RoomCardAppearance.standard;
  }

  final Rx<RoomCardAppearance> config;

  /// 单一配置：RoomCard 及 RoomCardCompact 统一从这里取。
  RoomCardAppearance get current => config.value;

  void updateConfig(RoomCardAppearance value) {
    final normalized = value.copyWith(cornerRadius: value.cornerRadius);
    config.value = normalized;
  }

  void reset() => updateConfig(RoomCardAppearance.standard);

  // ---------- 序列化：新格式，toJson/extractConfig ----------

  Map<String, dynamic> toJson() => config.value.toJson();

  static Map<String, dynamic> extractConfig(Map<String, dynamic>? rootConfig) {
    final parsed = parseConfig(rootConfig ?? const {});
    return (parsed['config'] as RoomCardAppearance).toJson();
  }

  // ---------- 导入：支持旧格式（mobile/desktop 双配置 + preset）和新格式 ----------

  void fromJson(Map<String, dynamic> json) {
    final parsed = parseConfig(json);
    config.value = parsed['config'] as RoomCardAppearance;
  }

  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    // 既可能是 {'roomCard': {...}} 也可能是内部 {...}
    final source = json['roomCard'] is Map ? Map<String, dynamic>.from(json['roomCard'] as Map) : json;

    // 新格式：直接 config 或 room_card_config
    final directJson = _readConfigMap(source, 'config', legacyKey: 'room_card_config');
    if (directJson != null) {
      final appearance = RoomCardAppearance.fromJson(directJson, fallback: RoomCardAppearance.standard, strict: true);
      return {'config': appearance};
    }

    // 旧格式：优先 desktopConfig，fallback mobileConfig → standard
    final desktopJson = _readConfigMap(source, 'desktopConfig', legacyKey: 'room_card_desktop_config');
    final mobileJson = _readConfigMap(source, 'mobileConfig', legacyKey: 'room_card_mobile_config');
    final appearance = (desktopJson ?? mobileJson) == null
        ? RoomCardAppearance.standard
        : RoomCardAppearance.fromJson(desktopJson ?? mobileJson!, fallback: RoomCardAppearance.standard, strict: true);
    return {'config': appearance};
  }

  // ---------- 辅助 ----------

  static Map<String, dynamic>? _readConfigMap(Map<String, dynamic> json, String key, {required String legacyKey}) {
    final value = json.containsKey(key) ? json[key] : json[legacyKey];
    if (value == null) return null;
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw FormatException('$key must be an object');
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw FormatException('$key must be an object');
  }
}
