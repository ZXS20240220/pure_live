import 'dart:io';
import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/file_utils.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:pure_live/common/global/initialized.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:pure_live/routes/navigation_observer.dart';
import 'package:pure_live/player/models/player_engine.dart';
import 'package:pure_live/player/utils/popup_route_tracker.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/routes/route_observer_controller.dart';
import 'package:pure_live/common/utils/shared_media_intake.dart';
import 'package:pure_live/common/utils/share_command_handler.dart';
import 'package:pure_live/core/iptv/services/epg_import_manager.dart';
import 'package:pure_live/common/global/platform/desktop_manager.dart';
import 'package:pure_live/core/iptv/services/iptv_import_manager.dart';
import 'package:pure_live/modules/wallpaper/widgets/app_background.dart';

void main(List<String> args) async {
  // Flutter abbreviates every framework error after the first one. In release
  // builds that abbreviation hides the actual exception behind a diagnostics
  // node, making a grey player surface impossible to diagnose from logcat.
  // Always retain the concrete exception and stack locally on the device.
  FlutterError.onError = (details) {
    FlutterError.dumpErrorToConsole(details, forceReport: true);
  };

  await AppInitializer().initialize(args);

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('zh')],
      path: 'assets/translations',
      fallbackLocale: const Locale('zh'),
      assetLoader: const RootBundleAssetLoader(),
      child: MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with DesktopWindowMixin {
  SharedMediaReceiver? _sharedMediaReceiver;
  bool _dynamicThemeChangeScheduled = false;

  @override
  void initState() {
    super.initState();
    // Start favourite verification after the first Flutter frame instead of
    // waiting until HomePage is created. When the splash page is enabled this
    // overlaps its one-second animation; when it is disabled the first frame
    // still wins over network/JSON work. The controller already publishes the
    // settled room snapshot as one transaction, so cards do not reshuffle as
    // individual requests finish.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Get.isRegistered<FavoriteController>()) {
        Get.find<FavoriteController>();
      }
    });
    if (PlatformUtils.isDesktop) {
      DesktopManager.initializeListeners(this);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(DesktopManager.updateTrayWhenLocalized());
      });
    }
    unawaited(initSharedMediaListener());
    unawaited(initGlobalPlayer());
  }

  Future<void> initGlobalPlayer() async {
    // 仅保留 mpv（media_kit）内核，历史 videoPlayerKey 存储值不再参与选择。
    await GlobalPlayerService.instance.initialize(defaultEngine: PlayerEngine.mediaKit);
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      DesktopManager.disposeListeners();
    }
    final receiver = _sharedMediaReceiver;
    if (receiver != null) unawaited(receiver.dispose());
    unawaited(GlobalPlayerService.instance.dispose());
    super.dispose();
  }

  Future<void> initSharedMediaListener() async {
    if (!Platform.isAndroid) return;

    final handler = ShareHandler.instance;
    final intake = SharedMediaIntake(
      isRoomCommand: ShareCommandHandler.isUsableCommand,
      consumeRoomCommand: handleIncomingShareCommand,
      importPlaylist: (path) => IptvImportManager().importFromSharedMedia(SharedMedia(content: path)),
      importEpg: (path) => EpgImportManager().importFromSharedMedia(SharedMedia(content: path)),
      releaseAttachment: (path) async {
        await FileUtils.cleanupOwnedSharedMediaFile(File(path));
      },
      notifyUnsupported: (key) => ToastUtil.show(i18n(key)),
      reportError: (error, stackTrace) => debugPrint('Shared media receiver failed: $error\n$stackTrace'),
    );
    final receiver = SharedMediaReceiver(
      readInitialMedia: handler.getInitialSharedMedia,
      resetInitialMedia: handler.resetInitialSharedMedia,
      mediaStream: handler.sharedMediaStream,
      intake: intake,
      reportError: (error, stackTrace) => debugPrint('Shared media channel failed: $error\n$stackTrace'),
    );
    _sharedMediaReceiver = receiver;
    await receiver.start();
  }

  void _applyDynamicTheme(
    material.ColorScheme? lightDynamic,
    material.ColorScheme? darkDynamic,
    ThemeData lightThemeData,
    ThemeData darkThemeData,
  ) {
    if (_dynamicThemeChangeScheduled) {
      return;
    }

    _dynamicThemeChangeScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dynamicThemeChangeScheduled = false;

      if (!mounted) {
        return;
      }

      final brightness = Theme.of(context).brightness;
      final wallpaperActive = SettingsService.to.wallpaper.hasWallpaper;
      final scaffoldBg = wallpaperActive ? Colors.transparent : null;

      ThemeData themeToApply;
      if (SettingsService.to.theme.enableDynamicTheme.v && lightDynamic != null && darkDynamic != null) {
        final scheme = brightness == Brightness.dark
            ? toFlutterColorScheme(darkDynamic)
            : toFlutterColorScheme(lightDynamic);

        final theme = MyTheme(colorScheme: scheme);
        themeToApply = brightness == Brightness.dark ? theme.darkThemeData : theme.lightThemeData;
      } else {
        themeToApply = brightness == Brightness.dark ? darkThemeData : lightThemeData;
      }

      if (scaffoldBg != null) {
        themeToApply = themeToApply.copyWith(
          scaffoldBackgroundColor: scaffoldBg,
          appBarTheme: AppBarTheme(surfaceTintColor: Colors.transparent, backgroundColor: scaffoldBg),
        );
      }

      Get.changeTheme(themeToApply);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return Obx(() {
          final themeColor = SettingsService.to.theme.themeColor;
          final showSplashPage = SettingsService.to.app.showSplashPage.v;
          final currentFactor = SettingsService.to.font.textScaleFactor.v;
          final wallpaper = SettingsService.to.wallpaper;
          final wallpaperActive = wallpaper.hasWallpaper;

          ThemeData lightTheme;
          ThemeData darkTheme;

          if (SettingsService.to.theme.enableDynamicTheme.v && lightDynamic != null && darkDynamic != null) {
            lightTheme = MyTheme(colorScheme: toFlutterColorScheme(lightDynamic)).lightThemeData;
            darkTheme = MyTheme(colorScheme: toFlutterColorScheme(darkDynamic)).darkThemeData;
          } else {
            lightTheme = MyTheme(primaryColor: themeColor).lightThemeData;
            darkTheme = MyTheme(primaryColor: themeColor).darkThemeData;
          }
          _applyDynamicTheme(lightDynamic, darkDynamic, lightTheme, darkTheme);

          // 壁纸激活时让全局 Scaffold 背景透明，露出底层 AppBackground。
          // 注意：由于 GetX 的 GetRootState.didUpdateWidget 被注释，
          // theme 属性的变化不会传播到 MaterialApp，实际透明效果由
          // builder 中的 Theme widget 覆盖实现。
          final scaffoldBg = wallpaperActive ? Colors.transparent : null;

          return GetMaterialApp(
            // The localized title is rendered by CustomTitleBar. A stable
            // application title avoids asking EasyLocalization for a key
            // before its delegate has completed the first load.
            title: i18n('app_name'),
            navigatorKey: appNavigatorKey,
            scrollBehavior: MyCustomScrollBehavior(),
            debugShowCheckedModeBanner: false,
            // 窗口背景设为透明，避免路由切换时闪现黑色（露出底层 AppBackground 壁纸）
            color: Colors.transparent,
            themeMode: SettingsService.to.theme.themeMode,
            theme: lightTheme.copyWith(
              scaffoldBackgroundColor: scaffoldBg,
              appBarTheme: AppBarTheme(surfaceTintColor: Colors.transparent, backgroundColor: scaffoldBg),
              pageTransitionsTheme: appPageTransitionsTheme,
            ),
            darkTheme: darkTheme.copyWith(
              scaffoldBackgroundColor: scaffoldBg,
              appBarTheme: AppBarTheme(surfaceTintColor: Colors.transparent, backgroundColor: scaffoldBg),
              pageTransitionsTheme: appPageTransitionsTheme,
            ),
            locale: context.locale,
            navigatorObservers: [FlutterSmartDialog.observer, LiveRouteObserver(), PopupRouteTracker.instance],
            builder: FlutterSmartDialog.init(
              builder: (context, child) {
                return Obx(() {
                  Widget resultWidget = child ?? const SizedBox.shrink();
                  if (PlatformUtils.isDesktopNotMac) {
                    resultWidget = DesktopManager.buildWithTitleBar(resultWidget);
                  } else if (Platform.isAndroid) {
                    resultWidget = AdaptiveRefreshRateScope(
                      mode: SettingsService.to.app.refreshRateMode,
                      child: resultWidget,
                    );
                  }

                  final wallpaperActive = SettingsService.to.wallpaper.hasWallpaper;
                  final baseTheme = Theme.of(context);
                  final restoredScaffoldBg = baseTheme.colorScheme.surface;
                  final effectiveTheme = wallpaperActive
                      ? baseTheme.copyWith(
                          scaffoldBackgroundColor: Colors.transparent,
                          appBarTheme: baseTheme.appBarTheme.copyWith(
                            backgroundColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                          ),
                        )
                      : baseTheme.copyWith(
                          scaffoldBackgroundColor: restoredScaffoldBg,
                          appBarTheme: baseTheme.appBarTheme.copyWith(
                            backgroundColor: restoredScaffoldBg,
                            surfaceTintColor: Colors.transparent,
                          ),
                        );

                  return Theme(
                    data: effectiveTheme,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(currentFactor)),
                      child: MaterialUiThemeBridge(
                        child: Stack(
                          children: [
                            const Positioned.fill(child: AppBackground()),
                            Positioned.fill(child: resultWidget),
                          ],
                        ),
                      ),
                    ),
                  );
                });
              },
            ),
            supportedLocales: context.supportedLocales,
            localizationsDelegates: [
              ...context.localizationDelegates,
              // flex_color_picker 4.x and cached_network_image 4.x use the
              // decoupled Material library. Its localization type is distinct
              // from flutter/material.dart and must be registered alongside it.
              material.GlobalMaterialLocalizations.delegate,
            ],
            initialRoute: showSplashPage ? RoutePath.kSplash : RoutePath.kInitial,
            defaultTransition: Transition.native,
            routingCallback: (routing) {
              if (routing != null) {
                RouteObserverController.to.updateRoute(routing.current);
              }
            },
            getPages: AppPages.routes,
          );
        });
      },
    );
  }
}
