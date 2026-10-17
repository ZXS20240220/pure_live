import 'dart:io';

import 'package:xml/xml.dart';

class LocalDanmakuEntry {
  LocalDanmakuEntry({required this.time, required this.text, required this.userName, required this.color});

  final double time;
  final String text;
  final String userName;
  final int color;

  int get r => (color >> 16) & 0xFF;
  int get g => (color >> 8) & 0xFF;
  int get b => color & 0xFF;
}

class LocalDanmakuParser {
  static List<LocalDanmakuEntry> parseFile(String xmlPath) {
    final file = File(xmlPath);
    if (!file.existsSync()) return const [];
    try {
      final content = file.readAsStringSync();
      return parseString(content);
    } catch (_) {
      return const [];
    }
  }

  static List<LocalDanmakuEntry> parseString(String xmlString) {
    final entries = <LocalDanmakuEntry>[];
    try {
      final document = XmlDocument.parse(xmlString);
      final dNodes = document.findAllElements('d');
      for (final node in dNodes) {
        final pAttr = node.getAttribute('p');
        if (pAttr == null || pAttr.isEmpty) continue;
        final parts = pAttr.split(',');
        if (parts.length < 4) continue;
        final time = double.tryParse(parts[0]) ?? 0.0;
        final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
        final userName = node.getAttribute('user') ?? '';
        final text = node.innerText.trim();
        if (text.isEmpty) continue;
        entries.add(LocalDanmakuEntry(time: time, text: text, userName: userName, color: color));
      }
    } catch (_) {}
    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }
}
