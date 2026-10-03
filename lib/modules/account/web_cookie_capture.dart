import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/core/common/cookie_string.dart';
import 'package:pure_live/core/utils/web_view2_environment.dart';
import 'package:pure_live/modules/account/cookie_validator.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';

/// 平台抓取配置：登录页地址与 Cookie 归属域名。
class CookieCaptureTarget {
  const CookieCaptureTarget({
    required this.platform,
    required this.loginUrl,
    required this.domains,
    this.excludeCookieNames = const <String>{},
    this.extraCookieUrls = const <String>[],
    this.clearAfterCapture = false,
  });

  /// 平台标识（与账户模块一致），用于抓取后经平台接口校验登录态。
  final String platform;

  /// 打开的登录页/站点地址。
  final String loginUrl;

  /// Cookie 归属域名（后缀匹配，如 'twitch.tv' 匹配 '.twitch.tv'）。
  final List<String> domains;

  /// 抓取结果中剔除的 Cookie 名。
  ///
  /// 按域名后缀过滤会连登录流程顺带下发的其他子域 Cookie 一起收进来；
  /// 有的平台（如斗鱼）passport 会话字段混进请求头会直接被边缘节点
  /// 拒绝（裸 403），因此这些字段在组装时就要丢掉。
  final Set<String> excludeCookieNames;

  /// 额外查询 Cookie 的 URL（登录页之外）。
  ///
  /// `getCookies` 只返回"浏览器访问该 URL 时会带上"的 Cookie，host-only
  /// 的凭证域 Cookie（如斗鱼 `LTP0`，Domain 限定在 passport.douyu.com）
  /// 不会出现在登录页的结果里；对凭证域再查一次才能捞全。这些域名也
  /// 必须落在 [domains] 的后缀范围内，否则组装时仍会被过滤掉。
  final List<String> extraCookieUrls;

  /// 抓取成功后清除 WebView 里该域的会话 Cookie（浏览器回到游客态）。
  ///
  /// 斗鱼的 passport 续期会撤销 web 会话令牌：WebView 里留着的活会话在
  /// app 侧续期后会被服务端判死，此后页面弹"未登录"并反复刷新。抓取
  /// 完成即清场，续期时就没有可被踢的会话。
  final bool clearAfterCapture;
}

/// 各平台抓取配置（key 与账户模块的平台标识一致）。
const Map<String, CookieCaptureTarget> kCookieCaptureTargets = {
  'douyin': CookieCaptureTarget(platform: 'douyin', loginUrl: 'https://www.douyin.com/', domains: ['douyin.com']),
  'huya': CookieCaptureTarget(platform: 'huya', loginUrl: 'https://www.huya.com/', domains: ['huya.com']),
  'kuaishou': CookieCaptureTarget(
    platform: 'kuaishou',
    loginUrl: 'https://www.kuaishou.com/',
    domains: ['kuaishou.com'],
  ),
  'soop': CookieCaptureTarget(platform: 'soop', loginUrl: 'https://www.sooplive.co.kr/', domains: ['sooplive.co.kr']),
  'twitch': CookieCaptureTarget(platform: 'twitch', loginUrl: 'https://www.twitch.tv/login', domains: ['twitch.tv']),
  // 斗鱼 Web 版：会话令牌是 dy_auth（不透明、七天），没有 LTP0 可续期，
  // 抓到什么就用什么。passport 会话字段（acf_stk 等）不属于登录态，混进
  // Cookie 头会被播放接口的边缘节点裸 403，按域名后缀抓取时必须剔除；
  // LTP0/dy_did 若登录流程有下发则保留——它们正是续期需要的凭证。
  // LTP0 是 passport.douyu.com 的 host-only Cookie，查登录页拿不到，
  // 需要对 passport 域再查一次（Web 登录页本身就在该域，cookie 一定存在）。
  // clearAfterCapture：passport 续期会撤销 web 会话，抓完就清掉 WebView
  // 里的登录态，续期时没有可被踢的活会话，页面不会再弹"未登录"刷屏。
  'douyu': CookieCaptureTarget(
    platform: 'douyu',
    loginUrl: 'https://www.douyu.com/',
    domains: ['douyu.com'],
    excludeCookieNames: {'acf_stk', 'acf_ccn', 'acf_ltkid', 'acf_ssid'},
    extraCookieUrls: ['https://passport.douyu.com/'],
    clearAfterCapture: true,
  ),
};

/// 按 [domains] 过滤并组装 `name=value; ...`；同名 Cookie 后值覆盖前值。
/// [excludeNames] 中的 Cookie 名（不区分大小写）不进入结果。
String? assembleCookieString(List<Cookie> cookies, List<String> domains, {Set<String>? excludeNames}) {
  final excluded = excludeNames?.map((name) => name.toLowerCase());
  final byName = <String, String>{};
  for (final cookie in cookies) {
    if (cookie.name.isEmpty) continue;
    if (excluded != null && excluded.contains(cookie.name.toLowerCase())) continue;
    if (!cookieDomainMatches(cookie.domain ?? '', domains)) continue;
    byName[cookie.name] = cookie.value?.toString() ?? '';
  }
  if (byName.isEmpty) return null;
  return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 内置浏览器（InAppWebView）Cookie 抓取。
///
/// 打开全屏网页加载平台登录页，用户在页面内完成登录后点击
/// 「我已登录完成」，经 [CookieManager] 按域名过滤组装
/// `name=value; ...`，再经平台接口校验登录态后返回。
class WebCookieCapturePage extends StatefulWidget {
  const WebCookieCapturePage({super.key, required this.target});

  final CookieCaptureTarget target;

  /// 打开内置浏览器抓取页并等待用户完成登录；
  /// 捕获成功返回 Cookie 字符串，返回/取消返回 null。
  static Future<String?> capture(CookieCaptureTarget target) async {
    return Get.to<String>(
      () => WebCookieCapturePage(target: target),
      routeName: SettingsCrumbs.cookieCapture.routeName,
    );
  }

  @override
  State<WebCookieCapturePage> createState() => _WebCookieCapturePageState();
}

class _WebCookieCapturePageState extends State<WebCookieCapturePage> {
  bool _busy = false;
  bool _closing = false;
  bool _showWebView = true;
  bool _isLoading = false;
  String _currentUrl = '';
  int _loadProgress = 0;

  @override
  void initState() {
    super.initState();
    _currentUrl = target.loginUrl;
  }

  /// 当前页面的 WebView 控制器。Windows 上 CookieManager 未绑定控制器时
  /// 会创建并销毁一个临时 WebView2，该路径在 ICoreWebView2 内部有已知
  /// 崩溃；所有 Cookie 读写必须绑定此控制器走当前 WebView。
  InAppWebViewController? _webViewController;

  CookieCaptureTarget get target => widget.target;

  /// 统一的安全关闭路径：所有离开本页的入口（AppBar 返回键、系统返回、
  /// 捕获成功自动关闭）都必须经过这里。若带着活跃的平台视图直接 pop，
  /// 视图会在路由转场动画帧中被引擎合成器销毁，Windows 上触发
  /// flutter_windows.dll 内的访问违规闪退；必须先把控件移出控件树、
  /// 停止加载并销毁控制器，等待若干帧后再 pop。
  Future<void> _safeClose([String? result]) async {
    if (_closing || !mounted) return;
    _closing = true;
    final controller = _webViewController;
    _webViewController = null;
    if (_showWebView) setState(() => _showWebView = false);
    if (controller != null) {
      try {
        await controller.stopLoading();
      } catch (_) {}
      try {
        // dispose 在插件中返回 void，无法 await；控件已移出控件树，同步销毁即可。
        controller.dispose();
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _completeLogin() async {
    final controller = _webViewController;
    if (_busy || controller == null) return;
    setState(() => _busy = true);
    try {
      // 查询 URL 按 [CookieCaptureTarget.extraCookieUrls] 扩展：凭证域的
      // host-only Cookie 不在登录页的查询结果里，必须对它单独查一次。
      final captureUrls = <WebUri>[WebUri(target.loginUrl), ...target.extraCookieUrls.map(WebUri.new)];
      final cookies = <Cookie>[];
      for (final url in captureUrls) {
        cookies.addAll(await CookieManager.instance().getCookies(url: url, webViewController: controller));
      }
      final cookie = assembleCookieString(cookies, target.domains, excludeNames: target.excludeCookieNames);
      if (!mounted) return;
      if (cookie == null || cookie.isEmpty) {
        ToastUtil.show(i18n('cookie_capture_empty_hint'));
        return;
      }
      final validation = await CookieValidator.validate(target.platform, cookie);
      if (!mounted) return;
      switch (validation) {
        case CookieValidationStatus.valid || CookieValidationStatus.unverified:
          await _clearWebSessionAfterCapture();
          await _safeClose(cookie);
        case CookieValidationStatus.invalid:
          ToastUtil.show(i18n('cookie_invalid_retry'));
        case CookieValidationStatus.error:
          ToastUtil.show(i18n('cookie_check_failed'));
      }
    } catch (_) {
      if (mounted) ToastUtil.show(i18n('cookie_check_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 抓取成功后清除 WebView 里该域的会话（配置了 [CookieCaptureTarget.clearAfterCapture] 的平台）。
  ///
  /// 走 environment 级 CDP：没有活动页面时原生端会建临时隐藏 WebView 执行、
  /// 用完即关，与页面控制器的销毁时序互不影响。
  Future<void> _clearWebSessionAfterCapture() async {
    if (!target.clearAfterCapture) return;
    try {
      final environment = AppWebView2Environment.optional;
      if (environment == null) return;
      final manager = CookieManager.instance(webViewEnvironment: environment);
      for (final url in <String>[target.loginUrl, ...target.extraCookieUrls]) {
        await manager.deleteCookies(url: WebUri(url));
      }
    } catch (_) {
      // 清理失败不影响捕获结果：app 侧 Cookie 已拿到并保存。
    }
  }

  /// 页面加载回调中同步地址栏展示的当前网址。
  void _updateAddressBarUrl(WebUri? uri) {
    final url = uri?.toString();
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _currentUrl = url);
  }

  /// 地址栏提交跳转。
  Future<void> _navigateTo(String url) async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (_) {}
  }

  /// 重建页面：重新加载当前地址栏的网址。画面异常或站点行为奇怪时，
  /// 观看者可以不退出抓取页直接重来。
  Future<void> _reloadPage() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_currentUrl)));
    } catch (_) {}
  }

  /// 打开 WebView2 开发者工具；要求 WebView 以 isInspectable 创建。
  Future<void> _openDevTools() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      await controller.openDevTools();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_safeClose());
      },
      child: Scaffold(
        appBar: SettingsBreadcrumbAppBar(
          node: SettingsCrumbs.cookieCapture.withPage(() => WebCookieCapturePage(target: target)),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: i18n('web_search_rebuild'),
              onPressed: _webViewController == null ? null : () => unawaited(_reloadPage()),
            ),
            IconButton(
              icon: const Icon(Icons.bug_report),
              tooltip: i18n('web_search_devtools'),
              onPressed: _webViewController == null ? null : () => unawaited(_openDevTools()),
            ),
            TextButton(
              onPressed: _busy || _webViewController == null ? null : _completeLogin,
              child: Text(i18n('cookie_capture_done_button')),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              child: Text(
                '${i18n('cookie_capture_waiting')}\n${i18n('cookie_capture_waiting_hint')}',
                style: AppTextStyles.t12.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ),
            WebViewAddressBar(currentUrl: _currentUrl, onSubmit: (url) => unawaited(_navigateTo(url))),
            // 加载进度：地址栏下方的独立窄条，不覆盖网页区域。开始加载但
            // 还没收到首个进度回调时保持 indeterminate 滚动（与网页搜索页
            // 一致），收到进度后转为确定进度，加载结束消失。
            if (_showWebView && _isLoading)
              LinearProgressIndicator(value: _loadProgress > 0 && _loadProgress < 100 ? _loadProgress / 100 : null),
            Expanded(
              child: _showWebView
                  ? InAppWebView(
                      webViewEnvironment: AppWebView2Environment.optional,
                      initialUrlRequest: URLRequest(url: WebUri(target.loginUrl)),
                      onWebViewCreated: (controller) => setState(() => _webViewController = controller),
                      onLoadStart: (_, uri) {
                        _updateAddressBarUrl(uri);
                        if (mounted) {
                          setState(() {
                            _isLoading = true;
                            _loadProgress = 0;
                          });
                        }
                      },
                      onLoadStop: (_, uri) {
                        _updateAddressBarUrl(uri);
                        if (mounted) {
                          setState(() {
                            _isLoading = false;
                            _loadProgress = 0;
                          });
                        }
                      },
                      onReceivedError: (controller, request, error) {
                        // 主框架加载失败时结束进度显示，避免进度条挂住。
                        if (!mounted || request.isForMainFrame == false) return;
                        setState(() {
                          _isLoading = false;
                          _loadProgress = 0;
                        });
                      },
                      onProgressChanged: (_, progress) {
                        if (!mounted) return;
                        setState(() => _loadProgress = progress.clamp(0, 100));
                      },
                      onUpdateVisitedHistory: (_, uri, _) => _updateAddressBarUrl(uri),
                      initialSettings: InAppWebViewSettings(
                        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
                        javaScriptEnabled: true,
                        useWideViewPort: true,
                        loadWithOverviewMode: true,
                        supportZoom: true,
                        builtInZoomControls: true,
                        displayZoomControls: false,
                        domStorageEnabled: true,
                        databaseEnabled: true,
                        thirdPartyCookiesEnabled: true,
                        cacheEnabled: true,
                        // AppBar 的调试按钮经 openDevTools 打开开发者工具，
                        // WebView2 只有可检视的 WebView 才允许附加。
                        isInspectable: true,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
