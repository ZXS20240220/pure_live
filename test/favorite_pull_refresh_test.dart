import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/widgets/app_status_view.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/favorite/room_grid_view.dart';
import 'package:pure_live/plugins/global.dart';
import 'package:pure_live/plugins/locale_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;
  late Map<String, dynamic> translations;

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('pure-live-fav-pull-test-');
    Hive.init(hiveDirectory.path);
    await HivePrefUtil.init();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    translations = jsonDecode(await File('assets/translations/zh.json').readAsString()) as Map<String, dynamic>;
    initRefresh();
  });

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await HivePrefUtil.clear();
    Get.put(SettingsService(), permanent: true);
  });

  tearDown(Get.reset);

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test('pull-to-refresh wraps every viewport and platform, matching the dev build', () {
    expect(shouldWrapFavoritePullToRefresh(viewportWidth: 1280, isMobilePlatform: true), isTrue);
    expect(shouldWrapFavoritePullToRefresh(viewportWidth: 1280, isMobilePlatform: false), isTrue);
    expect(shouldWrapFavoritePullToRefresh(viewportWidth: 600, isMobilePlatform: false), isTrue);
  });

  testWidgets('favorite platform page shows and triggers its vertical pull indicator', (tester) async {
    var refreshCount = 0;
    final refreshCompleter = Completer<void>();

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('zh')],
        startLocale: const Locale('zh'),
        saveLocale: false,
        path: 'assets/translations',
        assetLoader: _TranslationsLoader(translations),
        child: Builder(
          builder: (context) => GetMaterialApp(
            locale: context.locale,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final indicators = appRefreshIndicators(context);
                  return EasyRefresh(
                    key: const ValueKey('pull_to_refresh_favorite_bilibili'),
                    header: indicators.header,
                    triggerAxis: Axis.vertical,
                    onRefresh: () {
                      refreshCount++;
                      return refreshCompleter.future;
                    },
                    child: ListView(children: const [SizedBox(height: 120, child: Text('favourite'))]),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final refresh = tester.widget<EasyRefresh>(find.byType(EasyRefresh));
    expect(refresh.key, const ValueKey('pull_to_refresh_favorite_bilibili'));

    final header = refresh.header as ClassicHeader;
    expect(header.dragText, i18n('refresh_pull_up_to_refresh'));
    expect(header.processingText, i18n('refresh_refreshing'));
    expect(header.triggerOffset, greaterThan(0));

    final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    for (var index = 0; index < 30; index++) {
      await gesture.moveBy(const Offset(0, 70));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      find.text(i18n('refresh_release_to_load')),
      findsOneWidget,
      reason: 'armed mode should show release-to-load text',
    );

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(AppStatusView), findsOneWidget, reason: 'processing mode should show the loading indicator');
    expect(
      find.text(i18n('refresh_refreshing')),
      findsOneWidget,
      reason: 'processing mode should show refreshing text',
    );
    expect(refreshCount, 1, reason: 'a real drag, rather than a direct callback invocation, must arm refresh');

    refreshCompleter.complete();
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });
}

class _TranslationsLoader extends AssetLoader {
  _TranslationsLoader(this.data);
  final Map<String, dynamic> data;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => data;
}
