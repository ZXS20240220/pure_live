// The rewritten SuperChatPage reads its data from the live room controller
// (superChats / detail.notice / aiHighlights), so page-level rendering cannot
// be exercised without a full LivePlayController. These tests keep covering the
// card-level rendering guarantees that used to be asserted through the page.
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/common/services/settings/font_settings_controller.dart';
import 'package:pure_live/common/services/settings/theme_settings_controller.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/live_play/widgets/layout/super_chat_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('super-chat-card-');
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    Hive.init(directory.path);
    await HivePrefUtil.init();
  });

  setUp(() {
    Get.testMode = true;
    Get.put<SettingsService>(_Settings());
  });
  tearDown(() => Get.reset());
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> open(
    WidgetTester tester,
    Widget child, {
    String language = 'en',
    Size size = const Size(900, 900),
    double scale = 1,
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
        supportedLocales: const [Locale('zh'), Locale('en')],
        startLocale: Locale(language),
        saveLocale: false,
        path: 'unused',
        assetLoader: const _Translations(),
        child: Builder(
          builder: (context) => GetMaterialApp(
            locale: context.locale,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('malformed platform colours fall back without hiding the paid message', (tester) async {
    await open(
      tester,
      SuperChatCard(
        message(
          messageId: 'bad-colour',
          text: 'Server supplied message remains visible',
          backgroundColor: 'not-a-colour',
          backgroundBottomColor: '#12',
        ),
      ),
    );

    expect(find.text('Server supplied message remains visible'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long identity price and message fit a narrow large-text surface', (tester) async {
    final longMessage = List.filled(12, 'A paid message with important details').join(' ');
    await open(
      tester,
      SuperChatCard(
        message(
          messageId: 'large-text',
          userName: List.filled(8, 'Long supporter name').join(' '),
          text: longMessage,
          price: 2147483647,
        ),
      ),
      size: const Size(320, 480),
      scale: 3,
    );

    expect(find.text(longMessage), findsOneWidget);
    expect(find.text('￥2147483647'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

LiveSuperChatMessage message({
  String messageId = '',
  String userName = 'supporter',
  String text = 'paid message',
  int price = 30,
  Duration startOffset = Duration.zero,
  String backgroundColor = '#FFF3CD',
  String backgroundBottomColor = '#FFF8E1',
}) {
  final start = DateTime.now().add(startOffset);
  return LiveSuperChatMessage(
    messageId: messageId,
    backgroundBottomColor: backgroundBottomColor,
    backgroundColor: backgroundColor,
    endTime: start.add(const Duration(minutes: 2)),
    face: '',
    message: text,
    price: price,
    startTime: start,
    userName: userName,
  );
}

class _Translations extends AssetLoader {
  const _Translations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    if (locale.languageCode == 'zh') {
      return const {'super_chat_empty_title': '暂无醒目留言', 'super_chat_empty_subtitle': '当前直播间的付费留言会显示在这里。'};
    }
    return const {
      'super_chat_empty_title': 'No Super Chats yet',
      'super_chat_empty_subtitle': 'Paid messages from the current room will appear here.',
    };
  }
}

class _Settings extends SettingsService {
  final _font = FontSettingsController();
  final _theme = ThemeSettingsController();

  @override
  FontSettingsController get font => _font;

  @override
  ThemeSettingsController get theme => _theme;

  @override
  // ignore: must_call_super
  void onInit() {}
}
