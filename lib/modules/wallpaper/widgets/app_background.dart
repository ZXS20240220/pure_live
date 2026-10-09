import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_video_player.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<WallpaperSettingsController>();

    return Obx(() {
      if (!controller.hasWallpaper) {
        return const SizedBox.shrink();
      }

      final type = controller.wallpaperType;
      final source = controller.wallpaperSource.v;

      Widget background;
      switch (type) {
        case WallpaperType.imageLocal:
          background = _buildImageBackground(FileImage(File(source)));
          break;
        case WallpaperType.imageOnline:
        case WallpaperType.imagePreset:
          background = CachedNetworkImage(
            imageUrl: source,
            fit: controller.resolvedFit,
            width: double.infinity,
            height: double.infinity,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          );
          break;
        case WallpaperType.videoLocal:
        case WallpaperType.videoOnline:
          background = WallpaperVideoPlayer(
            source: source,
            isLocal: type == WallpaperType.videoLocal,
            fit: controller.resolvedFit,
          );
          break;
        case WallpaperType.none:
          return const SizedBox.shrink();
      }

      final blur = controller.blurRadius.v;
      final maskAlpha = controller.maskOpacity.v;

      // 模糊半径为 0 时不使用 BackdropFilter，避免其创建的 save layer 在 Windows 上
      // 干扰命中测试（导致按钮不可点击）和原生对话框定位（导致文件选择窗口闪烁）。
      // 此时仅用一个带透明度的纯色 Container 实现遮罩效果。
      final overlay = blur > 0
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: Container(color: Colors.black.withValues(alpha: maskAlpha)),
            )
          : ColoredBox(color: Colors.black.withValues(alpha: maskAlpha));

      return IgnorePointer(
        child: RepaintBoundary(
          child: Stack(
            children: [
              Positioned.fill(child: background),
              Positioned.fill(child: overlay),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildImageBackground(ImageProvider provider) {
    final controller = Get.find<WallpaperSettingsController>();
    return Image(
      image: provider,
      fit: controller.resolvedFit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}
