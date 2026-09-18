import 'package:flutter/material.dart';

/// 平台判断已常量化：本项目仅支持 Windows 桌面端。
/// 移动端/其他桌面平台的分支代码依赖这些常量恒为 false 而失效。
class PlatformUtils {
  PlatformUtils._();
  static const bool isDesktop = true;

  static const bool isDesktopNotMac = true;

  static const bool isMobile = false;

  static bool isMobileWidth(BuildContext context) {
    return MediaQuery.of(context).size.width < 760;
  }

  static const bool isWindows = true;
  static const bool isMacOS = false;
  static const bool isLinux = false;
  static const bool isAndroid = false;
  static const bool isIOS = false;

  static T select<T>({required T desktop, required T mobile}) {
    return isDesktop ? desktop : mobile;
  }
}
