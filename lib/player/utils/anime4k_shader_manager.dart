import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/common/global/app_path_manager.dart';
import 'package:pure_live/core/common/log.dart';
import 'package:pure_live/player/utils/player_consts.dart';

/// 管理 Anime4K GLSL 着色器：从 assets 提取到磁盘，供 mpv `glsl-shaders` 选项使用。
///
/// mpv 的 glsl-shaders 只接受文件系统路径，不接受 Flutter asset key，
/// 因此必须把 assets/shaders/*.glsl 复制到应用数据目录后再交给 mpv。
abstract final class Anime4KShaderManager {
  static const String _assetBase = 'assets/shaders';

  /// 将所需的着色器文件从 assets 提取到 [AppPathManager.shadersDir]，
  /// 返回可直接传给 mpv `glsl-shaders` 的绝对路径列表（按挂载顺序）。
  ///
  /// - [quality] 为 'high' 时使用 [PlayerConsts.mpvAnime4KShaders]，
  ///   为 'lite'（或其他值）时使用 [PlayerConsts.mpvAnime4KShadersLite]。
  /// - 若任一 shader asset 缺失，返回空列表，由调用方决定是否开启。
  static Future<List<String>> resolveShaderPaths({required String quality}) async {
    final shaderList = quality == 'high' ? PlayerConsts.mpvAnime4KShaderKeys : PlayerConsts.mpvAnime4KShadersLiteKeys;

    final targetDir = await AppPathManager().shadersDir;
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final paths = <String>[];
    for (final shaderName in shaderList) {
      final assetKey = '$_assetBase/$shaderName';
      final targetFile = File(p.join(targetDir.path, shaderName));

      // 目标文件已存在且非空则直接复用，避免每次开流都写盘。
      if (await targetFile.exists() && await targetFile.length() > 0) {
        paths.add(targetFile.path);
        continue;
      }

      try {
        final bytes = await rootBundle.load(assetKey);
        await targetFile.writeAsBytes(bytes.buffer.asUint8List());
        paths.add(targetFile.path);
      } catch (e) {
        // 着色器文件缺失（用户未在 assets/shaders 放入 Anime4K），
        // 返回空列表让调用方关闭 glsl-shaders。
        Log.w('[Anime4K] failed to load shader asset: $assetKey, error: $e');
        return const <String>[];
      }
    }
    return paths;
  }
}
