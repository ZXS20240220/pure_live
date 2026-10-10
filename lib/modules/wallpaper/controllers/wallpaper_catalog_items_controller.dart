import 'dart:async';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_repository.dart';

/// 壁纸库网格分页控制器
///
/// 支持本地图源和远程图源：
/// - 本地图源（deepin、纯色渐变）：数据编译在应用内，直接返回全部
/// - 远程图源（官方、Wallhaven、必应）：一次拉取较大批量，本地切片分页
class WallpaperCatalogItemsController extends ServerAllPageController<CatalogWallpaperItem> {
  WallpaperCatalogItemsController({required this.sourceId, required this.groupId});

  final String sourceId;
  final String groupId;

  Timer? _viewportPageDebounce;

  void applyViewportPageSize(int capacity) {
    if (isClosed) return;
    final target = capacity < 10 ? 10 : capacity;
    if (pageSize.value == target) return;
    _viewportPageDebounce?.cancel();
    _viewportPageDebounce = Timer(const Duration(milliseconds: 150), () {
      if (isClosed) return;
      setPageSize(target);
    });
  }

  @override
  void onClose() {
    _viewportPageDebounce?.cancel();
    super.onClose();
  }

  @override
  Future<List<CatalogWallpaperItem>> fetchAllServerData() async {
    final repo = WallpaperRepository.instance;
    final source = repo.loadCatalog().sourceById(sourceId);
    if (source == null) return const <CatalogWallpaperItem>[];

    if (repo.isLocalSource(source.id)) {
      return repo.localItems(source.id);
    }

    final group = _pickGroup(source, groupId);
    if (group == null) return const <CatalogWallpaperItem>[];

    return repo.fetchPage(source: source, group: group, page: 1, size: 1000);
  }

  static CatalogWallpaperGroup? _pickGroup(CatalogWallpaperSource source, String? wanted) {
    final groups = source.visibleGroups;
    if (groups.isEmpty) return null;
    if (wanted == null) return groups.first;
    for (final group in groups) {
      if (group.id == wanted) return group;
    }
    return groups.first;
  }
}
