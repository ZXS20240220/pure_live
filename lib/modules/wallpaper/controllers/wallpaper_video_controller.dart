import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/services/itab_wallpaper_client.dart';

/// 动态壁纸分页控制器
///
/// 从 iTab 一次性拉取完整列表，后续由 [ServerAllPageController]
/// 在本地切片分页，不触发额外的网络请求。
class WallpaperVideoController extends ServerAllPageController<VideoWallpaperItem> {
  static WallpaperVideoController get to => Get.find<WallpaperVideoController>();

  Timer? _viewportPageDebounce;

  @override
  bool get shouldSyncGlobalPageSize => false;

  /// 视口动态分页：每页数量 = 窗口可完整容纳的行数 × 每行列数。
  void applyViewportPageSize(int capacity) {
    if (isClosed) return;
    final target = capacity < 10 ? 10 : capacity;
    if (pageSize.value == target) return;
    _viewportPageDebounce?.cancel();
    _viewportPageDebounce = Timer(const Duration(milliseconds: 150), () {
      if (isClosed) return;
      setPageSize(target, persist: false, preservePage: true);
    });
  }

  @override
  void onClose() {
    _viewportPageDebounce?.cancel();
    super.onClose();
  }

  @override
  Future<List<VideoWallpaperItem>> fetchAllServerData() async {
    final sw = Stopwatch()..start();
    final items = await ItabWallpaperClient.instance.fetchVideoList(page: 1, size: 1000);
    // 确保加载至少持续 600ms，避免网络过快时 ClassicHeader 刷新动画一闪而过，
    // 与纯色页等静态数据页的刷新体验保持一致。
    final elapsed = sw.elapsedMilliseconds;
    if (elapsed < 600) {
      await Future<void>.delayed(Duration(milliseconds: 600 - elapsed));
    }
    return items;
  }
}
