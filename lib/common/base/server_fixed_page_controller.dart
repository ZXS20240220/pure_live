import 'dart:async';

import 'package:pure_live/common/index.dart';

abstract class ServerFixedPageController<T> extends BasePageScrollAndStateBone<T> {
  /// Nominal size of one server-side page. The controller still accumulates
  /// every returned item into a flat buffer so a mismatch between this value
  /// and the platform's real page size cannot silently truncate the catalogue.
  final int fixedServerPageSize;

  /// Flat buffer of every unique item fetched from the server, in fetch order.
  final List<T> _allItems = [];
  final Set<T> _seenItems = {};
  int _nextServerPage = 1;
  bool _hasMoreNetwork = true;
  Future<void>? _activeLoad;
  bool _refreshPending = false;
  int? _pendingPageSize;

  ServerFixedPageController({required this.fixedServerPageSize}) : super();

  Future<List<T>> fetchFixedNetworkData(int bigPage, int fixedSize);

  @override
  Future<void>? get activePageOperation => _activeLoad;

  @override
  Future<void> refreshData() async {
    if (isClosed) return;
    _refreshPending = true;
    while (_activeLoad != null && !isClosed) {
      await _activeLoad;
    }
    if (!_refreshPending || isClosed) return;
    _refreshPending = false;
    _allItems.clear();
    _seenItems.clear();
    _nextServerPage = 1;
    _hasMoreNetwork = true;
    currentPage = 1;
    await _startLoad(replaceMobileSnapshot: true);
  }

  @override
  Future<void> goToPage(int page) async {
    if (isClosed || _activeLoad != null || page < 1) return;
    if (!usesDesktopPagination) return;
    final int targetStart = (page - 1) * pageSize.value;
    // Reject navigation past the committed catalogue only when the server has
    // signalled end-of-stream.
    if (targetStart >= _allItems.length && !_hasMoreNetwork) return;
    currentPage = page;
    await loadData();
  }

  @override
  void setPageSize(int? newSize, {bool persist = true, bool preservePage = false}) {
    if (isClosed || newSize == null || newSize < 1) return;
    if (persist) persistUserPageSize(newSize);
    _pendingPageSize = newSize;
    unawaited(_applyPendingPageSize());
  }

  Future<void> _applyPendingPageSize() async {
    while (_activeLoad != null && !isClosed) {
      await _activeLoad;
    }
    if (isClosed) return;
    final newSize = _pendingPageSize;
    _pendingPageSize = null;
    if (newSize == null || pageSize.value == newSize) return;
    if (!usesDesktopPagination) {
      pageSize.value = newSize;
      return;
    }
    final int currentFirstItemIndex = (currentPage - 1) * pageSize.value;
    pageSize.value = newSize;
    currentPage = (currentFirstItemIndex ~/ newSize) + 1;
    await _startLoad();
  }

  @override
  Future<void> loadData() async {
    final active = _activeLoad;
    if (active != null) return active;
    if (isClosed) return;
    return _startLoad();
  }

  @override
  Future<void> loadMoreData() async {
    if (isClosed) return;
    final active = _activeLoad;
    if (active != null) return active;
    await super.loadMoreData();
  }

  Future<void> _startLoad({bool replaceMobileSnapshot = false}) {
    final active = _activeLoad;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _performLoad(replaceMobileSnapshot: replaceMobileSnapshot).whenComplete(() {
      if (identical(_activeLoad, operation)) _activeLoad = null;
    });
    _activeLoad = operation;
    return operation;
  }

  Future<void> _performLoad({required bool replaceMobileSnapshot}) async {
    totalCount.value = null;

    final int targetSize = pageSize.value;
    final int targetStart = usesDesktopPagination ? (currentPage - 1) * targetSize : 0;
    final int targetEnd = currentPage * targetSize;

    // Fast path: the requested slice is already fully buffered.
    if (targetEnd <= _allItems.length || !_hasMoreNetwork) {
      _publishSlice(targetStart, targetEnd, replaceMobileSnapshot);
      return;
    }

    final bool isNetworkSafe = await checkNetworkBeforeRequest();
    if (isClosed) return;
    if (!isNetworkSafe) {
      finishRefreshControllers(IndicatorResult.fail);
      return;
    }

    final int previousPageSnapshot = currentPage;

    try {
      loadding.value = true;
      pageError.value = false;
      pageEmpty.value = false;
      notLogin.value = false;
      if (list.isEmpty) pageLoadding.value = true;

      var requestCount = 0;
      var noProgressCount = 0;
      while (_allItems.length < targetEnd && _hasMoreNetwork && requestCount < 20 && noProgressCount < 2) {
        late final List<T> bigPageData;
        try {
          bigPageData = await fetchFixedNetworkData(_nextServerPage, fixedServerPageSize);
          if (isClosed) return;
        } catch (e) {
          if (isClosed) return;
          // Keep an already assembled partial catalogue when only a later
          // server page fails. The first request failure still follows the
          // normal error path.
          if (_allItems.isEmpty) rethrow;
          handleError(e, showPageError: false);
          break;
        }
        requestCount++;

        if (bigPageData.isEmpty) {
          _hasMoreNetwork = false;
          break;
        }

        final previousLength = _allItems.length;
        for (final item in bigPageData) {
          if (_seenItems.add(item)) _allItems.add(item);
        }
        noProgressCount = _allItems.length == previousLength ? noProgressCount + 1 : 0;
        _nextServerPage++;
        // 短页（少于服务端固定页大小）即末页：再请求只会命中越界页；部分
        // 平台对越界页既不返回空也不结束时，刷新事务会永久挂起
        // （transactional_page_refresh 的短页刷新用例即此场景）。
        if (bigPageData.length < fixedServerPageSize) {
          _hasMoreNetwork = false;
        }
      }

      _publishSlice(targetStart, targetEnd, replaceMobileSnapshot);
    } catch (e) {
      if (isClosed) return;
      currentPage = previousPageSnapshot;
      handleError(e, showPageError: list.isEmpty);
      finishRefreshControllers(IndicatorResult.fail);
    } finally {
      if (!isClosed) {
        loadding.value = false;
        pageLoadding.value = false;
      }
    }
  }

  /// Commits the visible slice from [_allItems] and updates paging metadata.
  /// Snaps back to the last valid page when the requested range falls past the
  /// end of the catalogue, so a phantom trailing page never renders empty.
  void _publishSlice(int start, int end, bool replaceMobileSnapshot) {
    int effectiveStart = start;
    int effectiveEnd = end;

    if (effectiveStart >= _allItems.length) {
      if (_allItems.isNotEmpty) {
        final int lastPage = (_allItems.length / pageSize.value).ceil();
        currentPage = lastPage;
        effectiveStart = (lastPage - 1) * pageSize.value;
        effectiveEnd = lastPage * pageSize.value;
      } else {
        list.clear();
        canLoadMore.value = false;
        pageEmpty.value = true;
        if (!_hasMoreNetwork) totalCount.value = 0;
        finishRefreshControllers(IndicatorResult.noMore);
        return;
      }
    }

    effectiveEnd = effectiveEnd.clamp(effectiveStart, _allItems.length);
    final slice = _allItems.sublist(effectiveStart, effectiveEnd);

    if (usesDesktopPagination) {
      list.assignAll(slice);
    } else {
      list.assignAll(_allItems.sublist(0, effectiveEnd));
    }

    canLoadMore.value = effectiveEnd < _allItems.length || _hasMoreNetwork;
    if (!_hasMoreNetwork) totalCount.value = _allItems.length;
    pageEmpty.value = list.isEmpty;
    finishRefreshControllers(canLoadMore.value ? IndicatorResult.success : IndicatorResult.noMore);
    if (usesDesktopPagination) scrollToTopImmediate();
  }
}
