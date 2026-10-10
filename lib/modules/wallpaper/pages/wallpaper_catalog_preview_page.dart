import 'dart:async';
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_catalog.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_network_image.dart';

/// 目录壁纸全屏预览页
///
/// 支持图片、视频、渐变三种类型，预览层叠加与实际背景一致的模糊 + 遮罩。
class WallpaperCatalogPreviewPage extends StatefulWidget {
  const WallpaperCatalogPreviewPage({
    super.key,
    required this.items,
    required this.kind,
    this.title,
    this.initialIndex = 0,
  });

  final List<CatalogWallpaperItem> items;
  final WallpaperKind kind;
  final String? title;
  final int initialIndex;

  @override
  State<WallpaperCatalogPreviewPage> createState() => _WallpaperCatalogPreviewPageState();
}

class _WallpaperCatalogPreviewPageState extends State<WallpaperCatalogPreviewPage> {
  late int _index;
  bool _applying = false;

  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _playingSub;
  bool _videoPlaying = false;
  String? _openedUrl;
  bool _suppressAutoOpen = false;
  double _lastNonMuteVolume = 0.5;

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

  CatalogWallpaperItem? get _currentItem {
    if (widget.items.isEmpty) return null;
    return widget.items[_index.clamp(0, widget.items.length - 1)];
  }

  bool get _isVideo => widget.kind == WallpaperKind.video;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    if (_isVideo) _createPlayer();
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  void _createPlayer() {
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    _playingSub = player.stream.playing.listen((playing) {
      if (mounted) setState(() => _videoPlaying = playing);
    });
    final volume = WallpaperSettingsController.to.videoVolume.v * 100;
    _lastNonMuteVolume = WallpaperSettingsController.to.videoVolume.v > 0
        ? WallpaperSettingsController.to.videoVolume.v
        : 0.5;
    unawaited(player.setVolume(volume));
    unawaited(player.setPlaylistMode(PlaylistMode.loop));
    _openCurrent();
  }

  void _destroyPlayer() {
    final player = _player;
    _player = null;
    _videoController = null;
    _videoPlaying = false;
    _openedUrl = null;
    _suppressAutoOpen = true;
    unawaited(_playingSub?.cancel());
    _playingSub = null;
    unawaited(player?.dispose());
  }

  void _openCurrent() {
    if (!_isVideo || _suppressAutoOpen) return;
    final item = _currentItem;
    if (item == null || item.file.isEmpty || item.file == _openedUrl) return;
    _openedUrl = item.file;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_player?.open(Media(item.file), play: true));
    });
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (_videoPlaying) {
      await player.pause();
    } else {
      if (_suppressAutoOpen) {
        _suppressAutoOpen = false;
        _openCurrent();
      }
      await player.play();
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index -= 1);
      _openCurrent();
    }
  }

  void _next() {
    if (_index < widget.items.length - 1) {
      setState(() => _index += 1);
      _openCurrent();
    }
  }

  void _setVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    WallpaperSettingsController.to.updateVideoVolume(v);
    unawaited(_player?.setVolume(v * 100));
  }

  void _toggleMute() {
    final current = WallpaperSettingsController.to.videoVolume.v;
    if (current > 0) {
      _lastNonMuteVolume = current;
      _setVolume(0);
    } else {
      _setVolume(_lastNonMuteVolume > 0 ? _lastNonMuteVolume : 0.5);
    }
  }

  // ===== 档位选择 =====

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

  // ===== 应用壁纸 =====

  Future<void> _apply() async {
    if (_applying) return;
    final item = _currentItem;
    if (item == null) return;
    setState(() => _applying = true);
    ToastUtil.show('正在下载壁纸…');
    try {
      final controller = WallpaperSettingsController.to;
      bool applied = false;
      switch (widget.kind) {
        case WallpaperKind.image:
          applied = await controller.applyOnlineImage(item.file, name: item.name);
          break;
        case WallpaperKind.video:
          applied = await controller.applyOnlineVideo(item.file, name: item.name);
          break;
        case WallpaperKind.gradient:
          applied = await _applyGradient(item);
          break;
      }
      if (!applied) {
        if (mounted) ToastUtil.show('应用失败');
        return;
      }
      if (_isVideo) _destroyPlayer();
      if (mounted) {
        ToastUtil.show('已设为壁纸');
        Get.back<void>();
      }
    } catch (e) {
      if (mounted) ToastUtil.show('应用失败：$e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<bool> _applyGradient(CatalogWallpaperItem item) async {
    final stops = item.gradient ?? const <WallpaperGradientStop>[];
    final colors = <Color>[];
    for (final stop in stops) {
      final c = colorFromHex(stop.color);
      if (c != null) colors.add(c);
    }
    if (colors.isEmpty) return false;
    if (colors.length == 1) {
      await WallpaperSettingsController.to.applyWallpaper(
        WallpaperItem(
          id: item.key,
          type: WallpaperType.color,
          url: ColorWallpaperData.solid(colors.first).serialize(),
          name: item.name,
        ),
      );
    } else {
      final (begin, end) = alignmentsFor(item.deg);
      final direction = _alignmentToDirection(begin, end);
      await WallpaperSettingsController.to.applyWallpaper(
        WallpaperItem(
          id: item.key,
          type: WallpaperType.color,
          url: ColorWallpaperData(colors: colors, direction: direction).serialize(),
          name: item.name,
        ),
      );
    }
    return true;
  }

  GradientDirection _alignmentToDirection(Alignment begin, Alignment end) {
    if (begin == Alignment.centerLeft && end == Alignment.centerRight) return GradientDirection.leftToRight;
    if (begin == Alignment.centerRight && end == Alignment.centerLeft) return GradientDirection.rightToLeft;
    if (begin == Alignment.topCenter && end == Alignment.bottomCenter) return GradientDirection.topToBottom;
    if (begin == Alignment.bottomCenter && end == Alignment.topCenter) return GradientDirection.bottomToTop;
    if (begin == Alignment.topLeft && end == Alignment.bottomRight) return GradientDirection.topLeftToBottomRight;
    if (begin == Alignment.topRight && end == Alignment.bottomLeft) return GradientDirection.topRightToBottomLeft;
    if (begin == Alignment.bottomLeft && end == Alignment.topRight) return GradientDirection.bottomLeftToTopRight;
    if (begin == Alignment.bottomRight && end == Alignment.topLeft) return GradientDirection.bottomRightToTopLeft;
    return GradientDirection.topToBottom;
  }

  // ===== 标签文案 =====

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

  String _blurLabel(double sigma) => sigma == 0 ? '关闭' : '${sigma.toStringAsFixed(0)} px';

  String _maskLabel(double opacity) => '${(opacity * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final item = _currentItem;
    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title ?? '预览')),
        body: const Center(child: Text('无内容')),
      );
    }

    return Obx(() {
      final controller = WallpaperSettingsController.to;
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
            item.name ?? widget.title ?? '壁纸预览',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          actions: [
            if (widget.items.length > 1)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: Text('${_index + 1}/${widget.items.length}', style: const TextStyle(color: Colors.white70)),
                ),
              ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            _blurred(_buildViewer(item, fit), blur),
            IgnorePointer(child: _buildMask(mask)),
            Align(alignment: Alignment.bottomCenter, child: _buildActionBar(fit, blur, mask)),
          ],
        ),
      );
    });
  }

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

  Widget _buildViewer(CatalogWallpaperItem item, BoxFit fit) {
    switch (widget.kind) {
      case WallpaperKind.gradient:
        final stops = item.gradient ?? const <WallpaperGradientStop>[];
        final colors = <Color>[];
        final positions = <double>[];
        for (final stop in stops) {
          final c = colorFromHex(stop.color);
          if (c != null) {
            colors.add(c);
            positions.add((stop.pos / 100).clamp(0.0, 1.0));
          }
        }
        if (colors.isEmpty) return const ColoredBox(color: Color(0xFF141E30));
        if (colors.length < 2) return ColoredBox(color: colors.first);
        final (begin, end) = alignmentsFor(item.deg);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: begin, end: end, colors: colors, stops: positions),
          ),
        );
      case WallpaperKind.video:
        final vc = _videoController;
        if (vc == null) return const ColoredBox(color: Colors.black);
        return Video(
          controller: vc,
          controls: NoVideoControls,
          fit: fit,
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
        );
      case WallpaperKind.image:
        final poster = item.poster?.isNotEmpty == true ? item.poster! : item.file;
        if (poster.isEmpty) return const ColoredBox(color: Colors.black);
        return WallpaperNetworkImage(
          url: item.thumb?.isNotEmpty == true ? item.thumb! : poster,
          fallbackUrl: poster,
          fit: fit,
          placeholder: const ColoredBox(color: Colors.black),
          fallback: const Center(child: Icon(Remix.image_line, color: Colors.white54, size: 48)),
        );
    }
  }

  Widget _buildActionBar(BoxFit fit, double blur, double mask) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isVideo) ...[_buildVolumeControl(), const SizedBox(height: 12)],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              if (_isVideo) ...[
                _ActionButton(
                  icon: _videoPlaying ? Remix.pause_line : Remix.play_line,
                  label: _videoPlaying ? '暂停' : '播放',
                  onPressed: _togglePlay,
                ),
                _ActionButton(icon: Remix.arrow_left_s_line, label: '上一张', onPressed: _index > 0 ? _previous : null),
                _ActionButton(
                  icon: Remix.arrow_right_s_line,
                  label: '下一张',
                  onPressed: _index < widget.items.length - 1 ? _next : null,
                ),
              ],
              _ActionButton(icon: Remix.aspect_ratio_line, label: _fitLabel(fit), onPressed: _pickFit),
              _ActionButton(icon: Remix.blur_off_line, label: _blurLabel(blur), onPressed: _pickBlur),
              _ActionButton(icon: Remix.contrast_2_line, label: _maskLabel(mask), onPressed: _pickMask),
              _ActionButton(icon: Remix.check_line, label: '设为背景', primary: true, busy: _applying, onPressed: _apply),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    final volume = WallpaperSettingsController.to.videoVolume.v;
    final muted = volume <= 0;
    final IconData icon = muted
        ? Remix.volume_mute_line
        : volume < 0.5
        ? Remix.volume_down_line
        : Remix.volume_up_line;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(24)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: _toggleMute,
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          SizedBox(
            width: 180,
            child: Slider(
              value: volume,
              min: 0,
              max: 1,
              activeColor: Colors.white,
              inactiveColor: Colors.white38,
              onChanged: _setVolume,
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              '${(volume * 100).toInt()}%',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// 预览页底部的药丸形按钮
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !busy;
    final child = busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          );

    return Material(
      color: primary ? colors.primary : Colors.white24,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), child: child),
      ),
    );
  }
}
