import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_api_catalog.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_api_client.dart';

/// 随机图源预览页
///
/// 从选中的图源获取一张随机图片并展示，用户可以"换一张"或"应用为壁纸"。
/// 对齐上游 `WallpaperPreviewPage`：预览层叠加与实际背景一致的模糊 + 遮罩，
/// 并提供填充方式、高斯模糊、遮罩档位选择。
class WallpaperApiPreviewPage extends StatefulWidget {
  const WallpaperApiPreviewPage({super.key, required this.source});

  final WallpaperApiSource source;

  @override
  State<WallpaperApiPreviewPage> createState() => _WallpaperApiPreviewPageState();
}

class _WallpaperApiPreviewPageState extends State<WallpaperApiPreviewPage> {
  Uint8List? _imageBytes;
  bool _loading = true;
  String? _error;

  static const List<BoxFit> kFitModes = <BoxFit>[
    BoxFit.cover,
    BoxFit.contain,
    BoxFit.fill,
    BoxFit.fitWidth,
    BoxFit.fitHeight,
    BoxFit.none,
    BoxFit.scaleDown,
  ];

  static const List<double> kMaskSteps = <double>[
    0,
    0.05,
    0.1,
    0.15,
    0.2,
    0.25,
    0.3,
    0.35,
    0.4,
    0.45,
    0.5,
    0.55,
    0.6,
    0.65,
    0.7,
    0.75,
    0.8,
    0.85,
    0.9,
    0.95,
    1,
  ];

  static const List<double> kBlurSteps = <double>[0, 2, 4, 6, 8, 12, 16, 24, 32, 48];

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  Future<void> _fetchImage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final bytes = await WallpaperApiClient.instance.fetchRandomImage(widget.source);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (bytes == null) {
        _error = '获取图片失败，请重试或换一个图源';
      } else {
        _imageBytes = bytes;
      }
    });
  }

  Future<void> _apply() async {
    final bytes = _imageBytes;
    if (bytes == null) return;
    SmartDialog.showLoading(msg: '应用中...');
    try {
      final ok = await WallpaperSettingsController.to.applyImageBytes(bytes);
      if (ok) {
        SmartDialog.showToast('已设为壁纸');
        if (mounted) Get.back<void>();
      } else {
        SmartDialog.showToast('应用失败');
      }
    } finally {
      SmartDialog.dismiss();
    }
  }

  // ===== 档位选择对话框 =====

  Future<void> _pickFit() async {
    final controller = WallpaperSettingsController.to;
    final current = WallpaperFit.toBoxFit(controller.fitIndex.v);
    final picked = await _pickOption<BoxFit>(
      title: '填充方式',
      icon: Remix.aspect_ratio_line,
      options: kFitModes,
      current: current,
      labelOf: _fitLabel,
    );
    if (picked != null) controller.updateFit(kFitModes.indexOf(picked));
  }

  Future<void> _pickBlur() async {
    final controller = WallpaperSettingsController.to;
    final current = kBlurSteps[_closestIndex(kBlurSteps, controller.blurRadius.v)];
    final picked = await _pickOption<double>(
      title: '高斯模糊',
      icon: Remix.blur_off_line,
      options: kBlurSteps,
      current: current,
      labelOf: _blurLabel,
    );
    if (picked != null) controller.updateBlurRadius(picked);
  }

  Future<void> _pickMask() async {
    final controller = WallpaperSettingsController.to;
    final current = kMaskSteps[_closestIndex(kMaskSteps, controller.maskOpacity.v)];
    final picked = await _pickOption<double>(
      title: '遮罩',
      icon: Remix.contrast_2_line,
      options: kMaskSteps,
      current: current,
      labelOf: _maskLabel,
    );
    if (picked != null) controller.updateMaskOpacity(picked);
  }

  int _closestIndex(List<double> steps, double value) {
    var best = 0;
    var bestDelta = double.infinity;
    for (var i = 0; i < steps.length; i++) {
      final delta = (steps[i] - value).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  Future<T?> _pickOption<T>({
    required String title,
    required IconData icon,
    required List<T> options,
    required T current,
    required String Function(T) labelOf,
  }) {
    final colors = Theme.of(context).colorScheme;
    return showDialog<T>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              final selected = option == current;
              return ListTile(
                dense: true,
                title: Text(labelOf(option)),
                trailing: selected ? Icon(Remix.check_line, color: colors.primary) : null,
                onTap: () => Navigator.of(dialogContext).pop(option),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消'))],
      ),
    );
  }

  String _fitLabel(BoxFit fit) {
    switch (fit) {
      case BoxFit.cover:
        return '等比覆盖';
      case BoxFit.contain:
        return '等比包含';
      case BoxFit.fill:
        return '拉伸填充';
      case BoxFit.fitWidth:
        return '适应宽度';
      case BoxFit.fitHeight:
        return '适应高度';
      case BoxFit.none:
        return '原始大小';
      case BoxFit.scaleDown:
        return '等比缩小';
    }
  }

  String _blurLabel(double sigma) => sigma <= 0 ? '关闭' : '${sigma.round()}';

  String _maskLabel(double step) => '${(step * 100).round()}%';

  Widget _blurred(Widget child, double sigma) {
    if (sigma <= 0) return child;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }

  Widget _buildMask(double opacity) {
    if (opacity <= 0) return const SizedBox.shrink();
    final light = Theme.of(context).brightness == Brightness.light;
    return ColoredBox(color: (light ? Colors.white : Colors.black).withValues(alpha: opacity));
  }

  @override
  Widget build(BuildContext context) {
    final controller = WallpaperSettingsController.to;
    return Obx(() {
      final fit = WallpaperFit.toBoxFit(controller.fitIndex.v);
      final blur = controller.blurRadius.v;
      final mask = controller.maskOpacity.v;
      return Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: Text(
            widget.source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          actions: [
            IconButton(
              tooltip: '换一张',
              icon: const Icon(Remix.refresh_line, color: Colors.white),
              onPressed: _loading ? null : _fetchImage,
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_imageBytes != null)
              _blurred(SizedBox.expand(child: Image.memory(_imageBytes!, fit: fit, gaplessPlayback: true)), blur)
            else if (_error != null)
              Center(
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            IgnorePointer(child: _buildMask(mask)),
            if (_loading) const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
            Align(alignment: Alignment.bottomCenter, child: _buildActionBar(fit, blur, mask)),
          ],
        ),
      );
    });
  }

  Widget _buildActionBar(BoxFit fit, double blur, double mask) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [
          _ActionButton(icon: Remix.refresh_line, label: '换一张', onPressed: _loading ? null : _fetchImage),
          _ActionButton(icon: Remix.aspect_ratio_line, label: _fitLabel(fit), onPressed: _pickFit),
          _ActionButton(icon: Remix.blur_off_line, label: _blurLabel(blur), onPressed: _pickBlur),
          _ActionButton(icon: Remix.contrast_2_line, label: _maskLabel(mask), onPressed: _pickMask),
          _ActionButton(
            icon: Remix.check_line,
            label: '应用为壁纸',
            primary: true,
            onPressed: _loading || _imageBytes == null ? null : _apply,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onPressed, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Material(
      color: primary ? colors.primary : Colors.white24,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
