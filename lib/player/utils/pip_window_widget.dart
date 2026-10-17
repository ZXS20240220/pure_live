import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class PureLivePipWidget extends StatelessWidget {
  final Widget child;

  /// 背景色。默认黑色；壁纸模式下调用方应传入透明色，
  /// 否则此处的黑色背景会挡住壁纸（视频宽高比不匹配时露出黑边）。
  final Color color;

  const PureLivePipWidget({super.key, required this.child, this.color = Colors.black});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return child;
    }
    return Stack(
      children: [
        DragToResizeArea(
          child: Container(color: color, child: child),
        ),
      ],
    );
  }
}
