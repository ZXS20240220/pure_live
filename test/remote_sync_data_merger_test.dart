import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_data_merger.dart';

/// 模拟上游 Android 端导出的关注房间条目（完整字段，含 fork 不认识的
/// catchUpMode / httpHeaders 等扩展字段）。
Map<String, dynamic> upstreamRoom({
  String roomId = '9999',
  String title = '上游标题',
  String tag = '',
}) {
  return <String, dynamic>{
    'roomId': roomId,
    'userId': null,
    'title': title,
    'nick': 'yyfyyf',
    'avatar': 'https://example/avatar.jpg',
    'cover': 'https://example/cover.avif',
    'area': 'DOTA2',
    'watching': '3735341',
    'audienceMetricType': 'popularity',
    'popularity': '3735341',
    'onlineViewers': '',
    'totalViewers': '',
    'followers': '0',
    'platform': 'douyu',
    'tagIds': tag.isEmpty ? <String>[] : <String>[tag],
    'liveStatus': 0,
    'isRecord': false,
    'status': true,
    'notice': '',
    'introduction': '',
    'epgId': null,
    'currentProgramme': null,
    'currentProgrammeDescription': null,
    'catchUpUrl': null,
    'isCatchUp': false,
    'catchUpStart': null,
    'catchUpEnd': null,
    'catchUpMode': 'live',
    'httpHeaders': <String, dynamic>{},
    'lastWatchedAt': null,
  };
}

/// 模拟 Windows fork 持久化的精简房间条目（LiveRoom.toJson 输出）。
Map<String, dynamic> forkRoom({
  String roomId = '9999',
  String title = '本地标题',
  String nick = 'yyfyyf',
  List<String> tagIds = const <String>['tag1'],
  int? lastWatchedAt = 1789635207334,
  String platform = 'douyu',
}) {
  return <String, dynamic>{
    'roomId': roomId,
    'userId': '',
    'title': title,
    'nick': nick,
    'platform': platform,
    'audienceMetricType': 'popularity',
    'tagIds': tagIds,
    'epgId': '',
    'currentProgramme': '',
    'currentProgrammeDescription': '',
    'lastWatchedAt': lastWatchedAt,
  };
}

Map<String, dynamic> buildLocalSnapshot() {
  return <String, dynamic>{
    'backupVersion': 3,
    'sensitiveDataIncluded': true,
    'app': <String, dynamic>{'autoRefreshTime': 5, 'forkOnlySetting': true},
    'favorite': <String, dynamic>{
      'shieldList': <String>['广告'],
      'blockedDanmakuUsers': <String>[],
      'hotAreasList': <String>['douyu', 'bilibili'],
      'preferPlatform': 'douyu',
      'favoriteRooms': <Map<String, dynamic>>[forkRoom()],
      'favoriteAreas': <Map<String, dynamic>>[],
      'watchDurations': <String, dynamic>{'douyu:9999': 120},
    },
    'history': <String, dynamic>{'historyRooms': <Map<String, dynamic>>[], 'historyLimit': 50},
  };
}

Map<String, dynamic> buildUpstreamRaw() {
  return <String, dynamic>{
    'backupVersion': 3,
    'sensitiveDataIncluded': true,
    'app': <String, dynamic>{'autoRefreshTime': 3, 'upstreamOnlySetting': 'x'},
    'favorite': <String, dynamic>{
      'shieldList': <String>[],
      'blockedDanmakuUsers': <String>[],
      'hotAreasList': <String>['douyu'],
      'preferPlatform': 'bilibili',
      'favoriteRooms': <Map<String, dynamic>>[
        upstreamRoom(),
        upstreamRoom(roomId: '8888', title: '仅上游的房间'),
      ],
      'favoriteAreas': <Map<String, dynamic>>[],
    },
    'history': <String, dynamic>{'historyRooms': <Map<String, dynamic>>[], 'historyLimit': 50},
    'upstreamFutureModule': <String, dynamic>{'whatever': 1},
  };
}

void main() {
  group('RemoteSyncDataMerger.analyze', () {
    test('标记上游独有房间字段与未知模块', () {
      final report = RemoteSyncDataMerger.analyze(buildUpstreamRaw(), buildLocalSnapshot());

      expect(report.unknownModules, contains('upstreamFutureModule'));

      final favoriteUnknown = report.unknownFields['favorite']!;
      expect(favoriteUnknown, contains('favoriteRooms[].catchUpMode'));
      expect(favoriteUnknown, contains('favoriteRooms[].httpHeaders'));
      // 上游 app 块中本地没有的键也要标记。
      expect(report.unknownFields['app'], contains('upstreamOnlySetting'));
    });

    test('两端结构一致时不产生未知标记', () {
      final report = RemoteSyncDataMerger.analyze(buildLocalSnapshot(), buildLocalSnapshot());
      expect(report.hasUnknown, isFalse);
    });
  });

  group('RemoteSyncDataMerger.normalizeForLocalApply（接收方向）', () {
    test('只保留选中模块与本端认识的字段，保留 backupVersion', () {
      final raw = buildUpstreamRaw();
      final local = buildLocalSnapshot();

      final normalized = RemoteSyncDataMerger.normalizeForLocalApply(raw, {
        'favorite',
        'upstreamFutureModule',
      }, local);

      expect(normalized['backupVersion'], 3);
      expect(normalized.containsKey('upstreamFutureModule'), isFalse);

      final favorite = normalized['favorite'] as Map<String, dynamic>;
      expect(favorite.containsKey('watchDurations'), isFalse);

      final rooms = favorite['favoriteRooms'] as List;
      expect(rooms.length, 2);
      final first = rooms.first as Map<String, dynamic>;
      // 本端认识的字段保留（用于 LiveRoom.fromJson 解析）。
      expect(first['cover'], 'https://example/cover.avif');
      expect(first['liveStatus'], 0);
      // 本端不认识的字段被过滤。
      expect(first.containsKey('catchUpMode'), isFalse);
      expect(first.containsKey('httpHeaders'), isFalse);
    });

    test('勾选 windowSize 时附带过滤后的 player 块供 extractConfig 读取', () {
      final raw = buildUpstreamRaw();
      raw['player'] = <String, dynamic>{'rememberPipPosition': false};

      final normalized = RemoteSyncDataMerger.normalizeForLocalApply(raw, {
        'windowSize',
      }, buildLocalSnapshot());

      expect(normalized['player'], isA<Map>());
    });
  });

  group('RemoteSyncDataMerger.buildReturnPayload（回传方向）', () {
    test('同房间以对方条目为底稿、本地对应字段覆盖、未知字段保持原样', () {
      final payload = RemoteSyncDataMerger.buildReturnPayload(buildUpstreamRaw(), {
        'favorite',
      }, buildLocalSnapshot());

      // 未选中模块原样保留。
      expect(payload['upstreamFutureModule'], buildUpstreamRaw()['upstreamFutureModule']);
      expect((payload['app'] as Map)['upstreamOnlySetting'], 'x');
      // favorite 块中本地未覆盖的键保持对方原值（hotAreasList 不覆盖）。
      final favorite = payload['favorite'] as Map<String, dynamic>;
      expect(favorite['hotAreasList'], <String>['douyu']);
      expect(favorite['preferPlatform'], 'douyu');

      final rooms = favorite['favoriteRooms'] as List;
      expect(rooms.length, 2, reason: '仅上游存在的房间应保持原样');

      final merged = rooms.first as Map<String, dynamic>;
      // 对方独有字段保持原样。
      expect(merged['avatar'], 'https://example/avatar.jpg');
      expect(merged['cover'], 'https://example/cover.avif');
      expect(merged['catchUpMode'], 'live');
      expect(merged['watching'], '3735341');
      // 本地有值的对应字段覆盖。
      expect(merged['title'], '本地标题');
      expect(merged['tagIds'], <String>['tag1']);
      expect(merged['lastWatchedAt'], 1789635207334);
      // 本地空值（userId/epgId 空串）不覆盖对方原值。
      expect(merged['userId'], isNull);
      expect(merged['epgId'], isNull);
    });

    test('仅本地存在的房间按对方格式补齐后追加', () {
      final raw = buildUpstreamRaw();
      final local = buildLocalSnapshot();
      (local['favorite'] as Map)['favoriteRooms'] = <Map<String, dynamic>>[
        forkRoom(roomId: '7777', platform: 'huya', title: '本地新房间'),
      ];

      final payload = RemoteSyncDataMerger.buildReturnPayload(raw, {'favorite'}, local);
      final rooms = (payload['favorite'] as Map)['favoriteRooms'] as List;

      expect(rooms.length, 3, reason: '上游两个房间保持 + 本地新房间追加');
      final added = rooms.last as Map<String, dynamic>;
      expect(added['roomId'], '7777');
      expect(added['platform'], 'huya');
      expect(added['title'], '本地新房间');
      // 对方格式默认值补齐。
      expect(added['userId'], isNull);
      expect(added['watching'], '0');
      expect(added['followers'], '0');
      expect(added['liveStatus'], 1);
      expect(added['status'], isFalse);
      expect(added['cover'], '');
      expect(added['tagIds'], <String>['tag1']);
      // 上游语义不明的扩展字段不臆造。
      expect(added.containsKey('catchUpMode'), isFalse);
      expect(added.containsKey('httpHeaders'), isFalse);
    });

    test('原始数据不被就地修改', () {
      final raw = buildUpstreamRaw();
      final before = RemoteSyncDataMerger.deepCopy(raw);

      RemoteSyncDataMerger.buildReturnPayload(raw, {'favorite'}, buildLocalSnapshot());

      expect(raw, before);
    });

    test('sensitiveDataIncluded 与回传内容保持一致', () {
      final raw = buildUpstreamRaw()..remove('webdav');
      final payload = RemoteSyncDataMerger.buildReturnPayload(raw, {
        'favorite',
      }, buildLocalSnapshot());
      expect(payload['sensitiveDataIncluded'], isFalse);

      raw['webdav'] = <String, dynamic>{'url': 'https://dav'};
      final payload2 = RemoteSyncDataMerger.buildReturnPayload(raw, {
        'favorite',
      }, buildLocalSnapshot());
      expect(payload2['sensitiveDataIncluded'], isTrue);
    });

    test('普通模块只覆盖对方已有的键，不写入本地独有键', () {
      final payload = RemoteSyncDataMerger.buildReturnPayload(buildUpstreamRaw(), {
        'app',
      }, buildLocalSnapshot());

      final app = payload['app'] as Map<String, dynamic>;
      expect(app['autoRefreshTime'], 5, reason: '对应字段用本地值覆盖');
      expect(app['upstreamOnlySetting'], 'x', reason: '对方独有键保持原样');
      expect(app.containsKey('forkOnlySetting'), isFalse, reason: '本地独有键不写入');
    });

    test('history 模块按房间身份合并并覆盖上限', () {
      final raw = buildUpstreamRaw();
      (raw['history'] as Map)['historyRooms'] = <Map<String, dynamic>>[upstreamRoom()];
      final local = buildLocalSnapshot();
      (local['history'] as Map)['historyRooms'] = <Map<String, dynamic>>[forkRoom()];
      (local['history'] as Map)['historyLimit'] = 30;

      final payload = RemoteSyncDataMerger.buildReturnPayload(raw, {'history'}, local);
      final history = payload['history'] as Map<String, dynamic>;

      expect(history['historyLimit'], 30);
      final rooms = history['historyRooms'] as List;
      expect(rooms.length, 1);
      expect((rooms.first as Map)['title'], '本地标题');
      expect((rooms.first as Map)['cover'], 'https://example/cover.avif');
    });
  });

  group('mergeModuleFromLocal / restoreModuleFromRaw（预览页勾选交互）', () {
    test('勾选单模块与 buildReturnPayload 单模块结果一致，且不修改底稿', () {
      final base = RemoteSyncDataMerger.deepCopy(buildUpstreamRaw()) as Map<String, dynamic>;
      final before = RemoteSyncDataMerger.deepCopy(base);

      final merged = RemoteSyncDataMerger.mergeModuleFromLocal(
        base: base,
        moduleKey: 'favorite',
        localSnapshot: buildLocalSnapshot(),
      );

      expect(base, before, reason: '入参底稿不被就地修改');

      final viaFull = RemoteSyncDataMerger.buildReturnPayload(buildUpstreamRaw(), {
        'favorite',
      }, buildLocalSnapshot());
      expect(merged['favorite'], viaFull['favorite'], reason: '与全量回传路径的单模块行为一致');
    });

    test('取消勾选恢复对方原始值，其他模块保持合并后状态', () {
      final local = buildLocalSnapshot();
      final merged = RemoteSyncDataMerger.mergeModuleFromLocal(
        base: buildUpstreamRaw(),
        moduleKey: 'app',
        localSnapshot: local,
      );

      final restored = RemoteSyncDataMerger.restoreModuleFromRaw(
        base: merged,
        moduleKey: 'app',
        raw: buildUpstreamRaw(),
      );

      expect(restored['app'], buildUpstreamRaw()['app']);
      // restore 只动目标模块。
      expect(identical(restored, merged), isFalse);
    });

    test('底稿缺失该模块时 favorite 按对方格式重建', () {
      final base = buildUpstreamRaw()..remove('favorite');

      final merged = RemoteSyncDataMerger.mergeModuleFromLocal(
        base: base,
        moduleKey: 'favorite',
        localSnapshot: buildLocalSnapshot(),
      );

      final favorite = merged['favorite'] as Map<String, dynamic>;
      final rooms = favorite['favoriteRooms'] as List;
      expect(rooms, isNotEmpty);
      expect(rooms.first, isA<Map>());
      // 重建条目走"对方格式补齐"，不含 fork 独有字段。
      expect((rooms.first as Map).containsKey('catchUpMode'), isFalse);
    });

    test('未知模块即使被调用也保持原样', () {
      final base = buildUpstreamRaw();

      final merged = RemoteSyncDataMerger.mergeModuleFromLocal(
        base: base,
        moduleKey: 'upstreamFutureModule',
        localSnapshot: buildLocalSnapshot(),
      );

      expect(merged['upstreamFutureModule'], buildUpstreamRaw()['upstreamFutureModule']);
    });
  });
}
