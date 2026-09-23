import 'dart:collection';

import 'package:flame_barrage/flame_barrage.dart';

class RichParser {
  RichParser({required this.atlas, int maxCacheSize = 1000}) : _maxCacheSize = maxCacheSize.clamp(1, 10000).toInt();

  final EmojiAtlas atlas;
  final LinkedHashMap<String, List<Fragment>> _cache = LinkedHashMap<String, List<Fragment>>();
  int _maxCacheSize;

  int get cacheCount => _cache.length;

  bool containsCache(String content) {
    return _cache.containsKey(content);
  }

  void clearCache() {
    _cache.clear();
  }

  void updateMaxCacheSize(int value) {
    _maxCacheSize = value.clamp(1, 10000).toInt();
    while (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  void removeCache(String content) {
    _cache.remove(content);
  }

  List<Fragment> parse(String content) {
    if (content.isEmpty) {
      return const [];
    }

    final cached = _cache[content];
    if (cached != null) {
      _cache.remove(content);
      _cache[content] = cached;
      return List<Fragment>.from(cached);
    }

    final fragments = _parseInternal(content);

    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }

    _cache[content] = fragments;

    return List<Fragment>.from(fragments);
  }

  List<Fragment> _parseInternal(String content) {
    final regex = atlas.regex;

    if (regex == null || !regex.hasMatch(content)) {
      return _splitPseudoEmoji(content);
    }

    final result = <Fragment>[];
    int lastIndex = 0;

    for (final match in regex.allMatches(content)) {
      if (match.start > lastIndex) {
        result.addAll(_splitPseudoEmoji(content.substring(lastIndex, match.start)));
      }

      final key = match.group(0);
      if (key != null) {
        final emojiInfo = atlas.find(key);
        if (emojiInfo != null) {
          if (emojiInfo.sourceType == EmojiSourceType.atlas) {
            result.add(SpriteFragment(key));
          } else {
            result.add(EmojiFragment(emojiInfo));
          }
        } else {
          result.add(TextFragment(key));
        }
      }

      lastIndex = match.end;
    }

    if (lastIndex < content.length) {
      result.addAll(_splitPseudoEmoji(content.substring(lastIndex)));
    }

    return result;
  }

  /// Splits [text] into alternating [TextFragment]s so that codepoints covered
  /// by Segoe UI Emoji (arrows, geometric shapes, dingbats, misc symbols, …)
  /// are isolated into their own fragments with `fontFamilyOverride` set to
  /// `'Segoe UI Emoji'`. This prevents third-party CJK fonts from hijacking
  /// these codepoints with monochrome vector glyphs.
  ///
  /// Returns `[TextFragment(text)]` when the text contains no pseudo-emoji.
  List<Fragment> _splitPseudoEmoji(String text) {
    if (text.isEmpty) return const [];

    final runes = text.runes;
    final result = <Fragment>[];
    final buf = StringBuffer();
    bool inEmoji = false;

    void flush(bool emojiMode) {
      if (buf.isEmpty) return;
      if (emojiMode) {
        result.add(TextFragment(buf.toString(), fontFamilyOverride: 'Segoe UI Emoji'));
      } else {
        result.add(TextFragment(buf.toString()));
      }
      buf.clear();
    }

    for (final cp in runes) {
      final matches = isSegoeEmojiCodepoint(cp);
      if (matches != inEmoji) {
        flush(inEmoji);
        inEmoji = matches;
      }
      buf.writeCharCode(cp);
    }
    flush(inEmoji);

    return result;
  }

  void warmUp(Iterable<String> contents) {
    for (final content in contents) {
      parse(content);
    }
  }

  Map<String, dynamic> debugInfo() {
    return {'cacheCount': _cache.length};
  }
}
