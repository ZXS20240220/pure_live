import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../common/binary_writer.dart';

import 'package:pure_live/core/common/core_log.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/core/common/web_socket_util.dart';
import 'package:pure_live/core/interface/live_danmaku.dart';
import 'package:pure_live/core/site/douyu/douyu_utils.dart';

class DouyuDanmaku with DouyuVoiceTrltAware implements LiveDanmaku {
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

  // 同一条醒目留言斗鱼会推送两份实时报告：comm_chatmsg 的 cprice 是抵扣前
  // 标价，voice_trlt 的 realPrice 是实付价（抵扣/打折后可能为 0）。两份
  // 报告不保证先后、间隔实测可达 1 分钟。处理策略是“先到先显示”，孪生
  // 报告到达时就地更新同一张卡，价格取实付价并附带标价。配对记忆保留至
  // SC endTime，因此断线重连重放也会合并为同一张卡。
  final Map<String, _RecentSuperChatReport> _recentSuperChats = {};
  Timer? _recentSuperChatTimer;

  @visibleForTesting
  void debugSetRoomId(String roomId) => _roomId = roomId;

  @visibleForTesting
  void debugDispatchSuperChat(LiveSuperChatMessage sc, {required bool isRealPriceEvent}) {
    _dispatchSuperChat(_superChatMessage(sc), isRealPriceEvent: isRealPriceEvent);
  }

  @override
  Future start(dynamic args) async {
    final generation = ++_generation;
    _resetRecentSuperChats();
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
    _resetRecentSuperChats();
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
        var isRealPriceSuperChat = false;
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
          isRealPriceSuperChat = true;
          onVoiceTrltReceived?.call();
        }
        if (liveMsg == null) continue;
        if (liveMsg.type == LiveMessageType.superChat) {
          _dispatchSuperChat(liveMsg, isRealPriceEvent: isRealPriceSuperChat);
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
    final face = chat["ic"]?.toString() ?? '';
    final startTime = DateTime.fromMillisecondsSinceEpoch(now);
    final userName = chat["nn"]?.toString() ?? '';
    final message = chat["txt"]?.toString() ?? '';
    final listPrice = rawPrice ~/ 100;
    final superChat = LiveSuperChatMessage(
      messageId: DouyuUtils.superChatCoalesceId(
        roomId: _roomId,
        userName: userName,
        message: message,
        startTime: startTime,
      ),
      backgroundBottomColor: "#292a60",
      backgroundColor: "#c1c1ff",
      endTime: startTime.add(Duration(seconds: duration)),
      face: face.isEmpty ? '' : "https://apic.douyucdn.cn/upload/${face}_small.jpg",
      message: message,
      price: listPrice,
      listPrice: listPrice,
      startTime: startTime,
      userName: userName,
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
    final userName = scData["un"]?.toString() ?? '';
    final message = scData["content"]?.toString() ?? '';
    final realPrice = rawPrice ~/ 100;
    final startTime = DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000);
    final superChat = LiveSuperChatMessage(
      messageId: DouyuUtils.superChatCoalesceId(
        roomId: _roomId,
        userName: userName,
        message: message,
        startTime: startTime,
      ),
      backgroundBottomColor: "#246488",
      backgroundColor: "#ffffff",
      endTime: DateTime.fromMillisecondsSinceEpoch(endSeconds * 1000),
      face: avatar.isEmpty ? '' : "https://$avatar",
      message: message,
      price: realPrice,
      startTime: startTime,
      userName: userName,
    );
    return _superChatMessage(superChat);
  }

  LiveMessage _superChatMessage(LiveSuperChatMessage data) {
    return LiveMessage(
      type: LiveMessageType.superChat,
      userName: "SUPER_CHAT_MESSAGE",
      message: "SUPER_CHAT_MESSAGE",
      color: LiveMessageColor.white,
      messageId: data.messageId,
      data: data,
    );
  }

  void _dispatchSuperChat(LiveMessage msg, {required bool isRealPriceEvent}) {
    final sc = msg.data as LiveSuperChatMessage;
    final id = sc.messageId;
    final previous = _recentSuperChats[id];

    if (previous == null) {
      // 先到先显示：不等待孪生事件，SC 无显示延迟。
      _recentSuperChats[id] = _RecentSuperChatReport(
        deadline: sc.endTime,
        realPrice: isRealPriceEvent ? sc.price : null,
        listPrice: isRealPriceEvent ? null : sc.price,
      );
      _scheduleRecentSuperChatExpiry();
      onMessage?.call(msg);
      return;
    }

    // 孪生报告到达：合并标价/实付价，就地更新同一张卡。
    final realPrice = isRealPriceEvent ? sc.price : previous.realPrice;
    final listPrice = isRealPriceEvent ? previous.listPrice : sc.price;
    _recentSuperChats[id] = _RecentSuperChatReport(
      deadline: sc.endTime.isAfter(previous.deadline) ? sc.endTime : previous.deadline,
      realPrice: realPrice,
      listPrice: listPrice,
    );
    _scheduleRecentSuperChatExpiry();

    final effectivePrice = realPrice ?? listPrice ?? sc.price;
    final merged = sc.copyWith(
      price: effectivePrice,
      listPrice: listPrice != null && listPrice != effectivePrice ? listPrice : null,
    );
    onMessage?.call(_superChatMessage(merged));
  }

  void _scheduleRecentSuperChatExpiry() {
    if (_recentSuperChats.isEmpty) {
      _recentSuperChatTimer?.cancel();
      _recentSuperChatTimer = null;
      return;
    }
    _recentSuperChatTimer?.cancel();
    final now = DateTime.now();
    final earliest = _recentSuperChats.values.map((report) => report.deadline).reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = earliest.difference(now);
    _recentSuperChatTimer = Timer(delay.isNegative ? Duration.zero : delay, _expireRecentSuperChats);
  }

  void _expireRecentSuperChats() {
    _recentSuperChatTimer = null;
    final now = DateTime.now();
    _recentSuperChats.removeWhere((_, report) => !report.deadline.isAfter(now));
    _scheduleRecentSuperChatExpiry();
  }

  void _resetRecentSuperChats() {
    _recentSuperChatTimer?.cancel();
    _recentSuperChatTimer = null;
    _recentSuperChats.clear();
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

/// 同一条 SC 已显示报告的配对记忆：标价来自 comm_chatmsg，实付价来自
/// voice_trlt，任一可能为 null（对应事件尚未到达或平台未推送）。
class _RecentSuperChatReport {
  _RecentSuperChatReport({required this.deadline, this.realPrice, this.listPrice});

  final DateTime deadline;
  final int? realPrice;
  final int? listPrice;
}
