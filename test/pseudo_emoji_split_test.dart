import 'package:flutter_test/flutter_test.dart';
import 'package:flame_barrage/flame_barrage.dart';

void main() {
  group('isSegoeEmojiCodepoint', () {
    test('matches U+2611 (☑) ballot box with check', () {
      expect(isSegoeEmojiCodepoint(0x2611), isTrue);
    });

    test('matches U+2600 (☀) sun', () {
      expect(isSegoeEmojiCodepoint(0x2600), isTrue);
    });

    test('matches U+2764 (❤) heart', () {
      expect(isSegoeEmojiCodepoint(0x2764), isTrue);
    });

    test('matches U+2190 (←) leftwards arrow', () {
      expect(isSegoeEmojiCodepoint(0x2190), isTrue);
    });

    test('does not match ASCII letters', () {
      expect(isSegoeEmojiCodepoint(0x0041), isFalse); // 'A'
      expect(isSegoeEmojiCodepoint(0x007A), isFalse); // 'z'
    });

    test('does not match CJK ideographs', () {
      expect(isSegoeEmojiCodepoint(0x4E2D), isFalse); // '中'
      expect(isSegoeEmojiCodepoint(0x6587), isFalse); // '文'
    });

    test('does not match basic punctuation', () {
      expect(isSegoeEmojiCodepoint(0x002E), isFalse); // '.'
      expect(isSegoeEmojiCodepoint(0x002C), isFalse); // ','
    });

    test('does not match surrogate-pair emoji (handled by atlas)', () {
      expect(isSegoeEmojiCodepoint(0xD83C), isFalse); // surrogate
    });
  });

  group('RichParser pseudo-emoji splitting', () {
    late RichParser parser;

    setUp(() {
      final atlas = EmojiAtlas.instance;
      atlas.clear();
      addTearDown(atlas.clear);
      parser = RichParser(atlas: atlas);
    });

    test('plain CJK text stays a single TextFragment without override', () {
      final fragments = parser.parse('你好世界');

      expect(fragments.length, 1);
      expect(fragments.first, isA<TextFragment>());
      final tf = fragments.first as TextFragment;
      expect(tf.text, '你好世界');
      expect(tf.fontFamilyOverride, isNull);
    });

    test('lone U+2611 (☑) becomes an overridden TextFragment', () {
      final fragments = parser.parse('☑');

      expect(fragments.length, 1);
      expect(fragments.first, isA<TextFragment>());
      final tf = fragments.first as TextFragment;
      expect(tf.text, '☑');
      expect(tf.fontFamilyOverride, 'Segoe UI Emoji');
    });

    test('mixed CJK + ☑ splits into plain and overridden segments', () {
      final fragments = parser.parse('同意☑继续');

      // Expect at least one plain segment and one emoji segment.
      final texts = fragments.whereType<TextFragment>().map((f) => f.text).toList();
      expect(texts.join(''), '同意☑继续');

      final overridden = fragments.whereType<TextFragment>().where((f) => f.fontFamilyOverride != null);
      expect(overridden, isNotEmpty);
      expect(overridden.every((f) => f.fontFamilyOverride == 'Segoe UI Emoji'), isTrue);
      expect(overridden.any((f) => f.text.contains('☑')), isTrue);
    });

    test('multiple emoji runs produce separate overridden fragments', () {
      final fragments = parser.parse('☑测试☑结束');

      final overridden = fragments.whereType<TextFragment>().where((f) => f.fontFamilyOverride != null).toList();
      expect(overridden.length, greaterThanOrEqualTo(2));
      expect(overridden.every((f) => f.fontFamilyOverride == 'Segoe UI Emoji'), isTrue);
    });

    test('parser cache returns fragments with override intact on second parse', () {
      parser.parse('标记☑');
      final second = parser.parse('标记☑');

      final overridden = second.whereType<TextFragment>().where((f) => f.fontFamilyOverride != null);
      expect(overridden, isNotEmpty);
    });
  });
}
