import 'package:pure_live/common/index.dart';

/// 兼容层：成功/失败提示统一由 [ToastUtil] 渲染，保证全应用只有一套样式。
class SnackBarUtil {
  static void success(String text) => ToastUtil.success(text);

  static void error(String text) => ToastUtil.error(text);
}
