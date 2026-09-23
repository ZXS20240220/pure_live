import 'fragment.dart';

class TextFragment extends Fragment {
  const TextFragment(this.text, {this.fontFamilyOverride});

  final String text;

  /// When non-null, forces this fragment to be rendered with the given font
  /// family instead of [BarrageConfig.fontFamily]. Used to route pseudo-emoji
  /// codepoints (e.g. U+2611 ☑) to a color-emoji font like Segoe UI Emoji so
  /// that third-party CJK fonts cannot hijack them with monochrome glyphs.
  final String? fontFamilyOverride;
}
