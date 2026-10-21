import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';

class WallpaperSettingsPage extends StatelessWidget {
  const WallpaperSettingsPage({super.key});

  static List<String> get _fitLabels => [
    i18n('wallpaper_settings_fit_cover'),
    i18n('wallpaper_settings_fit_contain'),
    i18n('wallpaper_settings_fit_fill'),
    i18n('wallpaper_settings_fit_width'),
    i18n('wallpaper_settings_fit_height'),
    i18n('wallpaper_settings_fit_none'),
    i18n('wallpaper_settings_fit_scale_down'),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<WallpaperSettingsController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SettingsBreadcrumbAppBar(node: SettingsCrumbs.wallpaper),
      body: ScrollConfiguration(
        behavior: const MouseDraggableScrollBehavior(),
        child: ListView(
          physics: const PureLiveScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // ===== 显示设置 =====
            context.buildGroupTitle(i18n('wallpaper_settings_display_section')),
            context.buildModernCard([
              // 填充模式：水平按钮组
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i18n('wallpaper_settings_fit_mode'),
                      style: AppTextStyles.t14.copyWith(color: theme.hintColor),
                    ),
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
                  title: i18n('wallpaper_settings_mask_strength'),
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
                  title: i18n('wallpaper_settings_blur'),
                  value: controller.blurRadius.v,
                  min: 0.0,
                  max: 50.0,
                  displayValue: controller.blurRadius.v <= 0
                      ? i18n('close')
                      : controller.blurRadius.v.toStringAsFixed(1),
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
                      title: i18n('wallpaper_settings_video_volume'),
                      value: controller.videoVolume.v,
                      min: 0.0,
                      max: 1.0,
                      displayValue: '${(controller.videoVolume.v * 100).toInt()}%',
                      onChanged: (v) => controller.updateVideoVolume(v),
                    ),
                    context.buildSwitchTile(
                      icon: Remix.pause_circle_line,
                      title: i18n('wallpaper_settings_pause_when_live'),
                      subtitle: i18n('wallpaper_settings_pause_when_live_subtitle'),
                      value: controller.pauseVideoWhenLivePlaying,
                    ),
                  ],
                );
              }),
              // 清除背景
              context.buildTile(
                icon: Icons.close_rounded,
                title: i18n('wallpaper_settings_clear_background'),
                subtitle: i18n('wallpaper_settings_clear_background_subtitle'),
                onTap: () => controller.clearWallpaper(),
              ),
            ]),

            const SizedBox(height: 20),

            // ===== 背景来源 =====
            context.buildGroupTitle(i18n('wallpaper_settings_source_section')),
            context.buildModernCard([
              context.buildTile(
                icon: Remix.palette_line,
                title: i18n('wallpaper_settings_solid_color'),
                subtitle: i18n('wallpaper_settings_solid_color_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperColor),
              ),
              context.buildTile(
                icon: Remix.film_line,
                title: i18n('wallpaper_settings_video_wallpaper'),
                subtitle: i18n('wallpaper_settings_video_wallpaper_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperVideo),
              ),
              context.buildTile(
                icon: Remix.image_2_line,
                title: i18n('wallpaper_settings_gallery'),
                subtitle: i18n('wallpaper_settings_gallery_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperLibrary),
              ),
              context.buildTile(
                icon: Remix.shuffle_line,
                title: i18n('wallpaper_settings_random_source'),
                subtitle: i18n('wallpaper_settings_random_source_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperApi),
              ),
              context.buildTile(
                icon: Remix.history_line,
                title: i18n('wallpaper_settings_saved_wallpapers'),
                subtitle: i18n('wallpaper_settings_saved_wallpapers_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperHistory),
              ),
              context.buildTile(
                icon: Remix.slideshow_line,
                title: i18n('wallpaper_settings_ppt_wallpaper'),
                subtitle: i18n('wallpaper_settings_ppt_wallpaper_subtitle'),
                onTap: () => SettingsNavigator.open(SettingsCrumbs.wallpaperPpt),
              ),
            ]),

            const SizedBox(height: 20),

            // ===== 本机与网络 =====
            context.buildGroupTitle(i18n('wallpaper_settings_local_network_section')),
            context.buildModernCard([
              context.buildTile(
                icon: Remix.image_add_line,
                title: i18n('wallpaper_settings_pick_local_image'),
                subtitle: i18n('wallpaper_settings_pick_local_image_subtitle'),
                onTap: () => controller.pickLocalImage(),
              ),
              context.buildTile(
                icon: Remix.video_add_line,
                title: i18n('wallpaper_settings_pick_local_video'),
                subtitle: i18n('wallpaper_settings_pick_local_video_subtitle'),
                onTap: () => controller.pickLocalVideo(),
              ),
              // 网络图片地址：内联输入框
              _NetworkUrlRow(onApply: (url) => controller.applyOnlineImage(url)),
            ]),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// 网络图片地址输入行：标题 + 输入框 + 应用按钮
class _NetworkUrlRow extends StatefulWidget {
  const _NetworkUrlRow({required this.onApply});

  final ValueChanged<String> onApply;

  @override
  State<_NetworkUrlRow> createState() => _NetworkUrlRowState();
}

class _NetworkUrlRowState extends State<_NetworkUrlRow> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            i18n('wallpaper_settings_network_image_url'),
            style: AppTextStyles.t14.copyWith(color: theme.hintColor, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: i18n('wallpaper_settings_network_image_hint'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) widget.onApply(value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () {
                  final url = _controller.text.trim();
                  if (url.isNotEmpty) widget.onApply(url);
                },
                child: Text(i18n('apply')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
