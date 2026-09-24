import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../common/binary_writer.dart';

import 'package:pure_live/core/common/core_log.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/core/common/web_socket_util.dart';
import 'package:pure_live/core/interface/live_danmaku.dart';

class DouyuDanmaku implements LiveDanmaku {
  DouyuDanmaku({bool Function()? filterSuspectedAutomatedMessages, bool Function()? filterActivityMessages})
    : _filterSuspectedAutomatedMessages = filterSuspectedAutomatedMessages ?? (() => true),
      _filterActivityMessages = filterActivityMessages ?? (() => true);

  final bool Function() _filterSuspectedAutomatedMessages;
  final bool Function() _filterActivityMessages;

  @override
  int heartbeatTime = 45 * 1000;
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  void markConnected() {
    _connected = true;
  }

  @override
  void markDisconnected() {
    _connected = false;
  }

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onReconnect;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;
  // ignore: unused_field
  String _roomId = '';
  int _generation = 0;

  // A price=0 SC is a real, displayable message (inherently free, or free
  // via deduction — Douyu web shows both as free). For such an SC Douyu may
  // push a redundant companion event right after it: same sender and
  // content but carrying the pre-deduction price (>0). Displaying that
  // companion makes the SC appear twice, so shown price=0 SCs are
  // remembered for a short window and an identical price>0 packet within
  // the window is suppressed. A price>0 packet without a remembered twin
  // is a normal paid SC and is displayed as-is.
  static const Duration _defaultSuperChatDedupWindow = Duration(seconds: 5);
  Duration _superChatDedupWindow = _defaultSuperChatDedupWindow;
  final List<_RecentFreeSuperChat> _recentFreeSuperChats = [];
  Timer? _recentSuperChatTimer;

  @visibleForTesting
  void debugSetRoomId(String roomId) => _roomId = roomId;

  @visibleForTesting
  void debugSetSuperChatDedupWindow(Duration window) => _superChatDedupWindow = window;

  @override
  Future start(dynamic args) async {
    final generation = ++_generation;
    _resetRecentFreeSuperChats();
    await webScoketUtils?.close();
    webScoketUtils = null;
    if (generation != _generation) return;
    _roomId = args.toString();
    markDisconnected();
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        if (generation == _generation) decodeMessage(e);
      },
      onReady: () {
        if (generation != _generation) return;
        markConnected();
        onReady?.call();
        joinRoom(args);
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        if (generation != _generation) return;
        markDisconnected();
        onReconnect?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        if (generation != _generation) return;
        markDisconnected();
        onClose?.call("服务器连接失败$e");
      },
    );
    await webScoketUtils?.connect();
  }

  void joinRoom(dynamic roomId) {
    webScoketUtils?.sendMessage(serializeDouyu("type@=loginreq/roomid@=$roomId/"));
    webScoketUtils?.sendMessage(serializeDouyu("type@=joingroup/rid@=$roomId/gid@=-9999/"));
  }

  @override
  void heartbeat() {
    var data = serializeDouyu("type@=mrkl/");
    webScoketUtils?.sendMessage(data);
  }

  @override
  Future stop() async {
    _generation++;
    _resetRecentFreeSuperChats();
    markDisconnected();
    onMessage = null;
    onReconnect = null;
    onClose = null;
    onReady = null;
    await webScoketUtils?.close();
    webScoketUtils = null;
  }

  void decodeMessage(List<int> data) {
    for (final result in deserializeDouyuPackets(data)) {
      try {
        final jsonData = sttToJObject(result);
        if (jsonData is! Map) continue;

        final type = jsonData["type"]?.toString();
        LiveMessage? liveMsg;
        if (type == "chatmsg") {
          final packetRoomId = jsonData['rid']?.toString() ?? '';
          if (packetRoomId.isNotEmpty && _roomId.isNotEmpty && packetRoomId != _roomId) continue;
          final text = jsonData["txt"]?.toString() ?? '';
          if (text.isEmpty) continue;
          if (_filterActivityMessages()) {
            final gadid = jsonData['gadid']?.toString();
            if (gadid != null && gadid.isNotEmpty) continue;
          }
          final isSuspectedAutomated = jsonData['dms'] == null && jsonData['if']?.toString() != '1';
          if (isSuspectedAutomated && _filterSuspectedAutomatedMessages()) continue;
          final col = int.tryParse(jsonData["col"]?.toString() ?? '') ?? 0;
          final rawTimestamp = int.tryParse(jsonData['cst']?.toString() ?? '');
          final sentAt = rawTimestamp == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(rawTimestamp > 100000000000 ? rawTimestamp : rawTimestamp * 1000);
          final messageId = jsonData['cid']?.toString() ?? '';
          final rawFansName = jsonData['bnn']?.toString() ?? '';
          final rawFansLevel = jsonData['bl']?.toString() ?? '';
          // A fan level is meaningful on its own: the badge name (bnn) is
          // optional because wearing the medal is a per-user choice.
          final fansLevel = (rawFansLevel.isNotEmpty && rawFansLevel != '0') ? rawFansLevel : '';
          liveMsg = LiveMessage(
            type: LiveMessageType.chat,
            userName: jsonData["nn"]?.toString() ?? '',
            userId: jsonData['uid']?.toString() ?? '',
            message: text,
            color: getColor(col),
            messageId: messageId.isEmpty ? '' : 'douyu:$messageId',
            sentAt: sentAt,
            userLevel: jsonData['level']?.toString() ?? '',
            fansName: rawFansName,
            fansLevel: fansLevel,
          );
        } else if (type == "comm_chatmsg") {
          liveMsg = _parseCommonSuperChat(jsonData);
        } else if (type == "voice_trlt") {
          liveMsg = _parseVoiceSuperChat(jsonData);
        }
        if (liveMsg == null) continue;
        if (liveMsg.type == LiveMessageType.superChat) {
          _dispatchSuperChat(liveMsg);
        } else {
          onMessage?.call(liveMsg);
        }
      } catch (e) {
        // One malformed packet must not discard the valid packets coalesced
        // after it in the same WebSocket frame.
        CoreLog.error("Douyu packet parse failed: $e");
      }
    }
  }

  LiveMessage? _parseCommonSuperChat(Map jsonData) {
    final chat = jsonData["chatmsg"];
    final now = int.tryParse(jsonData["now"]?.toString() ?? '');
    final duration = int.tryParse(jsonData["cet"]?.toString() ?? '');
    final rawPrice = int.tryParse(jsonData["cprice"]?.toString() ?? '');
    if (chat is! Map || now == null || duration == null || rawPrice == null) return null;
    // price=0 is a real SC (inherently free or free via deduction) and is
    // displayed immediately; the redundant price>0 companion of the same SC
    // is suppressed by _dispatchSuperChat instead.
    final face = chat["ic"]?.toString() ?? '';
    final startTime = DateTime.fromMillisecondsSinceEpoch(now);
    final superChat = LiveSuperChatMessage(
      backgroundBottomColor: "#292a60",
      backgroundColor: "#c1c1ff",
      endTime: startTime.add(Duration(seconds: duration)),
      face: face.isEmpty ? '' : "https://apic.douyucdn.cn/upload/${face}_small.jpg",
      message: chat["txt"]?.toString() ?? '',
      price: rawPrice ~/ 100,
      startTime: startTime,
      userName: chat["nn"]?.toString() ?? '',
    );
    return _superChatMessage(superChat);
  }

  LiveMessage? _parseVoiceSuperChat(Map jsonData) {
    final list = jsonData["list"];
    if (list is! List || list.isEmpty || list.first is! Map) return null;
    final scData = list.first as Map;
    final endSeconds = int.tryParse(scData["etime"]?.toString() ?? '');
    final startSeconds = int.tryParse(scData["acptime"]?.toString() ?? '');
    final rawPrice = int.tryParse(scData["realPrice"]?.toString() ?? '');
    if (endSeconds == null || startSeconds == null || rawPrice == null) return null;
    final avatars = scData["uat"];
    final avatar = avatars is List && avatars.length > 1 ? avatars[1].toString() : '';
    final superChat = LiveSuperChatMessage(
      backgroundBottomColor: "#246488",
      backgroundColor: "#ffffff",
      endTime: DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000),
      face: avatar.isEmpty ? '' : "https://$avatar",
      message: scData["content"]?.toString() ?? '',
      price: rawPrice ~/ 100,
      startTime: DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000),
      userName: scData["un"]?.toString() ?? '',
    );
    return _superChatMessage(superChat);
  }

  LiveMessage _superChatMessage(LiveSuperChatMessage data) {
    return LiveMessage(
      type: LiveMessageType.superChat,
      userName: "SUPER_CHAT_MESSAGE",
      message: "SUPER_CHAT_MESSAGE",
      color: LiveMessageColor.white,
      data: data,
    );
  }

  void _dispatchSuperChat(LiveMessage msg) {
    final sc = msg.data as LiveSuperChatMessage;
    if (sc.price == 0) {
      // Display immediately — a price=0 SC is the actual message (inherently
      // free or free via deduction). Remember it so the redundant price>0
      // companion of the same SC can be recognized and suppressed.
      _recentFreeSuperChats.add(_RecentFreeSuperChat(msg, DateTime.now().add(_superChatDedupWindow)));
      _scheduleRecentSuperChatExpiry();
      onMessage?.call(msg);
      return;
    }
    // A price>0 packet identical to a just-shown price=0 SC is that SC's
    // redundant companion event (same sender and content, pre-deduction
    // price), not a separate message — suppress it. The most recent twin is
    // consumed (LIFO) so a later genuine paid SC with the same content is
    // displayed instead of being swallowed. Without a twin it is a normal
    // paid SC.
    final index = _recentFreeSuperChats.lastIndexWhere((recent) => _isSameSuperChatContent(recent.message, msg));
    if (index == -1) {
      onMessage?.call(msg);
      return;
    }
    _recentFreeSuperChats.removeAt(index);
    if (_recentFreeSuperChats.isEmpty) {
      _recentSuperChatTimer?.cancel();
      _recentSuperChatTimer = null;
    }
  }

  bool _isSameSuperChatContent(LiveMessage a, LiveMessage b) {
    final pa = a.data as LiveSuperChatMessage;
    final pb = b.data as LiveSuperChatMessage;
    return pa.userName == pb.userName && pa.message == pb.message;
  }

  void _scheduleRecentSuperChatExpiry() {
    if (_recentFreeSuperChats.isEmpty) {
      _recentSuperChatTimer?.cancel();
      _recentSuperChatTimer = null;
      return;
    }
    // The timer always targets the earliest deadline. New deadlines are
    // strictly later (now + window), so an existing timer stays correct.
    if (_recentSuperChatTimer != null) return;
    final now = DateTime.now();
    final earliest = _recentFreeSuperChats.map((recent) => recent.deadline).reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = earliest.difference(now);
    _recentSuperChatTimer = Timer(delay.isNegative ? Duration.zero : delay, _expireRecentFreeSuperChats);
  }

  void _expireRecentFreeSuperChats() {
    _recentSuperChatTimer = null;
    final now = DateTime.now();
    _recentFreeSuperChats.removeWhere((recent) => !recent.deadline.isAfter(now));
    _scheduleRecentSuperChatExpiry();
  }

  void _resetRecentFreeSuperChats() {
    _recentSuperChatTimer?.cancel();
    _recentSuperChatTimer = null;
    _recentFreeSuperChats.clear();
  }

  List<int> serializeDouyu(String body) {
    try {
      const int clientSendToServer = 689;
      const int encrypted = 0;
      const int reserved = 0;

      List<int> buffer = utf8.encode(body);

      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(clientSendToServer, 2, endian: Endian.little);
      writer.writeInt(encrypted, 1, endian: Endian.little);
      writer.writeInt(reserved, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    final packets = deserializeDouyuPackets(buffer);
    return packets.isEmpty ? null : packets.first;
  }

  /// One WebSocket frame commonly carries several complete Douyu packets.
  /// Iterate by each packet's own length instead of silently dropping every
  /// packet after the first.
  List<String> deserializeDouyuPackets(List<int> buffer) {
    final packets = <String>[];
    try {
      final bytes = Uint8List.fromList(buffer);
      var offset = 0;
      while (offset + 12 <= bytes.length) {
        final header = ByteData.sublistView(bytes, offset, offset + 4);
        final fullMsgLength = header.getUint32(0, Endian.little);
        final frameLength = fullMsgLength + 4;
        final bodyLength = fullMsgLength - 9;
        if (fullMsgLength < 9 || bodyLength < 0 || offset + frameLength > bytes.length) break;
        final bodyStart = offset + 12;
        final bodyEnd = bodyStart + bodyLength;
        packets.add(utf8.decode(bytes.sublist(bodyStart, bodyEnd), allowMalformed: true));
        offset += frameLength;
      }
    } catch (e) {
      CoreLog.error(e);
    }
    return packets;
  }

  //辣鸡STT
  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split('/')) {
        if (field.isEmpty) {
          continue;
        }
        final separator = field.indexOf("@=");
        if (separator <= 0) continue;
        var k = field.substring(0, separator);
        var v = unscapeSlashAt(field.substring(separator + 2));
        result[k] = sttToJObject(v);
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}

/// A displayed price=0 super chat remembered so the redundant price>0
/// companion of the same SC can be suppressed, see [_dispatchSuperChat].
class _RecentFreeSuperChat {
  _RecentFreeSuperChat(this.message, this.deadline);

  final LiveMessage message;
  final DateTime deadline;
}
