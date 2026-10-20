import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/wallpaper_settings_controller.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';
import 'package:pure_live/modules/wallpaper/widgets/cover_file_image.dart';
import 'package:pure_live/modules/wallpaper/widgets/wallpaper_video_player.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<WallpaperSettingsController>();

    return Obx(() {
      final type = controller.wallpaperType;
      final source = controller.resolveWallpaperSourcePath();
      // 视口物理像素尺寸：作为图片解码目标，避免按原图全尺寸解码浪费内存。
      // 窗口缩放时 MediaQuery 依赖触发重建，Provider 相等性变化驱动重解码。
      final viewSize = MediaQuery.sizeOf(context);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final targetWidth = math.max(1, (viewSize.width * dpr).round());
      final targetHeight = math.max(1, (viewSize.height * dpr).round());

      Widget background;
      if (!controller.hasWallpaper || type == WallpaperType.none) {
        background = const SizedBox.shrink();
      } else {
        switch (type) {
          case WallpaperType.imageLocal:
            background = _buildImageBackground(
              CoverFileImage(File(source), targetWidth: targetWidth, targetHeight: targetHeight),
            );
            break;
          case WallpaperType.imageOnline:
          case WallpaperType.imagePreset:
            background = CachedNetworkImage(
              imageUrl: source,
              fit: controller.resolvedFit,
              memCacheWidth: targetWidth,
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
          case WallpaperType.color:
            background = _buildColorBackground(source);
            break;
          case WallpaperType.slideshow:
            background = const _SlideshowBackground();
            break;
          case WallpaperType.none:
            background = const SizedBox.shrink();
            break;
        }
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
              // 壁纸层：旧壁纸保持不透明直到底层，新壁纸在上层淡入覆盖
              _BackgroundStack(identityKey: '${type.name}:$source', child: background),
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
      gaplessPlayback: true,
      fit: controller.resolvedFit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildColorBackground(String source) {
    final data = ColorWallpaperData.deserialize(source);
    if (data == null || data.colors.isEmpty) {
      return const ColoredBox(color: Color(0xFF1A1A2E));
    }
    if (data.colors.length == 1) {
      return ColoredBox(color: data.colors.first);
    }
    return DecoratedBox(
      decoration: BoxDecoration(gradient: data.toGradient()),
      child: const SizedBox.expand(),
    );
  }
}

/// 壁纸切换容器：旧壁纸保持不透明留在底层，新壁纸在上层淡入覆盖，
/// 新壁纸完全显示后才移除旧壁纸，彻底避免切换时透出底层黑色。
class _BackgroundStack extends StatefulWidget {
  final Widget child;
  final Object identityKey;
  final Duration fadeDuration;

  const _BackgroundStack({
    required this.child,
    required this.identityKey,
    this.fadeDuration = const Duration(milliseconds: 300),
  });

  @override
  State<_BackgroundStack> createState() => _BackgroundStackState();
}

class _BackgroundStackState extends State<_BackgroundStack> with SingleTickerProviderStateMixin {
  Widget? _oldChild;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.fadeDuration, value: 1.0);
    _controller.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_BackgroundStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityKey != widget.identityKey) {
      // 壁纸真正切换时，将旧壁纸保存在底层并启动新壁纸淡入
      _oldChild = oldWidget.child;
      _controller.forward(from: 0.0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _oldChild = null);
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 旧壁纸始终不透明，作为底层
        if (_oldChild != null) Positioned.fill(child: _oldChild!),
        // 新壁纸在上层淡入覆盖
        Positioned.fill(
          child: FadeTransition(opacity: _controller.drive(Tween<double>(begin: 0.0, end: 1.0)), child: widget.child),
        ),
      ],
    );
  }
}

/// PPT 壁纸播放组件：按设定间隔与规则轮播选中的图片。
class _SlideshowBackground extends StatefulWidget {
  const _SlideshowBackground();

  @override
  State<_SlideshowBackground> createState() => _SlideshowBackgroundState();
}

class _SlideshowBackgroundState extends State<_SlideshowBackground> with WidgetsBindingObserver {
  late final WallpaperSettingsController controller;
  Timer? _timer;
  int _currentIndex = 0;
  Worker? _pathsWorker;
  Worker? _intervalWorker;
  final _shuffleQueue = <int>[];
  int _shufflePos = 0;

  /// 窗口最小化/不可见时置 true，暂停轮播避免后台解码与淡入开销。
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = Get.find<WallpaperSettingsController>();
    _pathsWorker = ever(controller.pptImagePaths, (_) {
      _resetShuffle();
      _alignInitialIndex();
      _restartTimer();
    });
    _intervalWorker = ever(controller.pptInterval, (_) => _restartTimer());
    _alignInitialIndex();
    _restartTimer();
  }

  void _alignInitialIndex() {
    final length = controller.pptImagePaths.length;
    if (length <= 1) {
      _currentIndex = 0;
      return;
    }
    if (controller.pptMode.v == PptMode.random.name) {
      _ensureShuffleQueue(length);
      _currentIndex = _shuffleQueue[_shufflePos];
      _shufflePos++;
    } else {
      _currentIndex = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_hidden) {
          _hidden = true;
          _timer?.cancel();
          _timer = null;
        }
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        if (_hidden) {
          _hidden = false;
          _restartTimer();
        }
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pathsWorker?.dispose();
    _intervalWorker?.dispose();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    // 窗口不可见时不启动计时，恢复可见后由生命周期回调统一重启
    if (_hidden) return;
    final interval = controller.pptInterval.v.clamp(1, 3600);
    _timer = Timer.periodic(Duration(seconds: interval), (_) => _advance());
  }

  void _advance() {
    final paths = controller.pptImagePaths;
    if (paths.length <= 1) {
      if (mounted) setState(() {});
      return;
    }
    final next = _nextIndex(paths.length);
    if (mounted) setState(() => _currentIndex = next);
    _precacheNext();
  }

  /// 不消耗随机队列的“预览下一张”索引；随机模式在换批次边界返回 null（跳过预解码）。
  int? _peekNextIndex(int length) {
    if (length <= 1) return null;
    if (controller.pptMode.v == PptMode.random.name) {
      if (_shufflePos < _shuffleQueue.length) return _shuffleQueue[_shufflePos];
      return null;
    }
    return (_currentIndex + 1) % length;
  }

  /// 预解码下一张，使切换淡入开始时纹理已就绪，消除低配机上的顿挫。
  void _precacheNext() {
    if (!mounted) return;
    final paths = controller.resolvePptPaths()
      ..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    final peek = _peekNextIndex(paths.length);
    if (peek == null) return;
    final path = paths[peek];
    final dims = _targetDims();
    if (dims == null) return;
    final provider = CoverFileImage(File(path), targetWidth: dims.$1, targetHeight: dims.$2);
    unawaited(precacheImage(provider, context).catchError((_) {}));
  }

  /// 视口物理像素尺寸（解码目标），视口尚未就绪时返回 null。
  (int, int)? _targetDims() {
    if (!mounted) return null;
    final viewSize = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (math.max(1, (viewSize.width * dpr).round()), math.max(1, (viewSize.height * dpr).round()));
  }

  void _resetShuffle() {
    _shuffleQueue.clear();
    _shufflePos = 0;
  }

  void _ensureShuffleQueue(int length) {
    if (_shuffleQueue.isEmpty || _shufflePos >= _shuffleQueue.length) {
      _shuffleQueue
        ..clear()
        ..addAll(List<int>.generate(length, (i) => i))
        ..shuffle();
      _shufflePos = 0;
    }
  }

  int _nextIndex(int length) {
    if (length <= 1) return 0;
    if (controller.pptMode.v == PptMode.random.name) {
      _ensureShuffleQueue(length);
      final next = _shuffleQueue[_shufflePos];
      _shufflePos++;
      return next;
    }
    return (_currentIndex + 1) % length;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final paths = controller.resolvePptPaths()
        ..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
      if (paths.isEmpty) return const SizedBox.shrink();
      if (_currentIndex >= paths.length) _currentIndex = 0;
      final path = paths[_currentIndex];
      final file = File(path);
      // 异步校验失效文件并清理列表：build 内不做同步磁盘 IO，
      // 展示层失效由 errorBuilder 兜底。
      unawaited(
        file.exists().then((exists) {
          if (!exists && mounted) controller.removeInvalidPptImage(path);
        }),
      );
      final dims = _targetDims();
      return _BackgroundStack(
        identityKey: path,
        fadeDuration: const Duration(milliseconds: 300),
        child: Image(
          // 视口未就绪时退回原尺寸解码，保持可用性优先
          image: dims == null ? FileImage(file) : CoverFileImage(file, targetWidth: dims.$1, targetHeight: dims.$2),
          gaplessPlayback: true,
          fit: controller.resolvedFit,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    });
  }
}
