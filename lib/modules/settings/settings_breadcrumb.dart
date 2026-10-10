import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';

import 'package:pure_live/modules/account/account_page.dart';
import 'package:pure_live/modules/account/account_bing.dart';
import 'package:pure_live/modules/account/bilibili/bilibili_bings.dart';
import 'package:pure_live/modules/account/bilibili/qr_login_page.dart';
import 'package:pure_live/modules/account/bilibili/web_login_page.dart';
import 'package:pure_live/modules/account/douyin/douyin_cookie_binding.dart';
import 'package:pure_live/modules/account/douyin/douyin_cookie_page.dart';
import 'package:pure_live/modules/account/douyu/douyu_cookie_binding.dart';
import 'package:pure_live/modules/account/douyu/douyu_cookie_page.dart';
import 'package:pure_live/modules/account/huya/huya_cookie_binding.dart';
import 'package:pure_live/modules/account/huya/huya_cookie_page.dart';
import 'package:pure_live/modules/account/kuaishou/kuaishou_cookie_binding.dart';
import 'package:pure_live/modules/account/kuaishou/kuaishou_cookie_page.dart';
import 'package:pure_live/modules/account/soop/soop_cookie_binding.dart';
import 'package:pure_live/modules/account/soop/soop_cookie_page.dart';
import 'package:pure_live/modules/account/taobao/taobao_cookie_binding.dart';
import 'package:pure_live/modules/account/taobao/taobao_cookie_page.dart';
import 'package:pure_live/modules/account/twitch/twitch_cookie_binding.dart';
import 'package:pure_live/modules/account/twitch/twitch_cookie_page.dart';
import 'package:pure_live/modules/account/yy/yy_cookie_binding.dart';
import 'package:pure_live/modules/account/yy/yy_cookie_page.dart';
import 'package:pure_live/modules/backup/backup_page.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_page.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_binding.dart';
import 'package:pure_live/modules/hot_areas/hot_areas_page.dart';
import 'package:pure_live/modules/hot_areas/hot_areas_binding.dart';
import 'package:pure_live/modules/iptv/iptv_page.dart';
import 'package:pure_live/modules/iptv/iptv_manage.dart';
import 'package:pure_live/modules/settings/pages/audience_metric_settings_page.dart';
import 'package:pure_live/modules/settings/pages/audio_output_settings_page.dart';
import 'package:pure_live/modules/settings/pages/cache_data_settings_page.dart';
import 'package:pure_live/modules/settings/pages/decoder_settings.dart';
import 'package:pure_live/modules/settings/pages/font_family_manager_page.dart';
import 'package:pure_live/modules/settings/pages/font_settings_page.dart';
import 'package:pure_live/modules/settings/pages/general_settings_page.dart';
import 'package:pure_live/modules/settings/pages/loading_style_settings_page.dart';
import 'package:pure_live/modules/settings/pages/local_config_preveiw.dart';
import 'package:pure_live/modules/settings/pages/local_interaction_settings_page.dart';
import 'package:pure_live/modules/settings/pages/navigation_settings_page.dart';
import 'package:pure_live/modules/settings/pages/network_proxy_settings_page.dart';
import 'package:pure_live/modules/settings/pages/page_settings.dart';
import 'package:pure_live/modules/settings/pages/pip_danmaku_settings_page.dart';
import 'package:pure_live/modules/settings/pages/platform_settings_page.dart';
import 'package:pure_live/modules/settings/pages/player_kernel_settings_page.dart';
import 'package:pure_live/modules/settings/pages/refresh_settings.dart';
import 'package:pure_live/modules/settings/pages/renderer_settings.dart';
import 'package:pure_live/modules/settings/pages/room_card_settings_page.dart';
import 'package:pure_live/modules/settings/pages/theme_settings_page.dart';
import 'package:pure_live/modules/settings/pages/video_settings_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_settings_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_color_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_video_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_api_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_library_page.dart';
import 'package:pure_live/modules/wallpaper/pages/wallpaper_history_page.dart';
import 'package:pure_live/modules/settings/settings_page.dart';
import 'package:pure_live/modules/shield/danmu_shield_page.dart';
import 'package:pure_live/modules/shield/danmu_shield_binding.dart';
import 'package:pure_live/modules/tags/tag_management_page.dart';
import 'package:pure_live/modules/tags/tag_management_binding.dart';
import 'package:pure_live/modules/web_dav/web_dav_page.dart';
import 'package:pure_live/modules/web_dav/web_dav_binding.dart';
import 'package:pure_live/modules/web_dav/web_dav_help.dart';

/// 设置目录树中的一个节点（面包屑中的一项）。
class SettingsCrumb {
  /// i18n key（与 [labelText] 二选一）
  final String? labelKey;

  /// 直接指定的文案（无对应 i18n 时）
  final String? labelText;

  /// 路由唯一标识，用于面包屑回退时匹配栈中路由
  final String routeName;

  /// 页面构建器（打开/重载页面用）；构造参数不固定的页面由调用方通过
  /// [withPage] 注入。
  final Widget Function()? pageBuilder;

  /// 祖先节点（从根到父节点）
  final List<SettingsCrumb> parents;

  /// 打开页面时需要的 binding（替代原 named route 上注册的 binding）
  final dynamic binding;

  const SettingsCrumb({
    this.labelKey,
    this.labelText,
    required this.routeName,
    this.pageBuilder,
    this.parents = const <SettingsCrumb>[],
    this.binding,
  });

  String get label => labelText ?? i18n(labelKey!);

  /// 从根到当前节点的完整路径
  List<SettingsCrumb> get path => <SettingsCrumb>[...parents, this];

  /// 保留节点的路径信息、替换页面构建器（用于构造参数不固定的页面）
  SettingsCrumb withPage(Widget Function() builder) => SettingsCrumb(
    labelKey: labelKey,
    labelText: labelText,
    routeName: routeName,
    pageBuilder: builder,
    parents: parents,
    binding: binding,
  );
}

/// 设置目录导航：打开页面 / 回到祖先 / 重新加载当前页。
class SettingsNavigator {
  SettingsNavigator._();

  /// 沿目录树打开页面。
  static Future<T?>? open<T>(SettingsCrumb node) {
    assert(node.pageBuilder != null, 'SettingsCrumb "${node.routeName}" has no pageBuilder');
    return Get.to<T>(
      node.pageBuilder!,
      routeName: node.routeName,
      bindings: <BindingsInterface>[if (node.binding != null) node.binding as BindingsInterface],
    );
  }

  /// 重新加载当前页：替换当前路由，页面整体重建（滚动位置等临时状态复位，
  /// 设置数据保存在全局 SettingsService 中不受影响）。
  static Future<T?>? reload<T>(SettingsCrumb node) {
    assert(node.pageBuilder != null, 'SettingsCrumb "${node.routeName}" has no pageBuilder');
    return Get.off<T>(
      node.pageBuilder!,
      routeName: node.routeName,
      preventDuplicates: false,
      bindings: <BindingsInterface>[if (node.binding != null) node.binding as BindingsInterface],
    );
  }

  /// 回到目录路径上的某个祖先页。
  ///
  /// 栈中能找到目标时直接 popUntil 回退；
  /// 找不到时（例如从主菜单直接进入设置子页，栈中没有设置首页），
  /// 先 pop 到栈底（保留首页，避免黑屏），再依次 push 路径上每一级。
  static void backTo(SettingsCrumb target) {
    final context = Get.context;
    if (context == null) return;

    // 无损探测：读取 GetX 路由栈，确认目标是否已在栈中。
    final activePages = Get.rootController.rootDelegate.activePages;
    final targetInStack = activePages.any((decoder) => decoder.route?.name == target.routeName);

    if (targetInStack) {
      // 目标在栈中：直接 popUntil 回退。
      Navigator.popUntil(context, (route) => route.settings.name == target.routeName);
      return;
    }

    // 目标不在栈中：先 pop 到栈底（保留首页，避免黑屏），再依次 push 路径上每一级。
    // 不能用 Get.offAll：裁剪版 GetX 的 _replace 依赖 routeTree，匿名 pageBuilder
    // 不在 routeTree 中会导致 _getRouteDecoder 返回 null，触发 activePage! 崩溃。
    Navigator.popUntil(context, (route) => route.isFirst);
    _pushPath(context, target.path);
  }

  /// 从根到目标依次 push 每一级路径（在当前栈底之上）。
  static void _pushPath(BuildContext context, List<SettingsCrumb> path) {
    for (final node in path) {
      if (node.pageBuilder == null) continue;
      Get.to(
        node.pageBuilder!,
        routeName: node.routeName,
        preventDuplicates: false,
        bindings: <BindingsInterface>[if (node.binding != null) node.binding as BindingsInterface],
      );
    }
  }
}

/// 设置目录树节点注册表：页面层级、标题、页面构建与 binding 的单一事实来源。
class SettingsCrumbs {
  SettingsCrumbs._();

  // 设置主页
  static final SettingsCrumb root = SettingsCrumb(
    labelKey: 'settings_title',
    routeName: RoutePath.kSettings,
    pageBuilder: SettingsPage.new,
  );

  // —— 设置 > 刷新率 / 配置预览 ——
  static final SettingsCrumb refresh = SettingsCrumb(
    labelKey: 'refresh_settings',
    routeName: '/settings/refresh',
    pageBuilder: RefreshSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb configPreview = SettingsCrumb(
    labelKey: 'local_config_preview',
    routeName: '/settings/configPreview',
    pageBuilder: LocalConfigPreviewPage.new,
    parents: [root],
  );

  // —— 设置 > 主题定制 ——
  static final SettingsCrumb theme = SettingsCrumb(
    labelKey: 'theme_customization',
    routeName: '/settings/theme',
    pageBuilder: ThemeSettingsPage.new,
    parents: [root],
  );
  // —— 设置 > 壁纸 ——
  static final SettingsCrumb wallpaper = SettingsCrumb(
    labelKey: 'wallpaper_settings',
    labelText: '壁纸设置',
    routeName: '/settings/wallpaper',
    pageBuilder: WallpaperSettingsPage.new,
    parents: [root],
  );
  // —— 设置 > 壁纸 > 纯色渐变 ——
  static final SettingsCrumb wallpaperColor = SettingsCrumb(
    labelText: '纯色渐变',
    routeName: '/settings/wallpaper/color',
    pageBuilder: WallpaperColorPage.new,
    parents: [root, wallpaper],
  );
  // —— 设置 > 壁纸 > 动态壁纸 ——
  static final SettingsCrumb wallpaperVideo = SettingsCrumb(
    labelText: '动态壁纸',
    routeName: '/settings/wallpaper/video',
    pageBuilder: WallpaperVideoPage.new,
    parents: [root, wallpaper],
  );
  // —— 设置 > 壁纸 > 随机图源 ——
  static final SettingsCrumb wallpaperApi = SettingsCrumb(
    labelText: '随机图源',
    routeName: '/settings/wallpaper/api',
    pageBuilder: WallpaperApiPage.new,
    parents: [root, wallpaper],
  );
  // —— 设置 > 壁纸 > 壁纸库 ——
  static final SettingsCrumb wallpaperLibrary = SettingsCrumb(
    labelText: '壁纸库',
    routeName: '/settings/wallpaper/library',
    pageBuilder: WallpaperLibraryPage.new,
    parents: [root, wallpaper],
  );
  // —— 设置 > 壁纸 > 已保存壁纸 ——
  static final SettingsCrumb wallpaperHistory = SettingsCrumb(
    labelText: '已保存壁纸',
    routeName: '/settings/wallpaper/history',
    pageBuilder: WallpaperHistoryPage.new,
    parents: [root, wallpaper],
  );
  static final SettingsCrumb loading = SettingsCrumb(
    labelKey: 'change_loading_style',
    routeName: '/settings/theme/loading',
    pageBuilder: LoadingStyleSettingsPage.new,
    parents: [root, theme],
  );
  static final SettingsCrumb roomCard = SettingsCrumb(
    labelKey: 'room_card_settings',
    routeName: '/settings/theme/roomCard',
    pageBuilder: RoomCardSettingsPage.new,
    parents: [root, theme],
  );
  static final SettingsCrumb pageSettings = SettingsCrumb(
    labelKey: 'page_settings',
    routeName: '/settings/theme/pageSettings',
    pageBuilder: PageSettingsPage.new,
    parents: [root, theme],
  );
  static final SettingsCrumb fontFamily = SettingsCrumb(
    labelKey: 'font_family_settings',
    routeName: '/settings/theme/fontFamily',
    pageBuilder: FontFamilyManagerPage.new,
    parents: [root, theme],
  );
  static final SettingsCrumb font = SettingsCrumb(
    labelKey: 'font_settings_title',
    routeName: '/settings/theme/font',
    pageBuilder: FontSettingsPage.new,
    parents: [root, theme],
  );

  // —— 设置 > 通用 / 导航 / 平台 ——
  static final SettingsCrumb general = SettingsCrumb(
    labelKey: 'general',
    routeName: '/settings/general',
    pageBuilder: GeneralSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb navigation = SettingsCrumb(
    labelKey: 'navigation_display_settings',
    routeName: '/settings/navigation',
    pageBuilder: NavigationSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb platform = SettingsCrumb(
    labelKey: 'platform_settings',
    routeName: '/settings/platform',
    pageBuilder: PlatformSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb hotAreas = SettingsCrumb(
    labelKey: 'platform_display',
    routeName: '/settings/platform/hotAreas',
    pageBuilder: HotAreasPage.new,
    binding: HotAreasBinding(),
    parents: [root, platform],
  );
  static final SettingsCrumb account = SettingsCrumb(
    labelKey: 'third_party_auth',
    routeName: '/settings/platform/account',
    pageBuilder: AccountPage.new,
    binding: AccountBinding(),
    parents: [root, platform],
  );
  static final SettingsCrumb bilibiliQrLogin = SettingsCrumb(
    labelKey: 'bilibili_login',
    routeName: RoutePath.kBiliBiliQRLogin,
    pageBuilder: BiliBiliQRLoginPage.new,
    binding: BilibiliQrLoginBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb bilibiliWebLogin = SettingsCrumb(
    labelKey: 'bilibili_login',
    routeName: RoutePath.kBiliBiliWebLogin,
    pageBuilder: BiliBiliWebLoginPage.new,
    binding: BilibiliWebLoginBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb huyaCookie = SettingsCrumb(
    labelKey: 'site_huya',
    routeName: RoutePath.kHuyaCookie,
    pageBuilder: HuyaCookiePage.new,
    binding: HuyaCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb douyuCookie = SettingsCrumb(
    labelKey: 'site_douyu',
    routeName: RoutePath.kDouyuAccountCookie,
    pageBuilder: DouyuCookiePage.new,
    binding: DouyuCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb douyinCookie = SettingsCrumb(
    labelKey: 'site_douyin',
    routeName: RoutePath.kDouyinCookie,
    pageBuilder: DouyinCookiePage.new,
    binding: DouyinCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb yyCookie = SettingsCrumb(
    labelKey: 'site_yy',
    routeName: RoutePath.kYyCookie,
    pageBuilder: YyCookiePage.new,
    binding: YyCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb taobaoCookie = SettingsCrumb(
    labelKey: 'site_taobaolive',
    routeName: RoutePath.kTaobaoCookie,
    pageBuilder: TaobaoCookiePage.new,
    binding: TaobaoCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb kuaishouCookie = SettingsCrumb(
    labelKey: 'site_kuaishou',
    routeName: RoutePath.kKuaishouCookie,
    pageBuilder: KuaishouCookiePage.new,
    binding: KuaishouCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb twitchCookie = SettingsCrumb(
    labelKey: 'site_twitch',
    routeName: RoutePath.kTwitchCookie,
    pageBuilder: TwitchCookiePage.new,
    binding: TwitchCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb soopCookie = SettingsCrumb(
    labelKey: 'site_soop',
    routeName: RoutePath.kSoop,
    pageBuilder: SoopCookiePage.new,
    binding: SoopCookieBinding(),
    parents: [root, platform, account],
  );
  static final SettingsCrumb cookieCapture = SettingsCrumb(
    labelKey: 'cookie_capture_title',
    routeName: '/settings/platform/account/cookieCapture',
    parents: [root, platform, account],
  );
  static final SettingsCrumb tags = SettingsCrumb(
    labelKey: 'tag_management',
    routeName: '/settings/platform/tags',
    pageBuilder: TagManagementPage.new,
    binding: TagManagementBinding(),
    parents: [root, platform],
  );

  // —— 设置 > 视频 ——
  static final SettingsCrumb video = SettingsCrumb(
    labelKey: 'video_settings',
    routeName: '/settings/video',
    pageBuilder: VideoSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb audienceMetric = SettingsCrumb(
    labelKey: 'audience_metric_settings',
    routeName: '/settings/video/audienceMetric',
    pageBuilder: AudienceMetricSettingsPage.new,
    parents: [root, video],
  );
  static final SettingsCrumb pipDanmaku = SettingsCrumb(
    labelKey: 'pip_danmaku',
    routeName: '/settings/video/pipDanmaku',
    pageBuilder: PipDanmakuSettingsPage.new,
    parents: [root, video],
  );
  static final SettingsCrumb danmakuFontFamily = SettingsCrumb(
    labelKey: 'change_danmaku_font_family',
    routeName: '/settings/video/danmakuFontFamily',
    pageBuilder: () => const FontFamilyManagerPage(isDanmakuSettings: true),
    parents: [root, video],
  );
  static final SettingsCrumb danmakuShield = SettingsCrumb(
    labelKey: 'danmaku_keyword_block',
    routeName: '/settings/video/danmakuShield',
    pageBuilder: DanmuShieldPage.new,
    binding: DanmuShieldBinding(),
    parents: [root, video],
  );

  // —— 设置 > IPTV ——
  static final SettingsCrumb iptv = SettingsCrumb(
    labelKey: 'iptv_settings',
    routeName: '/settings/iptv',
    pageBuilder: IptvPage.new,
    parents: [root],
  );
  static final SettingsCrumb iptvManage = SettingsCrumb(
    labelKey: 'manage_page_title',
    routeName: '/settings/iptv/manage',
    pageBuilder: IptvManagePage.new,
    parents: [root, iptv],
  );

  // —— 设置 > 播放器内核 ——
  static final SettingsCrumb kernel = SettingsCrumb(
    labelKey: 'player_kernel_settings',
    routeName: '/settings/kernel',
    pageBuilder: PlayerKernelSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb decoder = SettingsCrumb(
    labelKey: 'hardware_decoder',
    routeName: '/settings/kernel/decoder',
    pageBuilder: DecoderSettingsPage.new,
    parents: [root, kernel],
  );
  static final SettingsCrumb renderer = SettingsCrumb(
    labelKey: 'video_output_driver',
    routeName: '/settings/kernel/renderer',
    pageBuilder: RendererSettingsPage.new,
    parents: [root, kernel],
  );
  static final SettingsCrumb audioOutput = SettingsCrumb(
    labelKey: 'audio_output_driver',
    routeName: '/settings/kernel/audioOutput',
    pageBuilder: AudioOutputSettingsPage.new,
    parents: [root, kernel],
  );

  // —— 设置 > 网络代理 / 本地互动 / 缓存与数据 ——
  static final SettingsCrumb proxy = SettingsCrumb(
    labelKey: 'network_proxy_settings',
    routeName: '/settings/proxy',
    pageBuilder: NetworkProxySettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb localInteraction = SettingsCrumb(
    labelKey: 'local_interaction_settings',
    routeName: '/settings/localInteraction',
    pageBuilder: LocalInteractionSettingsPage.new,
    parents: [root],
  );
  static final SettingsCrumb cache = SettingsCrumb(
    labelKey: 'cache_and_data',
    routeName: '/settings/cache',
    pageBuilder: CacheDataSettingsPage.new,
    parents: [root],
  );

  // —— 设置 > 备份与恢复 ——
  static final SettingsCrumb backup = SettingsCrumb(
    labelKey: 'backup_recover',
    routeName: '/settings/backup',
    pageBuilder: BackupPage.new,
    parents: [root],
  );
  static final SettingsCrumb remoteSync = SettingsCrumb(
    labelKey: 'remote_sync',
    routeName: '/settings/backup/remoteSync',
    pageBuilder: RemoteSyncPage.new,
    binding: RemoteSyncBinding(),
    parents: [root, backup],
  );
  static final SettingsCrumb remoteSyncPreview = SettingsCrumb(
    labelText: '配置预览 / 选择性同步',
    routeName: '/settings/backup/remoteSync/preview',
    parents: [root, backup, remoteSync],
  );
  static final SettingsCrumb remoteSyncScanner = SettingsCrumb(
    labelKey: 'remote_sync_scan_qr',
    routeName: '/settings/backup/remoteSync/scanner',
    pageBuilder: RemoteSyncScannerPage.new,
    parents: [root, backup, remoteSync],
  );
  static final SettingsCrumb webdav = SettingsCrumb(
    labelKey: 'webdav',
    routeName: '/settings/backup/webdav',
    pageBuilder: WebDavPage.new,
    binding: WebDavBinding(),
    parents: [root, backup],
  );
  static final SettingsCrumb webdavHelp = SettingsCrumb(
    labelKey: 'webdav_help_title',
    routeName: '/settings/backup/webdav/help',
    pageBuilder: WebDavHelpPage.new,
    parents: [root, backup, webdav],
  );
}

/// 设置页面的面包屑顶部栏。
class SettingsBreadcrumbAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// 当前页对应的目录节点
  final SettingsCrumb node;

  /// 右上角操作区
  final List<Widget>? actions;

  /// 自定义 AppBar 高度
  final double? toolbarHeight;

  /// 静止状态下的阴影高度（null 跟随 AppBar 默认）
  final double? elevation;

  /// 滚动时是否移除阴影高度（null 跟随 AppBar 默认）
  final double? scrolledUnderElevation;

  const SettingsBreadcrumbAppBar({
    super.key,
    required this.node,
    this.actions,
    this.toolbarHeight,
    this.elevation,
    this.scrolledUnderElevation,
  });

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight ?? kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: toolbarHeight,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      title: SettingsBreadcrumbBar(node: node),
      actions: actions,
    );
  }
}

/// 面包屑内容，可嵌入普通 AppBar / SliverAppBar 的 title。
class SettingsBreadcrumbBar extends StatelessWidget {
  final SettingsCrumb node;

  const SettingsBreadcrumbBar({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    final path = node.path;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // 当前页（末尾项）始终可见，更早的层级向左折叠。
      reverse: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < path.length; i++) ...<Widget>[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Icon(Remix.arrow_right_s_line, size: 15, color: Theme.of(context).hintColor),
              ),
            _SettingsCrumbItem(crumb: path[i], isCurrent: i == path.length - 1),
          ],
        ],
      ),
    );
  }
}

class _SettingsCrumbItem extends StatefulWidget {
  final SettingsCrumb crumb;
  final bool isCurrent;

  const _SettingsCrumbItem({required this.crumb, required this.isCurrent});

  @override
  State<_SettingsCrumbItem> createState() => _SettingsCrumbItemState();
}

class _SettingsCrumbItemState extends State<_SettingsCrumbItem> {
  bool _hovering = false;

  void _handleTap() {
    if (widget.isCurrent) {
      SettingsNavigator.reload(widget.crumb);
    } else {
      SettingsNavigator.backTo(widget.crumb);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultColor = widget.isCurrent ? theme.colorScheme.onSurface : theme.colorScheme.outline;
    final color = _hovering ? theme.colorScheme.primary : defaultColor;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: _handleTap,
      onHover: (value) => setState(() => _hovering = value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          widget.crumb.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: color,
            fontWeight: widget.isCurrent ? FontWeight.w700 : FontWeight.w500,
            fontSize: widget.isCurrent ? 15 : 14,
          ),
        ),
      ),
    );
  }
}
