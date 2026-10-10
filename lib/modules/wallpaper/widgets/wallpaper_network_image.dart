import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 壁纸网络图片，支持缩略图失败后回退到原图
class WallpaperNetworkImage extends StatefulWidget {
  const WallpaperNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.placeholder,
    this.fallback,
  });

  final String url;
  final String? fallbackUrl;
  final BoxFit fit;
  final int? memCacheWidth;
  final Widget? placeholder;
  final Widget? fallback;

  @override
  State<WallpaperNetworkImage> createState() => _WallpaperNetworkImageState();
}

class _WallpaperNetworkImageState extends State<WallpaperNetworkImage> {
  int _attempt = 0;
  bool _dead = false;

  List<String> get _candidates => <String>[
    if (widget.url.isNotEmpty) widget.url,
    if ((widget.fallbackUrl ?? '').isNotEmpty && widget.fallbackUrl != widget.url) widget.fallbackUrl!,
  ];

  @override
  void didUpdateWidget(covariant WallpaperNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.fallbackUrl != widget.fallbackUrl) {
      _attempt = 0;
      _dead = false;
    }
  }

  void _next() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final int next = _attempt + 1;
      if (next >= _candidates.length) {
        if (!_dead) setState(() => _dead = true);
        return;
      }
      setState(() => _attempt = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dead) return widget.fallback ?? const SizedBox.shrink();

    final List<String> candidates = _candidates;
    if (candidates.isEmpty) return widget.fallback ?? const SizedBox.shrink();

    final String url = candidates[_attempt.clamp(0, candidates.length - 1)];
    return CachedNetworkImage(
      imageUrl: url,
      fit: widget.fit,
      memCacheWidth: widget.memCacheWidth,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, _) => widget.placeholder ?? const SizedBox.shrink(),
      errorWidget: (context, _, _) {
        _next();
        return widget.placeholder ?? const SizedBox.shrink();
      },
    );
  }
}
