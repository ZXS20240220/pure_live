import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/log_controller.dart';
import 'package:pure_live/core/common/log.dart';
import 'package:pure_live/core/utils/web_view2_environment.dart';
import 'package:pure_live/modules/search/web_search_room_parser.dart';
import 'package:pure_live/plugins/utils.dart';
import 'package:pure_live/routes/app_navigation.dart';
import 'package:url_launcher/url_launcher.dart';

enum WebSearchViewStatus { loading, ready, failed }

enum WebSearchBackDisposition { stayOnPage, closePage }

class WebSearchLaunchRequest {
  const WebSearchLaunchRequest({required this.uri, required this.platform});

  final Uri uri;
  final String platform;
}

WebSearchLaunchRequest? parseWebSearchLaunchRequest(Object? arguments) {
  if (arguments is! Map) return null;
  final rawUrl = arguments['url'];
  final rawPlatform = arguments['platform'];
  if (rawUrl is! String || rawPlatform is! String) return null;
  final uri = Uri.tryParse(rawUrl.trim());
  final platform = rawPlatform.trim().toLowerCase();
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.trim().isEmpty ||
      uri.userInfo.isNotEmpty ||
      platform.isEmpty) {
    return null;
  }
  return WebSearchLaunchRequest(uri: uri, platform: platform);
}

abstract interface class WebSearchBrowser {
  Future<void> load(Uri uri);

  Future<void> reload();

  Future<bool> canGoBack();

  Future<void> goBack();

  Future<void> stopLoading();

  Future<void> openDevTools();

  void dispose();
}

class _InAppWebSearchBrowser implements WebSearchBrowser {
  const _InAppWebSearchBrowser(this.controller);

  final InAppWebViewController controller;

  @override
  Future<void> load(Uri uri) => controller.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));

  @override
  Future<void> reload() => controller.reload();

  @override
  Future<bool> canGoBack() => controller.canGoBack();

  @override
  Future<void> goBack() => controller.goBack();

  @override
  Future<void> stopLoading() => controller.stopLoading();

  @override
  Future<void> openDevTools() => controller.openDevTools();

  @override
  void dispose() => controller.dispose();
}

typedef WebSearchExternalLauncher = Future<bool> Function(Uri uri);
typedef WebSearchRoomConfirmation = Future<bool?> Function(WebSearchRoomTarget target);
typedef WebSearchRoomOpener = Future<void> Function(LiveRoom room);
typedef WebSearchCookieFlusher = Future<void> Function();
typedef WebSearchNotice = void Function(String localizationKey);

class WebSearchController extends GetxController {
  WebSearchController({
    this.initialArguments,
    this.useExternalBrowser,
    WebSearchExternalLauncher? launchExternal,
    WebSearchRoomConfirmation? confirmRoom,
    WebSearchRoomOpener? openRoom,
    WebSearchCookieFlusher? flushCookies,
    WebSearchNotice? notice,
  }) : _launchExternal = launchExternal ?? _defaultLaunchExternal,
       _confirmRoom = confirmRoom ?? _defaultConfirmRoom,
       _openRoom = openRoom ?? _defaultOpenRoom,
       _flushCookies = flushCookies ?? _defaultFlushCookies,
       _notice = notice ?? _defaultNotice;

  final Object? initialArguments;
  final bool? useExternalBrowser;
  final WebSearchExternalLauncher _launchExternal;
  final WebSearchRoomConfirmation _confirmRoom;
  final WebSearchRoomOpener _openRoom;
  final WebSearchCookieFlusher _flushCookies;
  final WebSearchNotice _notice;

  WebSearchLaunchRequest? launchRequest;
  final roomId = ''.obs;
  final showWebView = true.obs;
  final viewStatus = WebSearchViewStatus.loading.obs;
  final errorMessageKey = ''.obs;
  final loadProgress = 0.obs;
  final isOpeningExternal = false.obs;

  /// 当前页面网址（地址栏展示与编辑的数据源）。
  final currentUrl = ''.obs;

  WebSearchBrowser? _browser;
  Timer? _creationWatchdog;
  InAppWebViewController? _nativeController;
  WebSearchRoomTarget? _pendingTarget;
  String? _dismissedTarget;
  Future<void>? _promptOperation;
  Future<void>? _externalOpenOperation;
  Future<WebSearchBackDisposition>? _backOperation;
  Future<void>? _closeOperation;
  int _generation = 0;
  bool _closed = false;

  bool get usesExternalBrowser => useExternalBrowser ?? Platform.isLinux;

  bool get hasValidLaunchRequest => launchRequest != null;

  Uri? get initialUri => launchRequest?.uri;

  String getDynamicUserAgent() {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';
  }

  @override
  void onInit() {
    super.onInit();
    _closed = false;
    final arguments = initialArguments ?? Get.arguments;
    launchRequest = parseWebSearchLaunchRequest(arguments);
    final request = launchRequest;
    if (request == null) {
      showWebView.value = false;
      _setFailure('web_search_invalid_address');
      _logWarning('[WebSearch] Rejected invalid launch arguments.');
      return;
    }
    _logInfo('[WebSearch] Initialized for ${request.uri.scheme}://${request.uri.host} (${request.platform}).');
    currentUrl.value = request.uri.toString();
    if (!usesExternalBrowser) _startCreationWatchdog();
  }

  Future<void> openExternalBrowser() {
    final existing = _externalOpenOperation;
    if (existing != null) return existing;
    final request = launchRequest;
    if (_closed || request == null) {
      if (!_closed) _notice('web_search_invalid_address');
      return Future.value();
    }

    final generation = _generation;
    isOpeningExternal.value = true;
    late final Future<void> task;
    task = _openExternal(request.uri, generation).whenComplete(() {
      if (identical(_externalOpenOperation, task)) {
        _externalOpenOperation = null;
        if (_isCurrent(generation)) isOpeningExternal.value = false;
      }
    });
    _externalOpenOperation = task;
    return task;
  }

  Future<void> _openExternal(Uri uri, int generation) async {
    var opened = false;
    try {
      opened = await _launchExternal(uri);
    } catch (error) {
      debugPrint('[WebSearch] External browser launch failed: $error');
    }
    if (_isCurrent(generation) && !opened) _notice('external_browser_not_opened');
  }

  void onWebViewCreated(InAppWebViewController controller) {
    _nativeController = controller;
    unawaited(attachBrowser(_InAppWebSearchBrowser(controller), nativeController: controller));
  }

  @visibleForTesting
  Future<void> attachBrowser(WebSearchBrowser browser, {InAppWebViewController? nativeController}) async {
    final request = launchRequest;
    if (_closed || request == null || usesExternalBrowser) {
      await _disposeSpecificBrowser(browser);
      return;
    }

    final previous = _browser;
    _browser = browser;
    _nativeController = nativeController;
    _cancelCreationWatchdog();
    if (previous != null && !identical(previous, browser)) {
      await _disposeSpecificBrowser(previous);
    }
    if (_closed || !identical(_browser, browser)) return;

    _beginMainFrameLoad();
    await _loadWithBrowser(browser, request.uri);
  }

  Future<void> _loadWithBrowser(WebSearchBrowser browser, Uri uri) async {
    final generation = _generation;
    try {
      await browser.load(uri);
    } catch (error) {
      if (!_closed && identical(_browser, browser) && _isCurrent(generation)) {
        debugPrint('[WebSearch] Page load threw (non-fatal): $error');
      }
    }
  }

  /// 渲染进程连续崩溃的自动恢复上限；超过后转为失败态让用户手动重试。
  static const int _maxRenderRecoveries = 3;
  int _renderRecoveries = 0;

  /// 恢复请求去重窗口：同一次进程失败常经由多个事件重复上报（如
  /// RENDER_PROCESS_EXITED 同时触发 onWebContentProcessDidTerminate 与
  /// onProcessFailed），窗口内的重复请求直接忽略，避免连环 reload。
  static const Duration _recoveryDebounce = Duration(seconds: 2);
  DateTime? _lastRecoveryAt;

  /// 渲染进程退出/崩溃后 WebView2 合成停止产帧，用户看到的就是“全黑”；
  /// 必须监听该事件并自动 reload 恢复内容，而不是留在黑屏上。
  void onRenderProcessGone(InAppWebViewController controller, RenderProcessGoneDetail detail) {
    if (!_acceptNativeController(controller)) return;
    _logWarning('[WebSearch] WebView render process gone (didCrash: ${detail.didCrash}).');
    _recoverRenderProcess();
  }

  /// Windows 上渲染进程退出（RENDER_PROCESS_EXITED）经此事件上报。
  void onWebContentProcessDidTerminate(InAppWebViewController controller) {
    if (!_acceptNativeController(controller)) return;
    _logWarning('[WebSearch] WebView content process terminated.');
    _recoverRenderProcess();
  }

  Future<WebViewRenderProcessAction?> onRenderProcessUnresponsive(InAppWebViewController controller, Uri? url) async {
    if (!_acceptNativeController(controller)) return null;
    _logWarning('[WebSearch] WebView render process unresponsive (${url?.host ?? 'unknown host'}).');
    return null;
  }

  /// Windows 专属进程失败总通道：渲染/帧渲染/GPU 进程失败均经此上报
  /// （onRenderProcessGone 只覆盖渲染进程，GPU 进程失败只有这里能看到）。
  ///
  /// GPU 进程退出时 WebView2 会自动重建进程，但本插件的画面走
  /// Windows.Graphics.Capture 捕获合成视觉，GPU 重启后捕获链可能不再产帧
  /// （表现为内容区全黑而 Flutter 界面正常），因此对渲染进程退出与 GPU
  /// 进程退出都尝试 reload 强制页面重新渲染；工具类进程退出不影响画面，
  /// 仅记录日志。
  void onProcessFailed(InAppWebViewController controller, ProcessFailedDetail detail) {
    if (!_acceptNativeController(controller)) return;
    _logWarning(
      '[WebSearch] WebView process failed (kind: ${detail.kind}, '
      'reason: ${detail.reason}, exitCode: ${detail.exitCode}, '
      'process: ${detail.processDescription ?? ''}).',
    );
    final kind = detail.kind;
    if (kind == ProcessFailedKind.RENDER_PROCESS_EXITED || kind == ProcessFailedKind.GPU_PROCESS_EXITED) {
      _recoverRenderProcess();
    }
  }

  void _recoverRenderProcess() {
    final browser = _browser;
    if (browser == null || _closed) return;
    final now = DateTime.now();
    final last = _lastRecoveryAt;
    if (last != null && now.difference(last) < _recoveryDebounce) {
      _logWarning('[WebSearch] Recovery request suppressed within debounce window.');
      return;
    }
    _lastRecoveryAt = now;
    if (_renderRecoveries >= _maxRenderRecoveries) {
      _logWarning('[WebSearch] Render process keeps crashing; giving up after $_renderRecoveries recoveries.');
      _setFailure('web_search_load_failed');
      return;
    }
    _renderRecoveries++;
    unawaited(_reloadAfterRecovery(browser));
  }

  Future<void> _reloadAfterRecovery(WebSearchBrowser browser) async {
    try {
      await browser.reload();
    } catch (error) {
      if (!_closed && identical(_browser, browser)) {
        debugPrint('[WebSearch] Render recovery reload failed: $error');
      }
    }
  }

  /// 地址栏提交跳转：规范化后经当前浏览器加载；
  /// WebView 尚未创建成功时忽略（失败态已有重试入口）。
  Future<void> navigateTo(String rawUrl) {
    if (_closed) return Future.value();
    final browser = _browser;
    if (browser == null) return Future.value();
    final uri = _parseHttpUri(rawUrl.trim().replaceAll(RegExp(r'[\r\n\t]'), ''));
    if (uri == null) return Future.value();
    _beginMainFrameLoad();
    currentUrl.value = uri.toString();
    return _loadWithBrowser(browser, uri);
  }

  void onLoadStart(InAppWebViewController controller, WebUri? uri) {
    if (!_acceptNativeController(controller)) return;
    final documentUri = _parseHttpUri(uri?.toString());
    if (documentUri == null) return;
    _beginMainFrameLoad();
    currentUrl.value = documentUri.toString();
    unawaited(observeUrl(documentUri.toString()));
  }

  void onUpdateVisitedHistory(InAppWebViewController controller, WebUri? uri, bool? isReload) {
    if (!_acceptNativeController(controller) || uri == null) return;
    final parsed = _parseHttpUri(uri.toString());
    if (parsed != null) currentUrl.value = parsed.toString();
    unawaited(observeUrl(uri.toString()));
  }

  Future<void> onLoadStop(InAppWebViewController controller, WebUri? uri) async {
    if (!_acceptNativeController(controller)) return;
    final documentUri = _parseHttpUri(uri?.toString());
    if (documentUri == null) return;
    if (errorMessageKey.value.isEmpty) {
      viewStatus.value = WebSearchViewStatus.ready;
      loadProgress.value = 100;
    }
    currentUrl.value = documentUri.toString();
    _renderRecoveries = 0;
    unawaited(observeUrl(documentUri.toString()));

    final generation = _generation;
    try {
      await _flushCookies();
      if (_isCurrent(generation)) _logInfo('[WebSearch] Persisted browser cookies.');
    } catch (error) {
      debugPrint('[WebSearch] Cookie flush failed: $error');
    }
  }

  void onProgressChanged(InAppWebViewController controller, int progress) {
    if (!_acceptNativeController(controller) || viewStatus.value == WebSearchViewStatus.failed) return;
    loadProgress.value = progress.clamp(0, 100);
  }

  void onReceivedHttpError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (!_acceptNativeController(controller)) return;
    final uri = _parseHttpUri(request.url.toString());
    _logWarning(
      '[WebSearch] HTTP status ${response.statusCode} for ${uri?.host ?? 'unknown host'} (mainFrame: ${request.isForMainFrame}).',
    );
  }

  void onReceivedError(InAppWebViewController controller, WebResourceRequest request, WebResourceError error) {
    if (!_acceptNativeController(controller)) return;
    final uri = _parseHttpUri(request.url.toString());
    _logWarning(
      '[WebSearch] Load error on ${uri?.host ?? 'unknown host'} (${error.type}, mainFrame: ${request.isForMainFrame}).',
    );
  }

  Future<ServerTrustAuthResponse?> onReceivedServerTrustAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  ) async {
    if (_acceptNativeController(controller)) {
      _logWarning('[WebSearch] Rejected an untrusted certificate for ${challenge.protectionSpace.host}.');
    }
    return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL);
  }

  void onConsoleMessage(InAppWebViewController controller, ConsoleMessage consoleMessage) {
    if (kDebugMode && _acceptNativeController(controller) && consoleMessage.messageLevel == ConsoleMessageLevel.ERROR) {
      debugPrint('[WebSearch] Browser console reported an error.');
    }
  }

  Future<NavigationActionPolicy> shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    // 身份不匹配只应让其他回调忽略事件，绝不能作为导航策略取消导航：
    // 首次导航若被静默 CANCEL，页面将永远加载不出来（对齐开发版永远放行）。
    if (_acceptNativeController(controller)) {
      final uri = action.request.url;
      if (uri != null) {
        final link = uri.toString();
        unawaited(observeUrl(link));
      }
    }
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> observeUrl(String rawUrl) {
    if (_closed) return Future.value();
    final uri = _parseHttpUri(rawUrl.trim().replaceAll(RegExp(r'[\r\n\t]'), ''));
    if (uri == null) return Future.value();
    final target = WebSearchRoomParser.parse(uri.toString());
    if (target == null) {
      _dismissedTarget = null;
      return Future.value();
    }
    if (_dismissedTarget == target.key) return Future.value();

    _pendingTarget = target;
    final existing = _promptOperation;
    if (existing != null) return existing;
    final generation = _generation;
    late final Future<void> task;
    task = _drainPromptQueue(generation).whenComplete(() {
      if (identical(_promptOperation, task)) _promptOperation = null;
    });
    _promptOperation = task;
    return task;
  }

  Future<void> _drainPromptQueue(int generation) async {
    while (_isCurrent(generation)) {
      final target = _pendingTarget;
      _pendingTarget = null;
      if (target == null) return;
      if (_dismissedTarget == target.key) continue;

      roomId.value = target.roomId;
      developer.log('[WebSearch] Detected a supported ${target.platform} room link.');
      bool? confirmed;
      try {
        confirmed = await _confirmRoom(target);
      } catch (error) {
        debugPrint('[WebSearch] Room confirmation failed: $error');
      }
      if (!_isCurrent(generation)) return;
      if (confirmed != true) {
        _dismissedTarget = target.key;
        continue;
      }

      _pendingTarget = null;
      showWebView.value = false;
      await _disposeBrowser();
      if (!_isCurrent(generation)) return;
      try {
        await _openRoom(LiveRoom(roomId: target.roomId, platform: target.platform));
      } catch (error) {
        if (!_isCurrent(generation)) return;
        debugPrint('[WebSearch] Opening the detected room failed: $error');
        _setFailure('get_room_info_failed_retry');
        showWebView.value = true;
        _notice('get_room_info_failed_retry');
      }
      return;
    }
  }

  /// WebView 插件在 Windows 上原生创建失败时 [onWebViewCreated] 永不触发，
  /// 页面会停留在无限空白加载且无任何报错；看门狗超时后兜底转为失败态，
  /// 让用户可以点击重试（retry 会强制重建 WebView）。
  void _startCreationWatchdog() {
    _cancelCreationWatchdog();
    _creationWatchdog = Timer(const Duration(seconds: 10), () {
      if (_closed || _browser != null || usesExternalBrowser) return;
      if (viewStatus.value != WebSearchViewStatus.loading) return;
      _logWarning('[WebSearch] WebView was not created within 10s; marking the load as failed.');
      _setFailure('web_search_load_failed');
    });
  }

  void _cancelCreationWatchdog() {
    _creationWatchdog?.cancel();
    _creationWatchdog = null;
  }

  /// 重载页面；[force] 为 true 时销毁并重建整个 WebView 控件（而非仅 reload）。
  ///
  /// force 用于黑屏自救：插件原生渲染链（Windows.Graphics.Capture 捕获
  /// WebView2 合成视觉）可能静默死亡——页面加载事件仍在持续（cookie 持久化
  /// 正常），但捕获链不再产帧，画面全黑。此时 reload 无法恢复，只有重建
  /// 控件（新纹理、新捕获链）才能恢复。重建后恢复即确诊该路径。
  Future<void> retry({bool force = false}) async {
    final request = launchRequest;
    if (_closed || request == null) return;
    errorMessageKey.value = '';
    viewStatus.value = WebSearchViewStatus.loading;
    loadProgress.value = 0;
    final browser = _browser;
    if (browser != null && force) {
      _logWarning('[WebSearch] Rebuilding the WebView control (forced).');
      await _disposeBrowser();
      showWebView.value = false;
      if (_closed) return;
      await Future.delayed(const Duration(milliseconds: 100));
      if (_closed) return;
      _startCreationWatchdog();
      showWebView.value = true;
      return;
    }
    if (browser == null) {
      // 原生 WebView 创建失败时没有可 reload 的控制器；
      // 先把控件移出控件树再延时放回，强制重建 InAppWebView 重新走创建流程。
      showWebView.value = false;
      _startCreationWatchdog();
      await Future.delayed(const Duration(milliseconds: 100));
      if (_closed) return;
      showWebView.value = true;
      return;
    }
    showWebView.value = true;
    try {
      await browser.reload();
    } catch (error) {
      if (!_closed && identical(_browser, browser)) {
        debugPrint('[WebSearch] Page reload failed: $error');
        _setFailure('web_search_load_failed');
      }
    }
  }

  Future<void> openDevTools() async {
    if (_closed) return;
    try {
      await _browser?.openDevTools();
    } catch (error) {
      debugPrint('[WebSearch] Developer tools failed to open: $error');
    }
  }

  Future<WebSearchBackDisposition> requestBack() {
    final existing = _backOperation;
    if (existing != null) return existing;
    late final Future<WebSearchBackDisposition> task;
    task = _performBack().whenComplete(() {
      if (identical(_backOperation, task)) _backOperation = null;
    });
    _backOperation = task;
    return task;
  }

  Future<WebSearchBackDisposition> _performBack() async {
    if (_closed) return WebSearchBackDisposition.closePage;
    final browser = _browser;
    if (browser != null) {
      try {
        if (await browser.canGoBack()) {
          if (_closed || !identical(_browser, browser)) return WebSearchBackDisposition.closePage;
          await browser.goBack();
          return WebSearchBackDisposition.stayOnPage;
        }
      } catch (error) {
        debugPrint('[WebSearch] Browser history navigation failed: $error');
      }
    }
    await closeWebSearch();
    return WebSearchBackDisposition.closePage;
  }

  Future<void> closeWebSearch() {
    final existing = _closeOperation;
    if (existing != null) return existing;
    _closed = true;
    _generation++;
    _cancelCreationWatchdog();
    _pendingTarget = null;
    showWebView.value = false;
    isOpeningExternal.value = false;
    late final Future<void> task;
    task = _disposeBrowser().whenComplete(() {
      if (identical(_closeOperation, task)) _closeOperation = null;
    });
    _closeOperation = task;
    return task;
  }

  void _beginMainFrameLoad() {
    errorMessageKey.value = '';
    viewStatus.value = WebSearchViewStatus.loading;
    loadProgress.value = 0;
  }

  void _setFailure(String localizationKey) {
    errorMessageKey.value = localizationKey;
    viewStatus.value = WebSearchViewStatus.failed;
    // 失败界面取代网页区域（页面结构不再用覆盖层盖住 WebView），必须同步
    // 卸载浏览器：控件已移出控件树，旧 controller 已销毁，若保留 _browser
    // 引用，retry 会 reload 到已 dispose 的实例并再次失败，形成失败循环。
    showWebView.value = false;
    unawaited(_disposeBrowser());
  }

  /// 校验事件是否来自当前 WebView。
  ///
  /// 插件对 onWebViewCreated 与各事件回调分别调用 controllerFromPlatform
  /// 工厂，每次都会新建一个 InAppWebViewController 包装实例，因此包装
  /// 实例本身永不相等（会导致所有事件被静默丢弃：房间检测失效、进度条
  /// 卡在加载中、地址栏不更新）；但它们包装的是同一个平台控制器，
  /// 必须比较底层 platform 实例来判断同一 WebView。
  bool _acceptNativeController(InAppWebViewController controller) {
    final native = _nativeController;
    return !_closed && native != null && identical(native.platform, controller.platform);
  }

  bool _isCurrent(int generation) => !_closed && generation == _generation;

  Uri? _parseHttpUri(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return uri;
  }

  Future<void> _disposeBrowser() async {
    final browser = _browser;
    _browser = null;
    _nativeController = null;
    if (browser != null) await _disposeSpecificBrowser(browser);
  }

  Future<void> _disposeSpecificBrowser(WebSearchBrowser browser) async {
    try {
      await browser.stopLoading();
    } catch (error) {
      debugPrint('[WebSearch] Stopping the browser failed: $error');
    }
    try {
      browser.dispose();
    } catch (error) {
      debugPrint('[WebSearch] Disposing the browser failed: $error');
    }
  }

  @override
  void onClose() {
    _cancelCreationWatchdog();
    if (!_closed) {
      _closed = true;
      _generation++;
      _pendingTarget = null;
      showWebView.value = false;
    }
    unawaited(_disposeBrowser());
    super.onClose();
  }

  static Future<bool> _defaultLaunchExternal(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool?> _defaultConfirmRoom(WebSearchRoomTarget target) {
    return Utils.showAlertDialog(
      i18n('detected_room_id_open'),
      title: i18n('tip'),
      confirm: i18n('confirm'),
      cancel: i18n('cancel'),
    );
  }

  static Future<void> _defaultOpenRoom(LiveRoom room) {
    return AppNavigator.offAndToRoomDetail(liveRoom: room);
  }

  static Future<void> _defaultFlushCookies() {
    // Windows 原生未实现 flush（调用只会抛 MissingPluginException 且被忽略），
    // 但插件在分发方法前会先创建默认 WebViewEnvironment；直接跳过，
    // 避免每次加载都额外拉起默认用户数据目录的浏览器进程。
    if (!kIsWeb && Platform.isWindows) return Future.value();
    return CookieManager.instance(webViewEnvironment: AppWebView2Environment.optional).flush();
  }

  static void _defaultNotice(String localizationKey) {
    ToastUtil.show(i18n(localizationKey));
  }

  static void _logInfo(String message) {
    if (Get.isRegistered<LogController>()) {
      Log.i(message);
    } else {
      debugPrint(message);
    }
  }

  static void _logWarning(String message) {
    if (Get.isRegistered<LogController>()) {
      Log.w(message);
    } else {
      debugPrint(message);
    }
  }
}
