import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';

/// Windows 上进程级唯一的 WebView2 [WebViewEnvironment]。
///
/// 插件默认行为是"每次创建 InAppWebView 都重新调用
/// `CreateCoreWebView2EnvironmentWithOptions` 新建一个 Environment"，
/// 并共享 exe 旁的默认用户数据目录。页面关闭（最后一个控制器 Close）
/// 会触发共享浏览器进程异步退出，下一次创建 Environment 与该退出过程
/// 竞争时可能失败（典型 0x8007139F / E_FAIL），表现为
/// `PlatformException(0, Cannot create the InAppWebView instance!)`，
/// 且长时间使用后可能持续失败，直到重启应用才能恢复。
///
/// 启动时创建一个常驻环境供所有 InAppWebView 复用：
/// * 原生创建路径直接复用现有 environment，不再调用
///   `CreateCoreWebView2EnvironmentWithOptions`（即失败的根源调用）；
/// * 常驻引用让浏览器进程保持热态，消除"最后一个控制器关闭→浏览器进程
///   退出→下次创建竞争退出过程"的失败窗口；
/// * 用户数据目录固定在应用数据目录内，避免 exe 目录只读（MSIX/安装版）
///   导致默认路径环境创建失败。
class AppWebView2Environment {
  AppWebView2Environment._();

  static const String dirName = 'WEBVIEW2';

  static WebViewEnvironment? _environment;
  static Future<void>? _initializing;

  static Future<void> cleanupOnStartup() async {
    if (kIsWeb || !Platform.isWindows) return;
    final candidates = <String>[
      p.join(AppPathManager().basePath, dirName),
      p.join(
        p.dirname(Platform.resolvedExecutable),
        '${p.basenameWithoutExtension(Platform.resolvedExecutable)}.exe.WebView2',
      ),
    ];
    for (final path in candidates) {
      await _deleteDirectoryWithRetry(path);
    }
  }

  static Future<void> _deleteDirectoryWithRetry(String path, {int attempts = 2}) async {
    final directory = Directory(path);
    if (!await directory.exists()) return;
    for (var i = 0; i < attempts; i++) {
      try {
        await directory.delete(recursive: true);
        return;
      } on FileSystemException catch (error) {
        if (i == attempts - 1) {
          debugPrint('[WebView2] Startup cleanup failed for $path: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
  }

  /// 已就绪的共享环境；未初始化或初始化失败时为 null（回退插件默认行为）。
  static WebViewEnvironment? get optional => _environment;

  static Future<void> ensureInitialized() async {
    if (kIsWeb || !Platform.isWindows) return;
    if (_environment != null) return;
    final initializing = _initializing;
    if (initializing != null) return initializing;

    final task = _create();
    _initializing = task;
    try {
      await task;
    } finally {
      if (identical(_initializing, task)) _initializing = null;
    }
  }

  static Future<void> _create() async {
    try {
      final userDataFolder = p.join(AppPathManager().basePath, dirName);
      await Directory(userDataFolder).create(recursive: true);
      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: userDataFolder),
      );
    } catch (error) {
      _environment = null;
      debugPrint('[WebView2] Shared WebViewEnvironment creation failed: $error');
    }
  }

  static Future<void> dispose() async {
    if (_environment == null) return;
    try {
      await _environment!.dispose();
    } catch (error) {
      debugPrint('[WebView2] Environment dispose failed: $error');
    }
    _environment = null;
  }
}
