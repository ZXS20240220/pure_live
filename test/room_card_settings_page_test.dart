import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/common/services/settings/room_card_settings_controller.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/settings/pages/room_card_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> english;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    english = jsonDecode(await File('assets/translations/en.json').readAsString()) as Map<String, dynamic>;
    await Hive.openBox<dynamic>('app_settings', bytes: Uint8List(0));
    await HivePrefUtil.init();
  });

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await HivePrefUtil.clear();
    Get.put(SettingsService(), permanent: true);
  });

  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    await HivePrefUtil.flush();
    Get.reset();
  });

  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 10));
  });

  testWidgets('room card settings page: reset button restores standard config', (tester) async {
    await _pump(tester, english, home: const RoomCardSettingsPage(), size: const Size(900, 1000));

    expect(find.byType(RoomCardSettingsPage), findsOneWidget);
    // 新 UI 不再有 viewport selector 和 preset chips
    expect(find.byKey(const ValueKey('room-card-target-selector')), findsNothing);

    // 先改一下配置
    SettingsService.to.roomCard.updateConfig(
      RoomCardAppearance.standard.copyWith(cornerRadius: 12, showPlatformBadge: true),
    );
    await tester.pump();

    // 点击重置按钮
    await tester.tap(find.byKey(const ValueKey('room-card-reset')));
    await tester.pump();

    expect(SettingsService.to.roomCard.current.cornerRadius, RoomCardAppearance.defaultCornerRadius);
    expect(SettingsService.to.roomCard.current.showPlatformBadge, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('room card settings page: preview renders RoomCard + RoomCardCompact', (tester) async {
    await _pump(tester, english, home: const RoomCardSettingsPage(), size: const Size(900, 1200));

    // 标准卡片预览
    expect(find.byKey(const ValueKey('room-card-preview-standard')), findsOneWidget);
    // 紧凑列表卡片预览（live + offline 两版）
    expect(find.byKey(const ValueKey('room-card-preview-compact-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-card-preview-compact-offline')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('room card settings remain scrollable at 320x480 with 3x text', (tester) async {
    await _pump(tester, english, home: const RoomCardSettingsPage(), size: const Size(320, 480), textScale: 3);

    // 新 UI 不再有 viewport selector
    expect(find.byTooltip('Reset current layout'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final page = find.byKey(const ValueKey('room-card-settings-scroll'));
    // 尝试滚到底部找圆角滑块（新 key 不同）
    await tester.drag(page, const Offset(0, -2000));
    await tester.pump();
    await tester.drag(page, const Offset(0, 2000));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> english, {
  required Widget home,
  required Size size,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      startLocale: const Locale('en'),
      fallbackLocale: const Locale('en'),
      saveLocale: false,
      path: 'assets/translations',
      assetLoader: _Translations(english),
      child: Builder(
        builder: (context) => GetMaterialApp(
          locale: context.locale,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _Translations extends AssetLoader {
  const _Translations(this.english);

  final Map<String, dynamic> english;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => english;
}
