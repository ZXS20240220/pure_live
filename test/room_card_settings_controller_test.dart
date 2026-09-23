import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/common/services/settings/room_card_settings_controller.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/get/get.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pure-live-room-card-settings-');
    Hive.init(directory.path);
    await HivePrefUtil.init();
  });

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await HivePrefUtil.clear();
  });

  tearDown(() async {
    Get.reset();
    await HivePrefUtil.flush();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('单一配置持久化：updateConfig 后 toJson 反映最新值', () async {
    final controller = Get.put(RoomCardSettingsController());

    final changed = RoomCardAppearance.standard.copyWith(
      showPlatformBadge: true,
      cornerRadius: 28,
      showReplayBadge: false,
    );
    controller.updateConfig(changed);

    expect(controller.current.showPlatformBadge, isTrue);
    expect(controller.current.cornerRadius, 28);
    expect(controller.current.showReplayBadge, isFalse);

    await Future<void>.delayed(Duration.zero);
    await HivePrefUtil.flush();
    // 沿用旧 desktop 存储键
    final raw = HivePrefUtil.getString('room_card_desktop_config');
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as Map<String, dynamic>;
    expect(decoded['showPlatformBadge'], isTrue);
    expect(decoded['cornerRadius'], 28);
  });

  test('copyWith 自动归一化圆角到合法范围', () {
    final controller = Get.put(RoomCardSettingsController());
    final changed = RoomCardAppearance.standard.copyWith(
      showPlatformBadge: true,
      cornerRadius: 100, // 超过 maxCornerRadius=32
    );

    controller.updateConfig(changed);

    expect(controller.current.showPlatformBadge, isTrue);
    expect(controller.current.cornerRadius, RoomCardAppearance.maxCornerRadius);
  });

  test('旧格式 Hive 键迁移：room_card_mobile_config 读取为 fallback', () async {
    await HivePrefUtil.setString(
      'room_card_mobile_config',
      jsonEncode({
        'showAvatar': false,
        'showSubtitle': true,
        'showPlatform': true,
        'showAudience': false,
        'showRecordBadge': false,
        'cardBorderRadius': 27,
      }),
    );

    final controller = Get.put(RoomCardSettingsController());
    final cfg = controller.current;

    expect(cfg.showAvatar, isFalse);
    expect(cfg.showAnchorName, isTrue);
    expect(cfg.showPlatformBadge, isTrue);
    expect(cfg.showAudience, isFalse);
    expect(cfg.showReplayBadge, isFalse);
    expect(cfg.cornerRadius, 27);
  });

  test('旧备份格式解析：desktopConfig 优先，其次 mobileConfig', () {
    // 旧备份格式（含 mobile/desktop 双配置）
    final oldBackup = {
      'mobilePreset': 'standard',
      'desktopPreset': 'rich',
      'mobileConfig': {'showAvatar': false, 'showAnchorName': false, 'cornerRadius': 8},
      'desktopConfig': {'showAvatar': true, 'showAnchorName': true, 'cornerRadius': 24},
    };
    final parsed = RoomCardSettingsController.parseConfig(oldBackup);
    final cfg = parsed['config'] as RoomCardAppearance;
    // desktopConfig 优先
    expect(cfg.showAvatar, isTrue);
    expect(cfg.cornerRadius, 24);

    // 只有 mobileConfig 时 fallback
    final mobileOnly = {
      'mobileConfig': {'showAvatar': false, 'showAnchorName': false, 'cornerRadius': 10},
    };
    final parsedMobile = RoomCardSettingsController.parseConfig(mobileOnly);
    expect((parsedMobile['config'] as RoomCardAppearance).cornerRadius, 10);

    // 都没有 → standard
    final empty = RoomCardSettingsController.parseConfig(const {});
    expect(empty['config'], RoomCardAppearance.standard);
  });

  test('新备份格式序列化 + extractConfig 返回 Map<String, dynamic>', () {
    final controller = Get.put(RoomCardSettingsController());
    controller.updateConfig(RoomCardAppearance.standard.copyWith(cornerRadius: 18));

    // toJson 返回单一 config 的 JSON
    final json = controller.toJson();
    expect(json['cornerRadius'], 18);
    expect(json['showAvatar'], isTrue);

    // extractConfig 从 rootConfig 里 roomCard section 解析
    final extracted = RoomCardSettingsController.extractConfig({
      'roomCard': {'showAvatar': false, 'cornerRadius': 12},
    });
    expect(extracted['showAvatar'], isFalse);
    expect(extracted['cornerRadius'], 12);
  });

  test('automaticPlatformBadge 旧字段迁移：true → showPlatformBadge=false', () {
    // 旧格式 automaticPlatformBadge=true 表示"自动显示"，
    // 新模式下自动已删除，统一降级为 false（隐藏）。
    final migrated = RoomCardAppearance.fromJson({
      'showAvatar': true,
      'automaticPlatformBadge': true,
      'cornerRadius': 12,
    });
    expect(migrated.showPlatformBadge, isFalse);

    // 旧格式 automaticPlatformBadge=false + showPlatformBadge=true → 保持 true
    final always = RoomCardAppearance.fromJson({
      'showAvatar': true,
      'automaticPlatformBadge': false,
      'showPlatformBadge': true,
      'cornerRadius': 12,
    });
    expect(always.showPlatformBadge, isTrue);
  });

  test('parseConfig strict 模式：非法类型抛 FormatException', () {
    expect(
      () => RoomCardSettingsController.parseConfig({
        'desktopConfig': {'showAvatar': 'yes'},
      }),
      throwsFormatException,
    );
    expect(
      () => RoomCardSettingsController.parseConfig({
        'desktopConfig': {'cornerRadius': double.infinity},
      }),
      throwsFormatException,
    );
  });
}
