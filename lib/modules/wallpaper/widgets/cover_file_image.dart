import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 按 BoxFit.cover 语义解码本地图片的自定义 [ImageProvider]。
///
/// `Image.file(cacheWidth:)` 只能约束单边，图片纵横比与视口不一致时，
/// cover 缩放后仍会产生放大模糊或浪费内存。本 Provider 利用解码回调
/// 先拿到图片原始尺寸，再一次性按 cover 公式计算目标解码尺寸：
/// - 保持纵横比（只约束长边方向，不拉伸）；
/// - 不放大超过原图（图比视口小时按原尺寸解码）；
/// - 解码结果恰好铺满视口，内存与清晰度同时最优。
///
/// 视口尺寸变化时构造新的 Provider（相等性包含 targetWidth/Height），
/// 配合 `Image(gaplessPlayback: true)` 即可在窗口缩放后平滑重解码。
class CoverFileImage extends ImageProvider<CoverFileImage> {
  const CoverFileImage(this.file, {required this.targetWidth, required this.targetHeight, this.scale = 1.0})
    : assert(targetWidth > 0 && targetHeight > 0);

  final File file;

  /// 视口物理像素宽高，作为解码目标依据。
  final int targetWidth;
  final int targetHeight;

  final double scale;

  @override
  Future<CoverFileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CoverFileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(CoverFileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.file.path,
      informationCollector: () => <DiagnosticsNode>[ErrorDescription('Path: ${key.file.path}')],
    );
  }

  Future<ui.Codec> _loadAsync(CoverFileImage key, ImageDecoderCallback decode) async {
    final bytes = await key.file.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        // cover 所需缩放 = max(视口宽/图宽, 视口高/图高)
        final coverScale = math.max(key.targetWidth / intrinsicWidth, key.targetHeight / intrinsicHeight);
        if (coverScale >= 1) {
          // 图片本身不小于视口所需：按原尺寸解码，不凭空放大
          return ui.TargetImageSize(width: intrinsicWidth, height: intrinsicHeight);
        }
        return ui.TargetImageSize(
          width: (intrinsicWidth * coverScale).round().clamp(1, intrinsicWidth),
          height: (intrinsicHeight * coverScale).round().clamp(1, intrinsicHeight),
        );
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! CoverFileImage) return false;
    if (identical(other, this)) return true;
    return file.path == other.file.path &&
        targetWidth == other.targetWidth &&
        targetHeight == other.targetHeight &&
        scale == other.scale;
  }

  @override
  int get hashCode => Object.hash(file.path, targetWidth, targetHeight, scale);

  @override
  String toString() => 'CoverFileImage(${file.path}, ${targetWidth}x$targetHeight)';
}
