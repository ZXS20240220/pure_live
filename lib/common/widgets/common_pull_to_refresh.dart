import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:pure_live/plugins/global.dart';

/// 全宽度/全平台生效的 EasyRefresh 下拉刷新包装（对齐开发版）。
///
/// 桌面端与移动端、任意窗口宽度一律包裹；桌面端鼠标滚轮与拖拽滚动由全局
/// MyCustomScrollBehavior 提供，不受此包装影响。
///
/// 使用与 [appRefreshIndicators] 一致的 [ClassicHeader]，统一全站下拉刷新
/// 样式（含"下拉刷新/松开加载"文案与秒级最后更新时间）。
///
/// [childBuilder] 必须把回调给出的 physics 安装到实际的纵向滚动控件上：
/// EasyRefresh 需要持有与子级完全一致的 physics，否则外层 overscroll
/// 策略会在刷新动画武装前消费掉边界拖拽。
Widget buildCommonPullToRefresh({
  required BuildContext context,
  required String refreshKey,
  required Future<void> Function() onRefresh,
  required ERChildBuilder childBuilder,
  EasyRefreshController? controller,
}) {
  final indicators = appRefreshIndicators(context);
  return EasyRefresh.builder(
    key: ValueKey('pull_to_refresh_$refreshKey'),
    controller: controller,
    header: indicators.header,
    triggerAxis: Axis.vertical,
    onRefresh: onRefresh,
    childBuilder: childBuilder,
  );
}
