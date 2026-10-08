import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/plugins/locale_helper.dart';
import 'package:pure_live/common/utils/toast_util.dart';
import 'package:pure_live/common/models/live_message.dart';

class SuperChatCard extends StatefulWidget {
  final LiveSuperChatMessage message;

  /// 初始锁定状态（来自控制器）。点击后的状态由卡片内部自持并立即刷新，
  /// 控制器集合仅用于到期清理过滤，不反向驱动 UI。
  final bool initialLocked;
  final VoidCallback onToggleLock;

  const SuperChatCard(this.message, {super.key, required this.initialLocked, required this.onToggleLock});

  @override
  State<SuperChatCard> createState() => _SuperChatCardState();
}

class _SuperChatCardState extends State<SuperChatCard> {
  Timer? _timer;

  int _remainSeconds = 0;
  bool _expanded = false;
  late bool _locked = widget.initialLocked;

  @override
  void initState() {
    super.initState();

    _initTimer();
  }

  @override
  void didUpdateWidget(covariant SuperChatCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 防御：即便外层未按 messageId 给 key（列表重排导致 State 被复用给另一条
    // SC），锁定态也必须跟随新卡片，避免“锁定样式串到新 SC 上”。
    if (oldWidget.message.messageId != widget.message.messageId) {
      _locked = widget.initialLocked;
      _expanded = false;
    }

    if (oldWidget.message.startTime != widget.message.startTime ||
        oldWidget.message.endTime != widget.message.endTime) {
      _timer?.cancel();
      _timer = null;

      _initTimer();
    }
  }

  void _toggleLock() {
    setState(() => _locked = !_locked);
    widget.onToggleLock();
  }

  void _initTimer() {
    _updateRemainSeconds();

    if (_remainSeconds > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateRemainSeconds());
    }
  }

  void _updateRemainSeconds() {
    final duration = widget.message.endTime.difference(DateTime.now());

    final remain = duration.inMilliseconds <= 0 ? 0 : (duration.inMilliseconds / 1000).ceil().clamp(0, 7200);

    if (!mounted) {
      return;
    }

    setState(() {
      _remainSeconds = remain;
    });

    if (remain <= 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  String get _remainText {
    final minutes = _remainSeconds ~/ 60;
    final seconds = _remainSeconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// 倒计时已结束但卡片被锁定时，状态位显示“已锁定”。
  String get _statusText => _locked && _remainSeconds <= 0 ? '已锁定' : _remainText;

  Color _contrastText(Color background) {
    return background.computeLuminance() > 0.55 ? const Color(0xFF18181A) : Colors.white;
  }

  Color _secondaryText(Color background) {
    return background.computeLuminance() > 0.55 ? const Color(0x8A18181A) : Colors.white.withValues(alpha: 0.70);
  }

  Color _overlay(Color background, double opacity) {
    return _contrastText(background).withValues(alpha: opacity);
  }

  Color _platformColor(String source, Color fallback) {
    final value = source.trim();
    final normalized = value.startsWith('#') ? value.substring(1) : value;
    if (!RegExp(r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(normalized)) return fallback;
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return fallback;
    return Color(normalized.length == 6 ? 0xFF000000 | parsed : parsed);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final theme = Theme.of(context);

    final headerColor = _platformColor(message.backgroundColor, theme.colorScheme.primaryContainer);
    final messageColor = _platformColor(message.backgroundBottomColor, theme.colorScheme.surfaceContainerHighest);

    final headerText = _contrastText(headerColor);
    final headerSubText = _secondaryText(headerColor);
    final messageText = _contrastText(messageColor);

    // 整卡右键复制 SC 内容；左键仅正文区触发展开，避免与锁按钮冲突。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTap: () => clipboard(message.message),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 锁定时用琥珀色边框给出明显视觉反馈。
          border: Border.all(
            color: _locked ? const Color(0xFFFFC107) : Colors.black.withValues(alpha: 0.08),
            width: _locked ? 1.4 : 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 10,
              spreadRadius: 0,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(
              message: message,
              backgroundColor: headerColor,
              primaryText: headerText,
              secondaryText: headerSubText,
            ),
            _buildMessageBody(
              context: context,
              message: message,
              backgroundColor: messageColor,
              textColor: messageText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader({
    required LiveSuperChatMessage message,
    required Color backgroundColor,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(color: backgroundColor),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 280 || MediaQuery.textScalerOf(context).scale(14) > 24;
          // 用户名过长：单行渐隐截断，悬浮 tooltip 显示完整用户名。
          final userName = Tooltip(
            message: message.userName,
            waitDuration: const Duration(milliseconds: 400),
            child: Text(
              message.userName,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(color: primaryText, fontSize: 14, height: 1.2, fontWeight: FontWeight.w600),
            ),
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildAvatar(message.face, primaryText),
                    const SizedBox(width: 10),
                    Expanded(child: userName),
                  ],
                ),
                const SizedBox(height: 10),
                _buildPrice(message, primaryText),
                const SizedBox(height: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _buildInfoArea(
                    backgroundColor: backgroundColor,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                  ),
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildAvatar(message.face, primaryText),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [userName, const SizedBox(height: 5), _buildPrice(message, primaryText)],
                ),
              ),
              const SizedBox(width: 8),
              _buildInfoArea(backgroundColor: backgroundColor, primaryText: primaryText, secondaryText: secondaryText),
            ],
          );
        },
      ),
    );
  }

  /// 锁定按钮：紧凑的圆角边框小方块，内联在倒计时右侧。
  Widget _buildLockButton(Color primaryText) {
    final locked = _locked;
    final accent = const Color(0xFFFFC107);
    return Tooltip(
      message: locked ? '解锁' : '锁定',
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _toggleLock,
          child: Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: locked ? accent : primaryText.withValues(alpha: 0.45), width: 1),
            ),
            child: Icon(
              locked ? Remix.lock_fill : Remix.lock_unlock_line,
              size: 12,
              color: locked ? accent : primaryText.withValues(alpha: 0.85),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrice(LiveSuperChatMessage message, Color textColor) {
    final listPrice = message.listPrice;
    return Row(
      children: [
        const Icon(Remix.money_cny_circle_fill, size: 16, color: Color(0xFFFFC107)),
        const SizedBox(width: 3),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '￥${message.price}'),
                if (listPrice != null && listPrice != message.price)
                  TextSpan(
                    text: '(￥$listPrice)',
                    style: TextStyle(
                      fontSize: 11,
                      color: textColor.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            style: TextStyle(
              color: textColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatar(String url, Color borderColor) {
    final uri = Uri.tryParse(url.trim());
    final hasRemoteAvatar = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
    final fallback = Container(
      color: Colors.black.withValues(alpha: 0.10),
      alignment: Alignment.center,
      child: Icon(Remix.user_2_fill, size: 20, color: borderColor),
    );
    return Container(
      width: 44,
      height: 44,
      padding: const EdgeInsets.all(1.8),
      decoration: BoxDecoration(color: borderColor.withValues(alpha: 0.9), shape: BoxShape.circle),
      child: ClipOval(
        child: hasRemoteAvatar
            ? Image.network(
                url,
                width: 40.4,
                height: 40.4,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }

  Widget _buildInfoArea({required Color backgroundColor, required Color primaryText, required Color secondaryText}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(color: _overlay(backgroundColor, 0.10), borderRadius: BorderRadius.circular(6)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Remix.vip_diamond_fill, size: 11, color: const Color(0xFFFFC107)),
              const SizedBox(width: 3),
              Text(
                'SC',
                style: TextStyle(
                  color: secondaryText,
                  fontSize: 12,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Remix.time_line, size: 13, color: secondaryText),
            const SizedBox(width: 3),
            Text(
              _statusText,
              style: TextStyle(
                color: primaryText,
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 6),
            _buildLockButton(primaryText),
          ],
        ),
      ],
    );
  }

  Future<void> clipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    ToastUtil.show(i18n('copied_to_clipboard'));
  }

  Widget _buildMessageBody({
    required BuildContext context,
    required LiveSuperChatMessage message,
    required Color backgroundColor,
    required Color textColor,
  }) {
    final textScale = MediaQuery.textScalerOf(context).scale(14);
    final collapsedLines = textScale > 28 ? 1 : (textScale > 21 ? 2 : 3);

    // 普通 Text 不支持选择与拖拽；收起时截断行数随字号缩放，左键点击展开/收起完整内容。
    final body = Material(
      color: backgroundColor,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 13),
          child: Text(
            message.message,
            maxLines: _expanded ? null : collapsedLines,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(color: textColor, fontSize: 14, height: 1.5, fontWeight: FontWeight.w400),
          ),
        ),
      ),
    );

    // 收起时悬浮显示完整内容；展开后正文已完整显示，不再需要 tooltip。
    if (_expanded) return body;
    return Tooltip(message: message.message, waitDuration: const Duration(milliseconds: 400), child: body);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
