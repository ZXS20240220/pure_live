import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/base/base_controller.dart';
import 'package:pure_live/common/global/platform_utils.dart';

abstract class BasePageScrollAndStateBone<T> extends BaseController {
  final ScrollController _ownedScrollController = createPureLiveScrollController();
  ScrollController? _boundScrollController;

  /// Scroll position used by paging buttons and visibility flags.
  ///
  /// A tabbed view can bind one dedicated controller for its active tab. This
  /// keeps every PageView child on a unique ScrollController while preserving
  /// the shared paging actions.
  ScrollController get scrollController => _boundScrollController ?? _ownedScrollController;
  final EasyRefreshController easyRefreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: true,
  );

  int currentPage = 1;
  final pageSize = 20.obs;
  final canLoadMore = false.obs;
  final list = <T>[].obs;
  final totalCount = Rxn<int>();

  final showBackToTop = false.obs;
  final showBackToBottom = true.obs;

  /// Guard set populated while [persistUserPageSize] writes the global default,
  /// so the [defaultPageSize] listener below does not echo the change back into
  /// [setPageSize] on the originating controller. A Set is required (not a
  /// single value) because [ever] fires asynchronously: back-to-back writes
  /// must all be tracked until their respective worker callbacks arrive.
  final Set<int> _pendingPersistedPageSizes = {};

  /// Worker that keeps every live pager in sync with the global default page
  /// size. Disposed in [onClose].
  Worker? _pageSizeSyncWorker;

  bool? _lastIsDesktop;
  bool? _pendingIsDesktop;
  int _layoutVersion = 0;
  Timer? _layoutRefreshTimer;

  BasePageScrollAndStateBone() {
    // Controllers are created from an already mounted route, so Get.width is
    // available here.  Establishing the initial paging mode before the first
    // frame prevents BasePageView from starting a second network refresh from
    // inside build while the controller's initial request is still running.
    final initialIsDesktop = Get.width > 680 && !PlatformUtils.isMobile;
    _lastIsDesktop = initialIsDesktop;
    pageSize.value = initialIsDesktop && Get.isRegistered<SettingsService>()
        ? SettingsService.to.page.defaultPageSize.v
        : 20;
    _ownedScrollController.addListener(_scrollListener);
  }

  @override
  void onInit() {
    super.onInit();
    if (Get.isRegistered<SettingsService>()) {
      _pageSizeSyncWorker = ever(
        SettingsService.to.page.defaultPageSize,
        (int newDefault) => _syncPageSizeFromGlobal(newDefault),
      );
    }
  }

  /// Whether this controller should follow the global [defaultPageSize] when
  /// it changes. Viewport-driven pagers (wallpaper grid, areas list) compute
  /// their page size from the window and must not be overwritten by the
  /// global default; they override this to `false`.
  bool get shouldSyncGlobalPageSize => true;

  void _syncPageSizeFromGlobal(int newDefault) {
    if (isClosed) return;
    if (!shouldSyncGlobalPageSize) return;
    // The change originated from this controller's own [setPageSize] call.
    if (_pendingPersistedPageSizes.remove(newDefault)) return;
    if (pageSize.value == newDefault) return;
    setPageSize(newDefault);
  }

  void bindActiveScrollController(ScrollController? externalController) {
    if (isClosed) return;
    final previous = scrollController;
    if (identical(previous, externalController) ||
        (externalController == null && identical(previous, _ownedScrollController))) {
      return;
    }
    previous.removeListener(_scrollListener);
    _boundScrollController = externalController;
    scrollController.addListener(_scrollListener);
    _syncScrollFlags();
  }

  /// Async pagers expose their current operation so callers (tests, favorite
  /// overrides) can await or inspect the in-flight request.
  Future<void>? get activePageOperation => null;

  void checkAndNotifyLayoutChange(bool isDesktop) {
    if (isClosed || (_pendingIsDesktop ?? _lastIsDesktop) == isDesktop) return;
    final version = ++_layoutVersion;
    _layoutRefreshTimer?.cancel();
    _pendingIsDesktop = isDesktop == _lastIsDesktop ? null : isDesktop;
    if (_pendingIsDesktop == null) return;

    // 跨越 680px 断点只切换分页布局（pageSize/currentPage），绝不重新拉取
    // 数据（对齐开发版：窗口宽度变化不触发刷新）。延迟 120ms 提交是为了
    // 避免在 build 期间修改状态；拖回原断点则整个意图取消。
    _layoutRefreshTimer = Timer(const Duration(milliseconds: 120), () => _commitLayout(version));
  }

  Future<void> _commitLayout(int version) async {
    if (isClosed || version != _layoutVersion) return;
    final isDesktop = _pendingIsDesktop;
    if (isDesktop == null) return;
    _pendingIsDesktop = null;
    final previousSize = pageSize.value;
    _lastIsDesktop = isDesktop;

    if (isDesktop) {
      pageSize.value = SettingsService.to.page.defaultPageSize.v;
      final int currentFirstItemIndex = (currentPage - 1) * previousSize;
      currentPage = (currentFirstItemIndex ~/ pageSize.value) + 1;
    } else {
      pageSize.value = 20;
      currentPage = 1;
    }
    onLayoutChanged();
  }

  /// Hook invoked after a desktop/mobile layout switch commits its new
  /// [pageSize] and [currentPage]. Subclasses that hold a local data pool
  /// override this to re-slice the visible page without hitting the network.
  void onLayoutChanged() {}

  bool get usesDesktopPagination => _lastIsDesktop ?? Get.width > 680 && !PlatformUtils.isMobile;

  void _scrollListener() {
    _syncScrollFlags();
  }

  void _syncScrollFlags() {
    if (!scrollController.hasClients) {
      if (showBackToTop.value) showBackToTop.value = false;
      if (!showBackToBottom.value) showBackToBottom.value = true;
      return;
    }
    final offset = scrollController.offset;
    final position = scrollController.position;
    final maxScroll = position.maxScrollExtent;

    if (offset > 400 && !showBackToTop.value) {
      showBackToTop.value = true;
    } else if (offset <= 400 && showBackToTop.value) {
      showBackToTop.value = false;
    }

    if (position.atEdge && offset > 0) {
      showBackToBottom.value = false;
    } else {
      if (maxScroll - offset > 400) {
        if (!showBackToBottom.value) showBackToBottom.value = true;
      } else {
        if (showBackToBottom.value) showBackToBottom.value = false;
      }
    }
  }

  @override
  void onClose() {
    _layoutVersion++;
    _pendingIsDesktop = null;
    _layoutRefreshTimer?.cancel();
    scrollController.removeListener(_scrollListener);
    _boundScrollController = null;
    _ownedScrollController.dispose();
    easyRefreshController.dispose();
    _pageSizeSyncWorker?.dispose();
    super.onClose();
  }

  void scrollToTopImmediate() {
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  /// 结束下拉刷新/上拉加载指示器。
  ///
  /// 历史上桌面端在此直接返回，因为 [BasePageView] 桌面布局不包裹
  /// [EasyRefresh]。但 [buildCommonPullToRefresh] 在桌面端同样包裹了
  /// 指示器，若不调用 [finishRefresh] 会导致转圈卡死。桌面端没有对应
  /// widget 时调用仅更新 controller 内部状态，无副作用。
  void finishRefreshControllers(IndicatorResult result) {
    easyRefreshController.finishRefresh(
      result == IndicatorResult.fail ? IndicatorResult.fail : IndicatorResult.success,
    );
    easyRefreshController.finishLoad(result);
  }

  void scrollToBottom() {
    if (!scrollController.hasClients) return;
    final distance = (scrollController.position.maxScrollExtent - scrollController.offset).abs();
    scrollController.animateTo(
      scrollController.position.maxScrollExtent,
      duration: _scrollAnimationDuration(distance),
      curve: Curves.easeOutCubic,
    );
  }

  void scrollToTopOrRefresh() {
    if (!scrollController.hasClients) return;
    if (scrollController.offset > 0) {
      scrollController.animateTo(
        0,
        duration: _scrollAnimationDuration(scrollController.offset),
        curve: Curves.easeOutCubic,
      );
    } else {
      if (_lastIsDesktop ?? Get.width > 680 && !PlatformUtils.isMobile) {
        refreshData();
      } else {
        easyRefreshController.callRefresh();
      }
    }
  }

  Duration _scrollAnimationDuration(double distance) {
    return Duration(milliseconds: (180 + distance / 8).round().clamp(220, 520));
  }

  Future<void> loadMoreData() async {
    if (loadding.value) return;
    if (usesDesktopPagination) {
      await goToPage(currentPage + 1);
    } else {
      currentPage++;
      await loadData();
    }
  }

  Future<void> loadData();

  /// 用户手动改每页数量后写回全局默认（hive 持久化）。
  ///
  /// 不写回的话，下次进入页面时构造函数读取的仍是旧默认值（20），
  /// 用户选择的 80 就丢了（同步自上游 e7a794c0）。
  ///
  /// [_pendingPersistedPageSizes] 记录本次写入的值，用于 [_syncPageSizeFromGlobal]
  /// 识别"由本控制器发起的写入"，避免监听回调反向触发 setPageSize 造成递归。
  /// 用 Set 而非单值是因为 [ever] 异步触发，连续写入需要全部追踪。
  void persistUserPageSize(int? size) {
    if (size == null || size < 1) return;
    if (Get.isRegistered<SettingsService>()) {
      _pendingPersistedPageSizes.add(size);
      SettingsService.to.page.defaultPageSize.v = size;
    }
  }

  /// Default retry retains the legacy refresh behavior. Native-cursor pagers
  /// can resume the failed action without restarting already consumed pages.
  Future<void> retryData() => refreshData();
  String get retryActionLabel => i18n('retry');
  bool get showInlineError => false;
  String? get pageNotice => null;
  Future<void> refreshData();
  Future<void> goToPage(int page);

  /// Changes the visible page size.
  ///
  /// When [persist] is `true` (default) the new size is written back to the
  /// global default and propagates to every other live pager. Viewport-driven
  /// pagers pass `persist: false` so their window-computed size never clobbers
  /// the user's chosen default.
  void setPageSize(int? newSize, {bool persist = true});
}
