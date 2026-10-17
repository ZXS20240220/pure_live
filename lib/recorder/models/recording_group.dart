import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_live/recorder/models/live_record_task.dart';

class Mp4Entry {
  Mp4Entry({
    required this.path,
    required this.platform,
    required this.safeNick,
    required this.modified,
    required this.size,
  });

  final String path;
  final String platform;
  final String safeNick;
  final DateTime modified;
  final int size;

  String? originalNick;
  String? cover;
  String? avatar;
  String? title;

  static String sidecarPathForDirectory(String dir) => p.join(dir, 'recording_meta.json');

  void mergeTask(LiveRecordTask task) {
    originalNick = _pick(originalNick, task.nick);
    cover = _pick(cover, task.cover);
    avatar = _pick(avatar, task.avatar);
    title = _pick(title, task.title);
  }

  Future<void> mergeSidecar() async {
    if (cover != null && avatar != null && originalNick != null) return;
    final sidecar = File(sidecarPathForDirectory(p.dirname(path)));
    if (!await sidecar.exists()) return;
    try {
      final content = await sidecar.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      originalNick = _pick(originalNick, json['nick'] as String?);
      cover = _pick(cover, json['cover'] as String?);
      avatar = _pick(avatar, json['avatar'] as String?);
      title = _pick(title, json['title'] as String?);
    } catch (_) {}
  }

  static String? _pick(String? existing, String? incoming) {
    if (existing != null && existing.isNotEmpty) return existing;
    if (incoming != null && incoming.isNotEmpty) return incoming;
    return existing;
  }

  String get displayNick => originalNick ?? safeNick;
}

class HostRecordingGroup {
  HostRecordingGroup({required this.platform, required this.safeNick});

  final String platform;
  final String safeNick;
  final List<Mp4Entry> mp4s = [];

  DateTime get latestModified =>
      mp4s.fold(DateTime.fromMillisecondsSinceEpoch(0), (prev, e) => e.modified.isAfter(prev) ? e.modified : prev);

  String get displayNick {
    for (final e in mp4s) {
      if (e.originalNick != null) return e.originalNick!;
    }
    return safeNick;
  }

  String? get cover {
    for (final e in mp4s) {
      if (e.cover != null && e.cover!.isNotEmpty) return e.cover;
    }
    return null;
  }

  String? get avatar {
    for (final e in mp4s) {
      if (e.avatar != null && e.avatar!.isNotEmpty) return e.avatar;
    }
    return null;
  }

  String get latestTitle {
    final latest = mp4s.reduce((a, b) => a.modified.isAfter(b.modified) ? a : b);
    return latest.title ?? '本地录制';
  }
}
