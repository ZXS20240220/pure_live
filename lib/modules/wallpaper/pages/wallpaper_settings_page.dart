import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';

class WallpaperSettingsPage extends StatelessWidget {
  const WallpaperSettingsPage({super.key});

  static const List<String> _fitLabels = ['等比覆盖', '完整包含', '拉伸填充', '适配宽度', '适配高度', '原始大小', '等比缩小'];

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<WallpaperSettingsController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SettingsBreadcrumbAppBar(node: SettingsCrumbs.wallpaper),
      body: ListView(
        physics: const PureLiveScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // ===== 显示设置 =====
          context.buildGroupTitle('显示设置'),
          context.buildModernCard([
            // 填充模式：水平按钮组
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('填充模式', style: AppTextStyles.t14.copyWith(color: theme.hintColor)),
                  const SizedBox(height: 10),
                  Obx(() {
                    final selected = controller.fitIndex.v;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(_fitLabels.length, (index) {
                        final isSelected = selected == index;
                        return ChoiceChip(
                          label: Text(_fitLabels[index]),
                          selected: isSelected,
                          onSelected: (_) => controller.updateFit(index),
                          showCheckmark: isSelected,
                          checkmarkColor: theme.colorScheme.onPrimary,
                          selectedColor: theme.colorScheme.primary,
                          labelStyle: TextStyle(
                            color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        );
                      }),
                    );
                  }),
                ],
              ),
            ),
            // 遮罩强度
            Obx(
              () => context.buildSliderTile(
                context,
                icon: Remix.contrast_drop_line,
                title: '遮罩强度',
                value: controller.maskOpacity.v,
                min: 0.0,
                max: 1.0,
                displayValue: '${(controller.maskOpacity.v * 100).toInt()}%',
                onChanged: (v) => controller.updateMaskOpacity(v),
              ),
            ),
            // 高斯模糊
            Obx(
              () => context.buildSliderTile(
                context,
                icon: Remix.blur_off_line,
                title: '高斯模糊',
                value: controller.blurRadius.v,
                min: 0.0,
                max: 50.0,
                displayValue: controller.blurRadius.v <= 0 ? '关闭' : controller.blurRadius.v.toStringAsFixed(1),
                onChanged: (v) => controller.updateBlurRadius(v),
              ),
            ),
            // 视频壁纸专属设置
            Obx(() {
              if (!controller.isVideo) return const SizedBox.shrink();
              return Column(
                children: [
                  context.buildSliderTile(
                    context,
                    icon: Remix.volume_up_line,
                    title: '视频音量',
                    value: controller.videoVolume.v,
                    min: 0.0,
                    max: 1.0,
                    displayValue: '${(controller.videoVolume.v * 100).toInt()}%',
                    onChanged: (v) => controller.updateVideoVolume(v),
                  ),
                  context.buildSwitchTile(
                    icon: Remix.pause_circle_line,
                    title: '直播时暂停',
                    subtitle: '播放直播时自动暂停壁纸视频',
                    value: controller.pauseVideoWhenLivePlaying,
                  ),
                ],
              );
            }),
            // 清除背景
            context.buildTile(
              icon: Icons.close_rounded,
              title: '清除背景',
              subtitle: '恢复使用主题底色',
              onTap: () => controller.clearWallpaper(),
            ),
          ]),

          const SizedBox(height: 20),

          // ===== 背景来源 =====
          context.buildGroupTitle('背景来源'),
          context.buildModernCard([
            context.buildTile(icon: Remix.palette_line, title: '纯色', subtitle: '纯色与渐变填充', onTap: null),
            context.buildTile(icon: Remix.film_line, title: '视频壁纸', subtitle: '动态视频背景', onTap: null),
            context.buildTile(icon: Remix.image_2_line, title: '壁纸库', subtitle: '官方、Wallhaven、必应等图库', onTap: null),
            context.buildTile(icon: Remix.shuffle_line, title: '随机图源', subtitle: '每次打开随机取一张图', onTap: null),
          ]),

          const SizedBox(height: 20),

          // ===== 本机与网络 =====
          context.buildGroupTitle('本机与网络'),
          context.buildModernCard([
            context.buildTile(
              icon: Remix.image_add_line,
              title: '选择本地图片',
              subtitle: '从相册或文件中选一张图',
              onTap: () => controller.pickLocalImage(),
            ),
            context.buildTile(
              icon: Remix.video_add_line,
              title: '选择本地视频',
              subtitle: '静音循环播放，直播播放时自动让位',
              onTap: () => controller.pickLocalVideo(),
            ),
          ]),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
