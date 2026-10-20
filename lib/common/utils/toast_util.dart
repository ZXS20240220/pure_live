import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pure_live/plugins/locale_helper.dart';

/// 应用内统一轻提示：底部滑入、内容自适应的悬浮卡片。
///
/// 历史上存在两套实现（SmartDialog 小胶囊与 Get.snackbar 带标题通栏），
/// 这里合并为一套：信息类无标题；成功/失败保留标题并按语义区分底色。
/// 提示之间为“后到顶替前一条”的替换关系，不会排队累积延迟展示。
class ToastUtil {
  ToastUtil._();

  static DateTime? _lastShowTime;

  static String? _lastSignature;

  /// 普通信息提示，默认无标题；确有分组语义时可传入标题。
  static void show(String? message, {String? title}) => _present(message, title: title);

  /// 成功提示：保留标题，沿用中性底色。
  static void success(String? message) => _present(message, title: i18nOr('success', '成功'));

  /// 失败提示：保留标题，使用错误容器色以维持警示效果。
  static void error(String? message) => _present(message, title: i18nOr('failed', '失败'), isError: true);

  /// 测试辅助：清空去重窗口，避免相邻用例因相同签名吞掉本应出现的提示。
  @visibleForTesting
  static void debugResetThrottle() {
    _lastShowTime = null;
    _lastSignature = null;
  }

  static void _present(String? message, {String? title, bool isError = false}) {
    if (message == null || message.trim().isEmpty) return;
    // 同一条提示在 3 秒内重复触发时去重，避免连续回调刷屏。
    final signature = '${title ?? ''}|$message';
    final now = DateTime.now();
    if (signature == _lastSignature &&
        _lastShowTime != null &&
        now.difference(_lastShowTime!) < const Duration(milliseconds: 3000)) {
      return;
    }
    _lastShowTime = now;
    _lastSignature = signature;
    try {
      unawaited(
        SmartDialog.showToast(
          message,
          builder: (context) => _ToastCard(message: message, title: title, isError: isError),
          alignment: Alignment.bottomCenter,
          // 底部位置使用位移动画，复现“从下方滑入”的观感。
          animationType: SmartAnimationType.centerFade_otherSlide,
          // 新提示直接顶替旧提示，避免默认排队模式导致消息滞后展示。
          displayType: SmartToastType.last,
        ).catchError((Object error, StackTrace stackTrace) {
          developer.log('Toast skipped because no dialog host is active', error: error, stackTrace: stackTrace);
        }),
      );
    } catch (error, stackTrace) {
      // Async playback/network callbacks can finish while the root overlay is
      // being replaced or already disposed. A missing toast host must never
      // turn a handled stream failure into an uncaught UI exception.
      developer.log('Toast skipped because no dialog host is active', error: error, stackTrace: stackTrace);
    }
  }
}

/// 提示卡片本体：宽度随内容自适应，过长时换行并受最大宽度约束。
class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.message, this.title, this.isError = false});

  final String message;
  final String? title;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = isError ? colors.errorContainer : colors.surfaceContainerHighest;
    final foreground = isError ? colors.onErrorContainer : colors.onSurfaceVariant;
    final bodyStyle = theme.textTheme.bodyMedium ?? const TextStyle();
    final titleStyle = (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w600);

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: colors.shadow.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title!, style: titleStyle.copyWith(color: foreground)),
              const SizedBox(height: 2),
            ],
            Text(message, style: bodyStyle.copyWith(color: foreground)),
          ],
        ),
      ),
    );
  }
}
