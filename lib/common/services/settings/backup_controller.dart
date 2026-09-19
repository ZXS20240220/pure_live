import 'dart:io';
import 'dart:convert';

import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';
import 'package:pure_live/common/services/settings/web_dav_controller.dart';
import 'package:pure_live/common/services/settings/history_controller.dart';
import 'package:pure_live/common/services/settings/startup_controller.dart';
import 'package:pure_live/common/services/settings/window_size_controller.dart';
import 'package:pure_live/common/services/settings/app_settings_controller.dart';
import 'package:pure_live/common/services/settings/favorite_room_controller.dart';
import 'package:pure_live/common/services/settings/font_settings_controller.dart';
import 'package:pure_live/common/services/settings/iptv_settings_controller.dart';
import 'package:pure_live/common/services/settings/exit_settings_controller.dart';
import 'package:pure_live/common/services/settings/page_settings_controller.dart';
import 'package:pure_live/common/services/settings/refresh_config_controller.dart';
import 'package:pure_live/common/services/settings/theme_settings_controller.dart';
import 'package:pure_live/common/services/settings/proxy_settings_controller.dart';
import 'package:pure_live/common/services/settings/player_settings_controller.dart';
import 'package:pure_live/common/services/settings/volume_settings_controller.dart';
import 'package:pure_live/common/services/settings/cookie_settings_controller.dart';
import 'package:pure_live/common/services/settings/danmaku_settings_controller.dart';
import 'package:pure_live/common/services/settings/panel_size_controller.dart';
import 'package:pure_live/modules/favorite/favorite_controller.dart';
import 'package:pure_live/common/services/settings/room_card_settings_controller.dart';

enum BackupRestoreScope { all, favorites }

class BackupController extends GetxController {
  static BackupController get to => Get.find();

  static const int backupVersion = 3;
  static bool _restoreInProgress = false;

  final RxString backupDirectory = hiveString('backupDirectory', '');

  Map<String, dynamic> exportAllSettings({bool includeSensitiveData = true}) {
    if (!Get.isRegistered<TagManagementController>()) {
      Get.put(TagManagementController());
    }

    final data = <String, dynamic>{
      'backupVersion': backupVersion,
      'sensitiveDataIncluded': includeSensitiveData,
      'app': Get.find<AppSettingsController>().toJson(),
      'theme': Get.find<ThemeSettingsController>().toJson(),
      'roomCard': Get.find<RoomCardSettingsController>().toJson(),
      'font': Get.find<FontSettingsController>().toJson(),
      'player': Get.find<PlayerSettingsController>().toJson(),
      'danmaku': Get.find<DanmakuSettingsController>().toJson(),
      'volume': Get.find<VolumeSettingsController>().toJson(),
      'favorite': Get.find<FavoriteRoomController>().toJson(),
      'history': Get.find<HistoryController>().toJson(),
      'iptv': Get.find<IptvSettingsController>().toJson(),
      'proxy': Get.find<ProxySettingsController>().toJson(),
      'windowSize': Get.find<WindowSizeController>().toJson(),
      'exit': Get.find<ExitSettingsController>().toJson(),
      'startup': Get.find<StartupController>().toJson(),
      'tags': Get.find<TagManagementController>().exportToJson(),
      'refresh': Get.find<RefreshConfigController>().toJson(),
      'page': Get.find<PageSettingsController>().toJson(),
      'panelSize': Get.find<PanelSizeController>().toJson(),
      'backupDirectory': backupDirectory.v,
    };

    // 收藏页置顶/排序偏好（5.2）。控制器由 lazyPut 注册，仅在已实例化时导出：
    // 未实例化说明用户从未改动过这些值，导出默认值反而会覆盖接收方的自定义。
    if (Get.isRegistered<FavoriteController>()) {
      final favCtrl = Get.find<FavoriteController>();
      data['favoriteCtrl'] = {
        'enablePinned': favCtrl.enablePinned.v,
        'onlineSortMode': favCtrl.onlineSortMode.v.name,
        'onlineSortOrder': favCtrl.onlineSortAscending.v ? 'asc' : 'desc',
      };
    }

    if (includeSensitiveData) {
      data['webdav'] = Get.find<WebDavController>().toJson();
      data['cookie'] = Get.find<CookieSettingsController>().toJson();
    }
    return data;
  }

  /// Removes credentials and session cookies before a backup leaves the device.
  static Map<String, dynamic> redactSensitiveData(Map<String, dynamic> source) {
    final result = Map<String, dynamic>.from(source)
      ..remove('webdav')
      ..remove('cookie');
    result['sensitiveDataIncluded'] = false;
    return result;
  }

  // Derive recognized wire keys from the existing canonical configuration
  // extractors, rather than maintaining another list of hundreds of fields.
  static final Map<String, Set<String>> _sectionKeys = {
    'app': AppSettingsController.extractConfig(null).keys.toSet(),
    'theme': ThemeSettingsController.extractConfig(null).keys.toSet()..add('languageName'),
    'roomCard': RoomCardSettingsController.extractConfig(null).keys.toSet()
      ..addAll({
        'room_card_mobile_preset',
        'room_card_desktop_preset',
        'room_card_mobile_config',
        'room_card_desktop_config',
      }),
    'font': FontSettingsController.extractConfig(null).keys.toSet(),
    'player': PlayerSettingsController.extractConfig(null).keys.toSet(),
    'danmaku': DanmakuSettingsController.extractConfig(null).keys.toSet()..add('pipDanmaNoEmojiMode'),
    'volume': VolumeSettingsController.extractConfig(null).keys.toSet(),
    'favorite': FavoriteRoomController.extractConfig(null).keys.toSet(),
    'history': HistoryController.extractConfig(null).keys.toSet(),
    'webdav': WebDavController.extractConfig(null).keys.toSet(),
    'iptv': IptvSettingsController.extractConfig(null).keys.toSet(),
    'cookie': CookieSettingsController.extractConfig(null).keys.toSet(),
    'proxy': ProxySettingsController.extractConfig(null).keys.toSet(),
    'windowSize': WindowSizeController.extractConfig(null).keys.toSet(),
    'exit': ExitSettingsController.extractConfig(null).keys.toSet(),
    'startup': StartupController.extractConfig(null).keys.toSet(),
    'refresh': RefreshConfigController.extractConfig(null).keys.toSet(),
    'page': PageSettingsController.extractConfig(null).keys.toSet(),
    'panelSize': {'panelWidth', 'immersiveOpacity'},
    'favoriteCtrl': {'enablePinned', 'onlineSortMode', 'onlineSortOrder'},
    'tags': {'tags', 'roomTagsMap'},
  };

  static int countConfigSections(Map<String, dynamic> data) {
    return _sectionKeys.keys.where(data.containsKey).length;
  }

  static void validateBackupIdentity(Map<String, dynamic> data) {
    final version = data['backupVersion'];
    if (version != null && (version is! int || version < 1)) {
      throw const FormatException('Invalid backup version');
    }
    bool recognized = false;
    if (version == null) {
      final legacyTags = data['custom_tags_data'];
      recognized =
          (legacyTags is Map && legacyTags.keys.any(_sectionKeys['tags']!.contains)) ||
          data.containsKey('pipDanmaNoEmojiMode') ||
          _sectionKeys.entries
              .where((entry) => entry.key != 'tags')
              .any((entry) => data.keys.any(entry.value.contains));
    } else {
      validateSectionStructure(data);
      recognized = _sectionKeys.entries.any((entry) {
        final section = data[entry.key];
        return section is Map && section.keys.any(entry.value.contains);
      });
      // 备份目录是字符串段，不参与 Map 段校验，但仍是合法的导入目标
      // （远程同步预览页可能只勾选该段）。
      if (!recognized && data['backupDirectory'] is String) recognized = true;
    }
    if (!recognized) throw const FormatException('No recognized backup settings');
  }

  void importAllSettings(Map<String, dynamic> data) {
    validateBackupIdentity(data);
    final version = data['backupVersion'];

    // Validate input before any controller notifies observers or persists it.
    // This does not make asynchronous storage failures transactional.
    if (version != null) validateSectionStructure(data);
    final parsers = <String, Map<String, dynamic> Function(Map<String, dynamic>)>{
      'app': AppSettingsController.parseConfig,
      'player': PlayerSettingsController.parseConfig,
      'danmaku': DanmakuSettingsController.parseConfig,
      'windowSize': WindowSizeController.parseConfig,
      'theme': ThemeSettingsController.parseConfig,
      'roomCard': RoomCardSettingsController.parseConfig,
      'font': FontSettingsController.parseConfig,
      'exit': ExitSettingsController.parseConfig,
      'iptv': IptvSettingsController.parseConfig,
      'startup': StartupController.parseConfig,
      'proxy': ProxySettingsController.parseConfig,
      'refresh': RefreshConfigController.parseConfig,
      'cookie': CookieSettingsController.parseConfig,
      'favorite': FavoriteRoomController.parseConfig,
      'history': HistoryController.parseConfig,
      'webdav': WebDavController.parseConfig,
      'page': PageSettingsController.parseConfig,
    };
    for (final entry in parsers.entries) {
      if (version == null) {
        entry.value(data);
      } else if (data.containsKey(entry.key)) {
        entry.value(Map<String, dynamic>.from(data[entry.key] ?? {}));
      }
    }
    final tags = version == null ? data['custom_tags_data'] : data['tags'];
    if (tags != null) {
      TagManagementController.parseConfig(Map<String, dynamic>.from(tags));
    }
    if (version == null) {
      VolumeSettingsController.parseConfig(data);
    } else {
      VolumeSettingsController.parseConfig(Map<String, dynamic>.from(data['volume'] ?? {}));
      // Validate the legacy player-owned flag after normalizing its ownership.
      WindowSizeController.parseConfig(WindowSizeController.extractConfig(data));
    }

    if (version == null) {
      _importLegacy(data);
      return;
    }

    switch (version) {
      case 2:
      case 3:
        _importV2(data);
        break;

      default:
        _importLatestCompatible(data);
        break;
    }
  }

  /// 选择性导入：只应用 [allowedKeys] 中选中的模块，未选中模块的控制器
  /// 不被触碰，保持当前值不变。远程同步预览页在用户勾选数据块后调用。
  void importPartialSettings(Map<String, dynamic> data, Set<String> allowedKeys) {
    validateBackupIdentity(data);
    final version = data['backupVersion'];

    if (version != null) validateSectionStructure(data);

    // 与 importAllSettings 相同的解析链，仅应用选中的模块。
    final parsers = <String, Map<String, dynamic> Function(Map<String, dynamic>)>{
      'app': AppSettingsController.parseConfig,
      'player': PlayerSettingsController.parseConfig,
      'danmaku': DanmakuSettingsController.parseConfig,
      'windowSize': WindowSizeController.parseConfig,
      'theme': ThemeSettingsController.parseConfig,
      'roomCard': RoomCardSettingsController.parseConfig,
      'font': FontSettingsController.parseConfig,
      'exit': ExitSettingsController.parseConfig,
      'iptv': IptvSettingsController.parseConfig,
      'startup': StartupController.parseConfig,
      'proxy': ProxySettingsController.parseConfig,
      'refresh': RefreshConfigController.parseConfig,
      'cookie': CookieSettingsController.parseConfig,
      'favorite': FavoriteRoomController.parseConfig,
      'history': HistoryController.parseConfig,
      'webdav': WebDavController.parseConfig,
      'page': PageSettingsController.parseConfig,
    };
    for (final entry in parsers.entries) {
      if (!allowedKeys.contains(entry.key)) continue;
      if (version == null) {
        entry.value(data);
      } else if (data.containsKey(entry.key)) {
        entry.value(Map<String, dynamic>.from(data[entry.key] ?? {}));
      }
    }
    final tags = version == null ? data['custom_tags_data'] : data['tags'];
    if (allowedKeys.contains('tags') && tags != null) {
      TagManagementController.parseConfig(Map<String, dynamic>.from(tags));
    }
    if (version == null) {
      if (allowedKeys.contains('volume')) {
        VolumeSettingsController.parseConfig(data);
      }
      _importLegacyPartial(data, allowedKeys);
      return;
    }
    if (allowedKeys.contains('volume')) {
      VolumeSettingsController.parseConfig(Map<String, dynamic>.from(data['volume'] ?? {}));
    }
    // windowSize 的导入依赖 extractConfig 回读 player 块中的旧版字段位置，
    // 调用方（远程同步合并器）保证只勾选 windowSize 时也附带过滤后的
    // player 块；它不在 allowedKeys 中，不会被导入。
    if (allowedKeys.contains('windowSize')) {
      WindowSizeController.parseConfig(WindowSizeController.extractConfig(data));
    }

    switch (version) {
      case 2:
      case 3:
        _importV2Partial(data, allowedKeys);
        break;

      default:
        _importV2Partial(data, allowedKeys);
        break;
    }
  }

  void _importV2Partial(Map<String, dynamic> data, Set<String> allowedKeys) {
    if (allowedKeys.contains('app')) {
      Get.find<AppSettingsController>().fromJson(Map<String, dynamic>.from(data['app'] ?? {}));
    }

    if (allowedKeys.contains('theme')) {
      Get.find<ThemeSettingsController>().fromJson(Map<String, dynamic>.from(data['theme'] ?? {}));
    }

    if (allowedKeys.contains('roomCard')) {
      Get.find<RoomCardSettingsController>().fromJson(Map<String, dynamic>.from(data['roomCard'] ?? {}));
    }

    if (allowedKeys.contains('font')) {
      Get.find<FontSettingsController>().fromJson(Map<String, dynamic>.from(data['font'] ?? {}));
    }

    if (allowedKeys.contains('player')) {
      Get.find<PlayerSettingsController>().fromJson(Map<String, dynamic>.from(data['player'] ?? {}));
    }

    if (allowedKeys.contains('danmaku')) {
      Get.find<DanmakuSettingsController>().fromJson(Map<String, dynamic>.from(data['danmaku'] ?? {}));
    }

    if (allowedKeys.contains('volume')) {
      Get.find<VolumeSettingsController>().fromJson(Map<String, dynamic>.from(data['volume'] ?? {}));
    }

    if (allowedKeys.contains('favorite')) {
      Get.find<FavoriteRoomController>().fromJson(Map<String, dynamic>.from(data['favorite'] ?? {}));
    }

    if (allowedKeys.contains('history')) {
      Get.find<HistoryController>().fromJson(Map<String, dynamic>.from(data['history'] ?? {}));
    }

    if (allowedKeys.contains('webdav') && data.containsKey('webdav')) {
      Get.find<WebDavController>().fromJson(Map<String, dynamic>.from(data['webdav'] ?? {}));
    }

    if (allowedKeys.contains('iptv')) {
      Get.find<IptvSettingsController>().fromJson(Map<String, dynamic>.from(data['iptv'] ?? {}));
    }

    if (allowedKeys.contains('cookie') && data.containsKey('cookie')) {
      Get.find<CookieSettingsController>().fromJson(Map<String, dynamic>.from(data['cookie'] ?? {}));
    }

    if (allowedKeys.contains('proxy')) {
      Get.find<ProxySettingsController>().fromJson(Map<String, dynamic>.from(data['proxy'] ?? {}));
    }

    // Normalize both the old flat PiP rectangle and the former player-owned
    // rememberPipPosition flag before importing the current window settings.
    if (allowedKeys.contains('windowSize')) {
      Get.find<WindowSizeController>().fromJson(WindowSizeController.extractConfig(data));
    }

    if (allowedKeys.contains('exit')) {
      Get.find<ExitSettingsController>().fromJson(Map<String, dynamic>.from(data['exit'] ?? {}));
    }

    if (allowedKeys.contains('startup')) {
      Get.find<StartupController>().fromJson(Map<String, dynamic>.from(data['startup'] ?? {}));
    }

    if (allowedKeys.contains('refresh')) {
      Get.find<RefreshConfigController>().fromJson(Map<String, dynamic>.from(data['refresh'] ?? {}));
    }

    if (allowedKeys.contains('page')) {
      Get.find<PageSettingsController>().fromJson(Map<String, dynamic>.from(data['page'] ?? {}));
    }

    // 沉浸侧栏面板尺寸（阶段五）：条件式导入，数据缺失该段时保持当前值。
    if (allowedKeys.contains('panelSize') && data['panelSize'] is Map) {
      Get.find<PanelSizeController>().fromJson(Map<String, dynamic>.from(data['panelSize']));
    }

    // 备份目录记忆：字符串段，不参与 validateSectionStructure 的 Map 校验。
    if (allowedKeys.contains('backupDirectory') && data['backupDirectory'] is String) {
      backupDirectory.v = data['backupDirectory'] as String;
    }

    // 收藏页置顶/排序偏好（5.2）：控制器未实例化（lazyPut）时直接写 Hive key，
    // 等其创建时自行恢复；避免 Get.find 触发工厂初始化引发启动刷新等副作用。
    if (allowedKeys.contains('favoriteCtrl') && data['favoriteCtrl'] is Map) {
      final favData = Map<String, dynamic>.from(data['favoriteCtrl'] as Map);
      if (Get.isRegistered<FavoriteController>()) {
        final favCtrl = Get.find<FavoriteController>();
        if (favData['enablePinned'] is bool) {
          favCtrl.enablePinned.value = favData['enablePinned'] as bool;
        }
        if (favData['onlineSortMode'] is String) {
          favCtrl.onlineSortMode.value = OnlineSortMode.values.firstWhere(
            (e) => e.name == favData['onlineSortMode'],
            orElse: () => OnlineSortMode.audience,
          );
        }
        // 旧备份没有该字段时保持当前方向不变。
        if (favData['onlineSortOrder'] is String) {
          favCtrl.onlineSortAscending.value = favData['onlineSortOrder'] == 'asc';
        }
      } else {
        if (favData['enablePinned'] is bool) {
          HivePrefUtil.setBool(FavoriteController.pinnedPrefKey, favData['enablePinned'] as bool);
        }
        if (favData['onlineSortMode'] is String) {
          HivePrefUtil.setString(FavoriteController.sortModePrefKey, favData['onlineSortMode'] as String);
        }
        if (favData['onlineSortOrder'] is String) {
          HivePrefUtil.setBool(FavoriteController.sortAscendingPrefKey, favData['onlineSortOrder'] == 'asc');
        }
      }
    }

    if (allowedKeys.contains('tags')) {
      if (!Get.isRegistered<TagManagementController>()) {
        Get.put(TagManagementController());
      }

      final tagsData = data['tags'];
      if (tagsData is Map) {
        Get.find<TagManagementController>().importFromJson(Map<String, dynamic>.from(tagsData));
      }
    }
  }

  /// legacy 扁平格式的部分导入：与 [_importLegacy] 相同的控制器映射，
  /// 但只应用 allowedKeys 中选中的模块，未选中模块保持当前值不变。
  void _importLegacyPartial(Map<String, dynamic> data, Set<String> allowedKeys) {
    if (allowedKeys.contains('app')) {
      Get.find<AppSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('theme')) {
      Get.find<ThemeSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('roomCard')) {
      Get.find<RoomCardSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('font')) {
      Get.find<FontSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('player')) {
      Get.find<PlayerSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('danmaku')) {
      Get.find<DanmakuSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('volume')) {
      Get.find<VolumeSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('favorite')) {
      Get.find<FavoriteRoomController>().fromJson(data);
    }

    if (allowedKeys.contains('history')) {
      Get.find<HistoryController>().fromJson(data);
    }

    if (allowedKeys.contains('webdav') && data.containsKey('webdav')) {
      Get.find<WebDavController>().fromJson(data);
    }

    if (allowedKeys.contains('iptv')) {
      Get.find<IptvSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('cookie') && data.containsKey('cookie')) {
      Get.find<CookieSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('proxy')) {
      Get.find<ProxySettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('windowSize')) {
      Get.find<WindowSizeController>().fromJson(data);
    }

    if (allowedKeys.contains('exit')) {
      Get.find<ExitSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('startup')) {
      Get.find<StartupController>().fromJson(data);
    }

    if (allowedKeys.contains('refresh')) {
      Get.find<RefreshConfigController>().fromJson(data);
    }

    if (allowedKeys.contains('page')) {
      Get.find<PageSettingsController>().fromJson(data);
    }

    if (allowedKeys.contains('tags') && data['custom_tags_data'] is Map) {
      if (!Get.isRegistered<TagManagementController>()) {
        Get.put(TagManagementController());
      }

      Get.find<TagManagementController>().importFromJson(Map<String, dynamic>.from(data['custom_tags_data'] as Map));
    }
  }

  void _importLatestCompatible(Map<String, dynamic> data) {
    _importV2(data);
  }

  void _importV2(Map<String, dynamic> data) {
    validateSectionStructure(data);
    Get.find<AppSettingsController>().fromJson(Map<String, dynamic>.from(data['app'] ?? {}));

    Get.find<ThemeSettingsController>().fromJson(Map<String, dynamic>.from(data['theme'] ?? {}));

    Get.find<RoomCardSettingsController>().fromJson(Map<String, dynamic>.from(data['roomCard'] ?? {}));

    Get.find<FontSettingsController>().fromJson(Map<String, dynamic>.from(data['font'] ?? {}));

    Get.find<PlayerSettingsController>().fromJson(Map<String, dynamic>.from(data['player'] ?? {}));

    Get.find<DanmakuSettingsController>().fromJson(Map<String, dynamic>.from(data['danmaku'] ?? {}));

    Get.find<VolumeSettingsController>().fromJson(Map<String, dynamic>.from(data['volume'] ?? {}));

    Get.find<FavoriteRoomController>().fromJson(Map<String, dynamic>.from(data['favorite'] ?? {}));

    Get.find<HistoryController>().fromJson(Map<String, dynamic>.from(data['history'] ?? {}));

    if (data.containsKey('webdav')) {
      Get.find<WebDavController>().fromJson(Map<String, dynamic>.from(data['webdav'] ?? {}));
    }

    Get.find<IptvSettingsController>().fromJson(Map<String, dynamic>.from(data['iptv'] ?? {}));

    if (data.containsKey('cookie')) {
      Get.find<CookieSettingsController>().fromJson(Map<String, dynamic>.from(data['cookie'] ?? {}));
    }

    Get.find<ProxySettingsController>().fromJson(Map<String, dynamic>.from(data['proxy'] ?? {}));

    // Normalize both the old flat PiP rectangle and the former player-owned
    // rememberPipPosition flag before importing the current window settings.
    Get.find<WindowSizeController>().fromJson(WindowSizeController.extractConfig(data));

    Get.find<ExitSettingsController>().fromJson(Map<String, dynamic>.from(data['exit'] ?? {}));

    Get.find<StartupController>().fromJson(Map<String, dynamic>.from(data['startup'] ?? {}));

    Get.find<RefreshConfigController>().fromJson(Map<String, dynamic>.from(data['refresh'] ?? {}));

    Get.find<PageSettingsController>().fromJson(Map<String, dynamic>.from(data['page'] ?? {}));

    // 沉浸侧栏面板尺寸（阶段五）：条件式导入，旧备份缺失该段时保持当前值。
    if (data['panelSize'] is Map) {
      Get.find<PanelSizeController>().fromJson(Map<String, dynamic>.from(data['panelSize']));
    }

    // 备份目录记忆：字符串段，不参与 validateSectionStructure 的 Map 校验。
    if (data['backupDirectory'] is String) {
      backupDirectory.v = data['backupDirectory'] as String;
    }

    // 收藏页置顶/排序偏好（5.2）：控制器未实例化（lazyPut）时直接写 Hive key，
    // 等其创建时自行恢复；避免 Get.find 触发工厂初始化引发启动刷新等副作用。
    if (data['favoriteCtrl'] is Map) {
      final favData = Map<String, dynamic>.from(data['favoriteCtrl'] as Map);
      if (Get.isRegistered<FavoriteController>()) {
        final favCtrl = Get.find<FavoriteController>();
        if (favData['enablePinned'] is bool) {
          favCtrl.enablePinned.value = favData['enablePinned'] as bool;
        }
        if (favData['onlineSortMode'] is String) {
          favCtrl.onlineSortMode.value = OnlineSortMode.values.firstWhere(
            (e) => e.name == favData['onlineSortMode'],
            orElse: () => OnlineSortMode.audience,
          );
        }
        // 旧备份没有该字段时保持当前方向不变。
        if (favData['onlineSortOrder'] is String) {
          favCtrl.onlineSortAscending.value = favData['onlineSortOrder'] == 'asc';
        }
      } else {
        if (favData['enablePinned'] is bool) {
          HivePrefUtil.setBool(FavoriteController.pinnedPrefKey, favData['enablePinned'] as bool);
        }
        if (favData['onlineSortMode'] is String) {
          HivePrefUtil.setString(FavoriteController.sortModePrefKey, favData['onlineSortMode'] as String);
        }
        if (favData['onlineSortOrder'] is String) {
          HivePrefUtil.setBool(FavoriteController.sortAscendingPrefKey, favData['onlineSortOrder'] == 'asc');
        }
      }
    }

    if (!Get.isRegistered<TagManagementController>()) {
      Get.put(TagManagementController());
    }

    final tagsData = data['tags'];
    if (tagsData is Map) {
      Get.find<TagManagementController>().importFromJson(Map<String, dynamic>.from(tagsData));
    }
  }

  /// Reject malformed sections before any controller persists an earlier one.
  /// Missing/null sections keep their historical default-import behavior.
  static void validateSectionStructure(Map<String, dynamic> data) {
    const sections = <String>[
      'app',
      'theme',
      'roomCard',
      'font',
      'player',
      'danmaku',
      'volume',
      'favorite',
      'history',
      'webdav',
      'iptv',
      'cookie',
      'proxy',
      'windowSize',
      'exit',
      'startup',
      'refresh',
      'page',
      'panelSize',
      'favoriteCtrl',
      'tags',
    ];
    for (final name in sections) {
      final section = data[name];
      if (section == null) continue;
      if (section is! Map || section.keys.any((key) => key is! String)) {
        throw FormatException('Invalid backup section: $name');
      }
    }
  }

  void _importLegacy(Map<String, dynamic> data) {
    Get.find<AppSettingsController>().fromJson(data);
    Get.find<ThemeSettingsController>().fromJson(data);
    Get.find<RoomCardSettingsController>().fromJson(data);
    Get.find<FontSettingsController>().fromJson(data);
    Get.find<PlayerSettingsController>().fromJson(data);
    Get.find<DanmakuSettingsController>().fromJson(data);
    Get.find<VolumeSettingsController>().fromJson(data);
    Get.find<FavoriteRoomController>().fromJson(data);
    Get.find<HistoryController>().fromJson(data);
    Get.find<WebDavController>().fromJson(data);
    Get.find<IptvSettingsController>().fromJson(data);
    Get.find<CookieSettingsController>().fromJson(data);
    Get.find<ProxySettingsController>().fromJson(data);
    Get.find<WindowSizeController>().fromJson(data);
    Get.find<ExitSettingsController>().fromJson(data);
    Get.find<StartupController>().fromJson(data);
    Get.find<RefreshConfigController>().fromJson(data);
    Get.find<PageSettingsController>().fromJson(data);
    if (!Get.isRegistered<TagManagementController>()) {
      Get.put(TagManagementController());
    }

    final legacyTags = data['custom_tags_data'];
    if (legacyTags is Map) {
      Get.find<TagManagementController>().importFromJson(Map<String, dynamic>.from(legacyTags));
    }
  }

  bool backup(File file) {
    try {
      final data = exportAllSettings();
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> restoreAllSettings(Map<String, dynamic> data) async {
    await _persistRestore(() => importAllSettings(data));
  }

  Future<void> restoreFavoriteSettings(Map<String, dynamic> data) async {
    await _persistRestore(() {
      final version = data['backupVersion'];
      if (version != null && (version is! int || version < 1)) {
        throw const FormatException('Invalid backup version');
      }

      final Map<String, dynamic> favorite;
      if (version == null) {
        favorite = data;
      } else {
        final section = data['favorite'];
        if (section is! Map || section.keys.any((key) => key is! String)) {
          throw const FormatException('Invalid backup section: favorite');
        }
        favorite = Map<String, dynamic>.from(section);
      }
      Get.find<FavoriteRoomController>().restoreFavoriteLists(favorite);
    });
  }

  Future<void> _persistRestore(void Function() restore) async {
    if (_restoreInProgress) throw StateError('A settings restore is already running');
    _restoreInProgress = true;
    try {
      await HivePrefUtil.persistBatch(restore);
    } finally {
      _restoreInProgress = false;
    }
  }

  Future<bool> recover(File file) async {
    try {
      final json = file.readAsStringSync();
      final data = jsonDecode(json);

      if (data is! Map<String, dynamic>) {
        return false;
      }

      await restoreAllSettings(data);

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> recoverAndDelete(File file) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      final json = await file.readAsString();
      final data = jsonDecode(json);
      if (data is! Map<String, dynamic>) {
        return false;
      }
      importAllSettings(data);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await file.exists()) {
          await file.delete();
        }
        final parent = file.parent;
        if (await parent.exists()) {
          try {
            await parent.delete();
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  Map<String, dynamic> exportToTVSettings({bool includeSensitiveData = true}) {
    final danmaku = Get.find<DanmakuSettingsController>().toJson();
    final iptv = Get.find<IptvSettingsController>().toJson();
    final favorite = Get.find<FavoriteRoomController>().toJson();
    final history = Get.find<HistoryController>().toJson();

    final data = <String, dynamic>{
      ...danmaku,
      ...favorite,
      ...history,
      'customIptvUserAgent': iptv['customIptvUserAgent'],
    };
    if (includeSensitiveData) {
      data.addAll(Get.find<CookieSettingsController>().toJson());
    }
    return data;
  }
}
