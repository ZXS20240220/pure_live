import 'package:flutter/material.dart';

import 'package:pure_live/common/services/settings_service.dart';
import 'package:remixicon/remixicon.dart';

/// 纯音频模式面板：直播间（PlayerManager.buildAudioOnlyUI）与本地回放页共用，
/// 保证两处视觉规格一致。
///
/// 背景：主播头像暗化铺底（无头像时省略）+ 深蓝渐变遮罩；
/// 内容：呼吸动画圆形头像（无头像时显示 [fallbackIcon]）、标题、
/// 主播昵称徽章、状态徽章（[restoring] 为 true 时显示加载圈）。
class AudioOnlyPanel extends StatelessWidget {
  const AudioOnlyPanel({
    super.key,
    this.avatarUrl = '',
    this.title = '',
    this.subtitle = '',
    required this.statusText,
    this.restoring = false,
    this.fallbackIcon = Remix.user_3_line,
    this.scrollable = true,
    this.opaqueBackground = false,
  });

  /// 铺底暗化背景的头像 URL，为空时不显示背景图。
  final String avatarUrl;

  /// 主标题（直播间为直播标题，本地回放为录像标题），为空时不显示。
  final String title;

  /// 昵称徽章文字，为空时不显示。
  final String subtitle;

  /// 状态徽章文字（如"纯音频模式"）。
  final String statusText;

  /// 正在恢复视频画面时，状态徽章图标显示为加载圈。
  final bool restoring;

  /// 头像缺失或加载失败时，头像位置显示的图标。
  final IconData fallbackIcon;

  /// 视口高度不足（compact 布局）时是否允许滚动。
  /// 画中画等拖拽手势敏感的场景应传 false，避免 Scrollable 抢走窗口拖动。
  final bool scrollable;

  /// 强制使用不透明渐变背景。
  /// 默认 false 时跟随壁纸设置：开启壁纸则降低遮罩不透明度透出壁纸。
  /// 画中画等没有壁纸的独立窗口应传 true，避免低透明度渐变叠在黑底上。
  final bool opaqueBackground;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        final compact = maxHeight < 500;
        final avatarSize = compact ? (maxHeight * 0.22).clamp(50.0, 76.0) : 100.0;
        final titleSize = compact ? 14.0 : 22.0;
        final nickSize = compact ? 11.0 : 13.0;
        final badgeTextSize = compact ? 11.0 : 13.0;
        final gapLarge = compact ? 10.0 : 24.0;
        final gapMedium = compact ? 8.0 : 16.0;
        final gapSmall = compact ? 4.0 : 8.0;

        final avatar = avatarUrl;
        final titleText = title;
        final nick = subtitle;

        final background = avatar.isEmpty
            ? const SizedBox.expand()
            : Positioned.fill(
                child: Opacity(
                  opacity: 0.22,
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.mode(Color(0xFF273047), BlendMode.modulate),
                    child: Image.network(avatar, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.expand()),
                  ),
                ),
              );

        // 有壁纸时降低渐变遮罩不透明度，透出应用壁纸；画中画等无壁纸窗口
        // 通过 opaqueBackground 强制保持不透明观感。
        final gradientColors = opaqueBackground || !SettingsService.hasWallpaper
            ? const <Color>[Color(0xE8121827), Color(0xF20B0E16), Color(0xF0151020)]
            : const <Color>[Color(0x99121827), Color(0xA30B0E16), Color(0x9E151020)];

        return Stack(
          fit: StackFit.expand,
          children: [
            background,
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradientColors),
              ),
            ),
            Container(
              width: maxWidth,
              height: maxHeight,
              alignment: Alignment.center,
              child: SingleChildScrollView(
                physics: compact && scrollable ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24, vertical: compact ? 4 : 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? maxWidth : 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _BreathingScale(
                        child: Container(
                          width: avatarSize,
                          height: avatarSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.04),
                                blurRadius: compact ? 10 : 20,
                                spreadRadius: compact ? 4 : 8,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: avatar.isNotEmpty
                                ? Image.network(
                                    avatar,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) =>
                                        Icon(fallbackIcon, color: Colors.white24),
                                  )
                                : Icon(fallbackIcon, color: Colors.white24),
                          ),
                        ),
                      ),
                      if (titleText.isNotEmpty) ...[
                        SizedBox(height: gapLarge),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 24),
                          child: Text(
                            titleText,
                            textAlign: TextAlign.center,
                            maxLines: compact ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleSize,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                      if (nick.isNotEmpty) ...[
                        SizedBox(height: gapSmall),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 14, vertical: compact ? 2 : 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: Text(
                            nick,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: nickSize,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: gapMedium),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: compact ? 5 : 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          color: restoring
                              ? const Color(0xFF5B67F1).withValues(alpha: 0.28)
                              : Colors.white.withValues(alpha: 0.08),
                          border: Border.all(
                            color: restoring
                                ? const Color(0xFF8B94FF).withValues(alpha: 0.62)
                                : Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: Row(
                            key: ValueKey<bool>(restoring),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (restoring)
                                SizedBox.square(
                                  dimension: compact ? 12 : 15,
                                  child: const CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white),
                                )
                              else
                                Icon(
                                  Remix.headphone_line,
                                  color: Colors.white.withValues(alpha: 0.85),
                                  size: compact ? 12 : 16,
                                ),
                              SizedBox(width: compact ? 4 : 8),
                              Text(
                                statusText,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: badgeTextSize,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 头像持续呼吸缩放动画：0.95 ↔ 1.05 往返循环，单程 1.5 秒。
class _BreathingScale extends StatefulWidget {
  const _BreathingScale({required this.child});

  final Widget child;

  @override
  State<_BreathingScale> createState() => _BreathingScaleState();
}

class _BreathingScaleState extends State<_BreathingScale> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  late final Animation<double> _scale = Tween<double>(
    begin: 0.95,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scale,
      builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
      child: widget.child,
    );
  }
}
