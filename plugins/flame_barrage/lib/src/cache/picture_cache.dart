import 'dart:ui' as ui;
import 'dart:collection';

/// Bookkeeping for one cached [ui.Picture].
///
/// A picture can be referenced simultaneously by the LRU cache and by
/// on-screen barrage entries. It must only be disposed once **all** parties
/// have released it.
class _CachedPicture {
  _CachedPicture(this.key, this.picture);

  final String key;
  final ui.Picture picture;

  /// Number of on-screen entries currently holding this picture.
  int refs = 0;

  /// Whether the picture still participates in the LRU cache and can be
  /// returned by [PictureCache.acquire]. Evicted entries keep their object
  /// alive until [refs] drops to zero.
  bool inLru = true;
}

/// LRU cache of pre-rendered barrage pictures.
///
/// Ownership model:
/// * [acquire] / [putAndAcquire] hand out a picture and increment its ref
///   count. The caller (one barrage entry) must balance each hand-out with
///   exactly one [release].
/// * LRU eviction detaches the entry from the cache instead of disposing it
///   blindly. Pictures still referenced by visible entries survive until the
///   last [release], so the rasterizer never receives a disposed picture
///   ("Canvas.drawPicture called with non-genuine Picture").
class PictureCache {
  PictureCache({required this.maxSize});

  int maxSize;

  /// LRU order (first = oldest, last = most recently used) of pictures still
  /// eligible for cache hits.
  final LinkedHashMap<String, _CachedPicture> _lru = LinkedHashMap<String, _CachedPicture>();

  /// Identity index of every tracked picture, including pictures already
  /// evicted from [_lru] but still referenced by on-screen entries.
  final Map<ui.Picture, _CachedPicture> _index = Map<ui.Picture, _CachedPicture>.identity();

  /// Number of pictures currently eligible for cache hits.
  int get size => _lru.length;

  /// Returns the cached picture for [key] (moving it to the MRU position) and
  /// increments its reference count. Returns `null` on a cache miss.
  ui.Picture? acquire(String key) {
    final cached = _lru.remove(key);
    if (cached == null) return null;
    _lru[key] = cached;
    cached.refs++;
    return cached.picture;
  }

  /// Inserts [picture] into the cache and hands it out with one reference
  /// already held by the caller. Must only be called after an [acquire] miss
  /// for [key].
  ui.Picture putAndAcquire(String key, ui.Picture picture) {
    // Defensive: a concurrent insert for the same key keeps the cached object
    // and discards the duplicate.
    final existing = _lru.remove(key);
    if (existing != null) {
      picture.dispose();
      _lru[key] = existing;
      existing.refs++;
      return existing.picture;
    }

    if (_lru.length >= maxSize) {
      _evictOldest();
    }

    final cached = _CachedPicture(key, picture)..refs = 1;
    _lru[key] = cached;
    _index[picture] = cached;
    return picture;
  }

  void _evictOldest() {
    if (_lru.isEmpty) return;
    final oldestKey = _lru.keys.first;
    final oldest = _lru.remove(oldestKey)!;
    _detachAndMaybeDispose(oldest);
  }

  /// Removes [cached] from LRU eligibility and disposes it immediately when no
  /// on-screen entry references it anymore. Otherwise it lingers in [_index]
  /// until the balancing [release].
  void _detachAndMaybeDispose(_CachedPicture cached) {
    cached.inLru = false;
    if (cached.refs <= 0) {
      _index.remove(cached.picture);
      cached.picture.dispose();
    }
  }

  /// Releases one reference previously handed out by [acquire] or
  /// [putAndAcquire]. When the last reference to an already-evicted picture
  /// is released, its GPU resources are disposed.
  void release(ui.Picture picture) {
    final cached = _index[picture];
    if (cached == null) return;
    if (cached.refs > 0) {
      cached.refs--;
    }
    if (cached.refs <= 0 && !cached.inLru) {
      _index.remove(picture);
      cached.picture.dispose();
    }
  }

  void updateMaxSize(int newMaxSize) {
    if (newMaxSize <= 0) return;
    maxSize = newMaxSize;
    while (_lru.length > maxSize) {
      _evictOldest();
    }
  }

  /// Drops the whole LRU. Pictures still referenced by on-screen entries are
  /// kept alive in the identity index and are disposed through their balancing
  /// [release] calls.
  void clear() {
    if (_lru.isEmpty) return;
    final entries = _lru.values.toList(growable: false);
    _lru.clear();
    for (final cached in entries) {
      _detachAndMaybeDispose(cached);
    }
  }
}
