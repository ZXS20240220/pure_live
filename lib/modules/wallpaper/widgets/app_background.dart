import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';

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
          // 视频壁纸在阶段 2 实现，先占位
          background = const ColoredBox(color: Colors.transparent);
          break;
        case WallpaperType.none:
          return const SizedBox.shrink();
      }

      return IgnorePointer(
        child: Stack(
          children: [
            Positioned.fill(child: background),
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: controller.blurRadius.v, sigmaY: controller.blurRadius.v),
                child: Container(color: Colors.black.withValues(alpha: controller.maskOpacity.v)),
              ),
            ),
          ],
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
