import 'dart:async';

import 'package:pure_live/common/index.dart';

abstract class ServerRemotePageController<T> extends BasePageScrollAndStateBone<T> {
  /// Flat buffer of every unique item fetched from the server, in fetch order.
  /// Client pages are sliced from this pool so overflow from a server response
  /// is never discarded (the previous per-client-page cache silently dropped
  /// every item beyond [pageSize] on each network page).
  final List<T> _allItems = [];
  final Set<T> _seenItems = {};
  int _nextNetworkPage = 1;
  bool _hasMoreNetwork = true;
  Future<void>? _activeLoad;
  bool _refreshPending = false;
  int? _pendingPageSize;

  ServerRemotePageController() : super();

  Future<List<T>> fetchNetworkData(int page, int pageSize);

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
    currentPage = 1;
    _nextNetworkPage = 1;
    _allItems.clear();
    _seenItems.clear();
    _hasMoreNetwork = true;
    await _startLoad(replaceMobileSnapshot: true);
  }

  @override
  Future<void> goToPage(int page) async {
    if (isClosed || _activeLoad != null || page < 1) return;
    if (!usesDesktopPagination) return;
    final int targetStart = (page - 1) * pageSize.value;
    // Reject navigation past the committed catalogue only when the server has
    // signalled end-of-stream. While [_hasMoreNetwork] is still true the target
    // page may simply not have been fetched yet.
    if (targetStart >= _allItems.length && !_hasMoreNetwork) return;
    currentPage = page;
    await loadData();
  }

  @override
  void setPageSize(int? newSize) {
    if (isClosed || newSize == null || newSize < 1) return;
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

    final int previousSize = pageSize.value;
    final int currentFirstItemIndex = (currentPage - 1) * previousSize;

    pageSize.value = newSize;
    currentPage = (currentFirstItemIndex ~/ newSize) + 1;

    // The flat buffer is page-size agnostic; re-slicing from it needs no
    // network round-trip unless the new page extends past the cached tail.
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
        final int neededCount = targetEnd - _allItems.length;
        late final List<T> result;
        try {
          result = await fetchNetworkData(_nextNetworkPage, neededCount);
          if (isClosed) return;
        } catch (e) {
          if (isClosed) return;
          // A later cursor/page is allowed to fail without erasing items that
          // the same transaction has already fetched successfully. The partial
          // page is committed below with [_hasMoreNetwork] left untouched only
          // when some data was already buffered.
          if (_allItems.isEmpty) rethrow;
          handleError(e, showPageError: false);
          break;
        }
        requestCount++;
        if (result.isEmpty) {
          _hasMoreNetwork = false;
          break;
        }

        final previousLength = _allItems.length;
        for (final item in result) {
          if (_seenItems.add(item)) _allItems.add(item);
        }
        noProgressCount = _allItems.length == previousLength ? noProgressCount + 1 : 0;
        _nextNetworkPage++;
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
      // Mobile accumulates every committed page; the visible list always runs
      // from the buffer head up to [effectiveEnd].
      list.assignAll(_allItems.sublist(0, effectiveEnd));
    }

    canLoadMore.value = effectiveEnd < _allItems.length || _hasMoreNetwork;
    if (!_hasMoreNetwork) totalCount.value = _allItems.length;
    pageEmpty.value = list.isEmpty;
    finishRefreshControllers(canLoadMore.value ? IndicatorResult.success : IndicatorResult.noMore);
    if (usesDesktopPagination) scrollToTopImmediate();
  }
}
