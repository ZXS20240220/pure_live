import 'dart:math' as math;

import 'package:pure_live/common/models/live_message.dart';

/// 进程内的斗鱼 SC 本地缓存（按房间维度维护）。
///
/// 设计目标——
/// - 实时推送或历史回填拿到的 SC 一旦入库，同一房间内直接复用，不再依赖
///   远程接口；退出直播间后只要 SC 未到期就继续保留；
/// - 到期（endTime 已过）的条目在读写时自动剔除；
/// - 仅存活于当前进程：退出程序即丢弃，不做任何持久化。
class DouyuSuperChatCache {
  DouyuSuperChatCache._();

  static final Map<String, List<LiveSuperChatMessage>> _cache = <String, List<LiveSuperChatMessage>>{};

  /// 将单条 SC 合并进目标列表：同身份条目就地合并（实付价取最小、标价取
  /// 最大、endTime 取较晚、头像回填空缺），新条目追加。
  ///
  /// UI 列表与本地缓存共用该规则，保证两边展示与留存一致。
  /// 合并身份与 [LiveSuperChatMessage.==] 一致（messageId 优先，内容兜底）。
  static void mergeItem(List<LiveSuperChatMessage> merged, LiveSuperChatMessage item) {
    final index = merged.indexWhere((existing) => existing == item);
    if (index == -1) {
      merged.add(item);
      return;
    }
    final existing = merged[index];
    final listCandidates = <int>[
      existing.price,
      item.price,
      if (existing.listPrice != null) existing.listPrice!,
      if (item.listPrice != null) item.listPrice!,
    ];
    merged[index] = existing.copyWith(
      price: math.min(existing.price, item.price),
      listPrice: listCandidates.reduce(math.max),
      endTime: item.endTime.isAfter(existing.endTime) ? item.endTime : existing.endTime,
      face: existing.face.isEmpty ? item.face : existing.face,
    );
  }

  /// 读取房间的缓存 SC（已剔除过期项）。无缓存或全部过期返回空列表；
  /// 顺带清理空房间，避免 Map 随房间数无限增长。
  static List<LiveSuperChatMessage> get(String roomId) {
    final list = _cache[roomId];
    if (list == null || list.isEmpty) return const <LiveSuperChatMessage>[];
    _pruneExpired(roomId, list);
    return List<LiveSuperChatMessage>.unmodifiable(list);
  }

  /// 合并一批 SC 到指定房间的缓存。
  static void merge(String roomId, Iterable<LiveSuperChatMessage> items) {
    if (items.isEmpty) return;
    final list = _cache.putIfAbsent(roomId, () => <LiveSuperChatMessage>[]);
    for (final item in items) {
      mergeItem(list, item);
    }
    _pruneExpired(roomId, list);
  }

  // 剔除到期条目（与 UI 的 _removeExpiredSuperChats 同一判定：endTime 已过即到期）。
  static void _pruneExpired(String roomId, List<LiveSuperChatMessage> list) {
    final now = DateTime.now().millisecondsSinceEpoch;
    list.removeWhere((x) => x.endTime.millisecondsSinceEpoch <= now);
    if (list.isEmpty) _cache.remove(roomId);
  }
}
