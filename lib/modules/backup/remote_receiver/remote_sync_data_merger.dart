/// 远程同步数据合并器。
///
/// Windows fork 与官方上游（Android 端）的备份数据结构存在双向差异：
/// - fork 精简了关注/历史房间条目（LiveRoom.toJson 只输出少量字段）；
/// - 上游反而拥有 fork 不认识的字段（如 catchUpMode/catchUpSource 等）。
///
/// 同步策略（以目标端的数据结构为准）：
/// - 接收方向（对方 → 本地应用）：把对方数据块过滤成本端认识的字段后，
///   通过 BackupController.importPartialSettings 覆盖选中的模块；
///   本端完全不认识的模块与字段仅标记，不写入。
/// - 回传方向（本地 → 对方）：以对方原始数据为底稿深拷贝，只把选中模块中
///   "对方也存在的对应字段"用本地值覆盖；房间条目按 platform+roomId 逐条合并，
///   对方独有的字段一律保持原样，本地独有的房间以对方格式补齐后追加。
///
/// 本文件刻意不依赖任何 Flutter/GetX 类型，便于单元测试。
class RemoteSyncMergeReport {
  /// 对方数据里本端完全不认识的顶层模块（原样保留，双向都不动）。
  final Set<String> unknownModules;

  /// 模块键 -> 本端不认识的字段路径（如 favoriteRooms[].catchUpMode）。
  final Map<String, Set<String>> unknownFields;

  RemoteSyncMergeReport({required this.unknownModules, required this.unknownFields});

  bool get hasUnknown => unknownModules.isNotEmpty || unknownFields.isNotEmpty;
}

class RemoteSyncDataMerger {
  RemoteSyncDataMerger._();

  // ---------------------------------------------------------------------------
  // Schema 常量
  // ---------------------------------------------------------------------------

  /// 备份元数据键，不属于任何模块。
  static const Set<String> metadataKeys = {'backupVersion', 'sensitiveDataIncluded'};

  /// 本端（fork）exportAllSettings 会输出的全部模块键。
  static const Set<String> knownModules = {
    'app',
    'theme',
    'font',
    'player',
    'danmaku',
    'volume',
    'favorite',
    'history',
    'webdav',
    'cookie',
    'iptv',
    'proxy',
    'windowSize',
    'exit',
    'startup',
    'refresh',
    'page',
    'panelSize',
    'roomCard',
    'tags',
    'favoriteCtrl',
    'backupDirectory',
  };

  /// 房间条目所在模块 -> 房间列表的键名。
  static const Map<String, String> roomListKeyByModule = {
    'favorite': 'favoriteRooms',
    'history': 'historyRooms',
  };

  /// 本端 LiveRoom.fromJson 认识的全部房间字段。
  /// 上游多出的字段（catchUpMode/catchUpSource/catchUpDays/
  /// catchUpCorrectionHours/httpHeaders）不在此列，会按"未知字段"处理。
  static const Set<String> knownRoomFields = {
    'roomId',
    'userId',
    'link',
    'title',
    'nick',
    'avatar',
    'cover',
    'area',
    'watching',
    'audienceMetricType',
    'popularity',
    'onlineViewers',
    'totalViewers',
    'followers',
    'anchorLevel',
    'unionName',
    'platform',
    'tagIds',
    'liveStatus',
    'status',
    'notice',
    'aiHighlights',
    'introduction',
    'isRecord',
    'epgId',
    'currentProgramme',
    'currentProgrammeDescription',
    'catchUpUrl',
    'isCatchUp',
    'catchUpStart',
    'catchUpEnd',
    'lastWatchedAt',
    'startTime',
    'location',
  };

  /// LiveArea 序列化字段（两端一致）。
  static const Set<String> knownAreaFields = {
    'platform',
    'areaType',
    'typeName',
    'areaId',
    'areaName',
    'areaPic',
    'shortName',
  };

  /// 收藏块中可直接用本地值覆盖的对应字段。
  /// - hotAreasList 不覆盖：两端支持的平台集合不同步，各端本地目录自治理；
  /// - watchDurations 是 fork 扩展，上游没有对应字段，不写入。
  static const Set<String> favoriteOverlayKeys = {
    'shieldList',
    'blockedDanmakuUsers',
    'preferPlatform',
    'favoriteAreas',
  };

  // ---------------------------------------------------------------------------
  // 分析：标记未知模块与未知字段
  // ---------------------------------------------------------------------------

  static RemoteSyncMergeReport analyze(
    Map<String, dynamic> raw,
    Map<String, dynamic> localSnapshot,
  ) {
    final unknownModules = <String>{};
    final unknownFields = <String, Set<String>>{};

    for (final key in raw.keys) {
      if (metadataKeys.contains(key) || knownModules.contains(key)) continue;
      unknownModules.add(key);
    }

    void markUnknown(String module, String fieldPath) {
      unknownFields.putIfAbsent(module, () => <String>{}).add(fieldPath);
    }

    for (final entry in raw.entries) {
      final moduleKey = entry.key;
      final moduleValue = entry.value;
      if (moduleValue is! Map || !knownModules.contains(moduleKey)) continue;
      final block = Map<String, dynamic>.from(moduleValue);
      final localBlock = localSnapshot[moduleKey];
      final localKeys = localBlock is Map ? localBlock.keys.toSet() : null;

      final roomListKey = roomListKeyByModule[moduleKey];

      for (final field in block.keys) {
        if (field == roomListKey) {
          // 房间列表：逐条检查条目字段。
          final rooms = block[field];
          if (rooms is List) {
            for (final room in rooms) {
              if (room is! Map) continue;
              for (final roomField in room.keys) {
                if (!knownRoomFields.contains(roomField)) {
                  markUnknown(moduleKey, '$field[].$roomField');
                }
              }
            }
          }
          continue;
        }

        if (moduleKey == 'favorite' && field == 'favoriteAreas') {
          final areas = block[field];
          if (areas is List) {
            for (final area in areas) {
              if (area is! Map) continue;
              for (final areaField in area.keys) {
                if (!knownAreaFields.contains(areaField)) {
                  markUnknown(moduleKey, '$field[].$areaField');
                }
              }
            }
          }
          continue;
        }

        // 普通字段：以本地导出块的字段集合为"本端认识"的依据。
        if (localKeys != null && !localKeys.contains(field)) {
          markUnknown(moduleKey, field);
        }
      }
    }

    return RemoteSyncMergeReport(unknownModules: unknownModules, unknownFields: unknownFields);
  }

  // ---------------------------------------------------------------------------
  // 接收方向：把对方数据归一化为本端结构后交给 importPartialSettings
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> normalizeForLocalApply(
    Map<String, dynamic> raw,
    Set<String> selectedKeys,
    Map<String, dynamic> localSnapshot,
  ) {
    final out = <String, dynamic>{};

    // 版本号必须携带，importPartialSettings 依赖它选择导入路径。
    if (raw['backupVersion'] != null) {
      out['backupVersion'] = raw['backupVersion'];
    }

    for (final key in selectedKeys) {
      // 本端不认识的模块双向都不动，即使被误选也跳过。
      if (!knownModules.contains(key)) continue;
      if (!raw.containsKey(key)) continue;
      final value = raw[key];

      if (key == 'backupDirectory') {
        if (value is String) out[key] = value;
        continue;
      }

      if (value is! Map) {
        out[key] = value;
        continue;
      }

      final block = Map<String, dynamic>.from(value);
      final localBlock = localSnapshot[key];
      final localKeys = localBlock is Map ? localBlock.keys.toSet() : null;
      final roomListKey = roomListKeyByModule[key];

      final normalizedBlock = <String, dynamic>{};

      for (final field in block.keys) {
        if (roomListKey != null && field == roomListKey) {
          normalizedBlock[field] = _filterRoomList(block[field]);
          continue;
        }

        if (key == 'favorite' && field == 'favoriteAreas') {
          normalizedBlock[field] = _filterObjectList(block[field], knownAreaFields);
          continue;
        }

        // 只保留本端认识的字段（以本地导出块为 schema 依据）。
        if (localKeys != null && !localKeys.contains(field)) continue;
        normalizedBlock[field] = block[field];
      }

      out[key] = normalizedBlock;
    }

    // windowSize 的导入会经由 extractConfig 回读 player 块中的
    // rememberPipPosition（旧版字段位置）。当用户只勾选 windowSize 时，
    // 附带过滤后的 player 块仅供读取；它不在 allowedKeys 中，不会被导入。
    if (selectedKeys.contains('windowSize') && !out.containsKey('player') && raw['player'] is Map) {
      final localPlayer = localSnapshot['player'];
      final localPlayerKeys = localPlayer is Map
          ? localPlayer.keys.whereType<String>().toSet()
          : null;
      out['player'] = _filterMapByKnownKeys(
        Map<String, dynamic>.from(raw['player'] as Map),
        localPlayerKeys,
      );
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // 回传方向：以对方原始数据为底稿，仅覆盖选中模块的对应字段
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> buildReturnPayload(
    Map<String, dynamic> raw,
    Set<String> selectedKeys,
    Map<String, dynamic> localSnapshot,
  ) {
    // 深拷贝底稿：对方未选中的模块、未知模块、未知字段全部原样保留。
    var payload = deepCopy(raw) as Map<String, dynamic>;

    for (final key in selectedKeys) {
      // 本端不认识的模块双向都不动，即使被误选也跳过。
      if (!knownModules.contains(key)) continue;
      payload = mergeModuleFromLocal(base: payload, moduleKey: key, localSnapshot: localSnapshot);
    }

    // 若回传内容包含敏感块，同步修正标记，保持与内容一致。
    payload['sensitiveDataIncluded'] =
        payload.containsKey('webdav') || payload.containsKey('cookie');

    return payload;
  }

  // ---------------------------------------------------------------------------
  // 交互式合并（预览页勾选 / 取消勾选单个数据块时使用）
  // ---------------------------------------------------------------------------

  /// 把单个模块从本地快照合并到底稿上，返回新 Map，不修改 [base]。
  ///
  /// 与 [buildReturnPayload] 的单模块行为保持一致；当底稿缺失该模块
  /// （理论上仅出现在数据被人为改动过的情况）时按对方格式重建该块。
  static Map<String, dynamic> mergeModuleFromLocal({
    required Map<String, dynamic> base,
    required String moduleKey,
    required Map<String, dynamic> localSnapshot,
  }) {
    final payload = deepCopy(base) as Map<String, dynamic>;
    if (!knownModules.contains(moduleKey)) return payload;

    if (moduleKey == 'backupDirectory') {
      final localValue = localSnapshot[moduleKey];
      if (localValue is String) payload[moduleKey] = localValue;
      return payload;
    }

    if (localSnapshot[moduleKey] is! Map) return payload;

    final localBlock = Map<String, dynamic>.from(localSnapshot[moduleKey] as Map);

    if (payload[moduleKey] is! Map) {
      // 底稿缺失或非法：favorite/history 按对方格式重建，普通模块整块注入。
      switch (moduleKey) {
        case 'favorite':
          payload[moduleKey] = _mergeFavoriteBlock(const {}, localBlock);
          break;
        case 'history':
          payload[moduleKey] = _mergeHistoryBlock(const {}, localBlock);
          break;
        default:
          payload[moduleKey] = deepCopy(localBlock);
      }
      return payload;
    }

    final baseBlock = Map<String, dynamic>.from(payload[moduleKey] as Map);
    switch (moduleKey) {
      case 'favorite':
        payload[moduleKey] = _mergeFavoriteBlock(baseBlock, localBlock);
        break;
      case 'history':
        payload[moduleKey] = _mergeHistoryBlock(baseBlock, localBlock);
        break;
      default:
        // 普通模块：只覆盖"对方块中也存在"的键；对方独有键保持原样，
        // 本地独有键（fork 扩展）不写入对方数据。
        for (final field in baseBlock.keys.toList()) {
          if (!localBlock.containsKey(field)) continue;
          baseBlock[field] = deepCopy(localBlock[field]);
        }
        payload[moduleKey] = baseBlock;
    }
    return payload;
  }

  /// 把单个模块恢复为对方原始值，返回新 Map，不修改 [base]。
  static Map<String, dynamic> restoreModuleFromRaw({
    required Map<String, dynamic> base,
    required String moduleKey,
    required Map<String, dynamic> raw,
  }) {
    final payload = deepCopy(base) as Map<String, dynamic>;
    if (!knownModules.contains(moduleKey)) return payload;
    if (raw.containsKey(moduleKey)) {
      payload[moduleKey] = deepCopy(raw[moduleKey]);
    }
    return payload;
  }

  // ---------------------------------------------------------------------------
  // 模块级合并
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _mergeFavoriteBlock(
    Map<String, dynamic> base,
    Map<String, dynamic> local,
  ) {
    final merged = Map<String, dynamic>.from(base);

    for (final key in favoriteOverlayKeys) {
      if (!local.containsKey(key)) continue;
      merged[key] = deepCopy(local[key]);
    }

    final mergedRooms = _mergeRoomList(base['favoriteRooms'], local['favoriteRooms']);
    if (mergedRooms != null) merged['favoriteRooms'] = mergedRooms;

    return merged;
  }

  static Map<String, dynamic> _mergeHistoryBlock(
    Map<String, dynamic> base,
    Map<String, dynamic> local,
  ) {
    final merged = Map<String, dynamic>.from(base);

    // 历史条数上限两端语义一致，属于对应字段。
    if (local.containsKey('historyLimit')) {
      merged['historyLimit'] = local['historyLimit'];
    }

    final mergedRooms = _mergeRoomList(base['historyRooms'], local['historyRooms']);
    if (mergedRooms != null) merged['historyRooms'] = mergedRooms;

    return merged;
  }

  /// 房间列表逐条合并：
  /// - 对方已有该房间：以对方条目为底稿（保留对方全部字段，含未知字段），
  ///   用本地条目中"有意义的值"覆盖对应字段；
  /// - 仅本地存在：按对方格式补齐模板后追加；
  /// - 仅对方存在：保持原样。
  static List<dynamic>? _mergeRoomList(dynamic baseRooms, dynamic localRooms) {
    if (localRooms is! List) return null;

    final merged = baseRooms is List ? deepCopy(baseRooms) as List : <dynamic>[];

    final indexById = <String, int>{};
    for (var i = 0; i < merged.length; i++) {
      final entry = merged[i];
      if (entry is! Map) continue;
      final id = roomIdentity(entry);
      if (id.isEmpty || indexById.containsKey(id)) continue;
      indexById[id] = i;
    }

    for (final item in localRooms) {
      if (item is! Map) continue;
      final localRoom = Map<String, dynamic>.from(item);
      final id = roomIdentity(localRoom);
      if (id.isEmpty) continue;

      final existingIndex = indexById[id];
      if (existingIndex != null) {
        final baseRoom = Map<String, dynamic>.from(merged[existingIndex] as Map);
        for (final entry in localRoom.entries) {
          if (!_shouldOverlay(entry.value)) continue;
          baseRoom[entry.key] = deepCopy(entry.value);
        }
        merged[existingIndex] = baseRoom;
      } else {
        final newRoom = buildRoomEntryForTarget(localRoom);
        merged.add(newRoom);
        indexById[id] = merged.length - 1;
      }
    }

    return merged;
  }

  /// 房间身份键：platform(小写) + roomId，与 LiveRoom.identityKey 语义一致。
  static String roomIdentity(Map<dynamic, dynamic> room) {
    final platform = (room['platform'] ?? '').toString().trim().toLowerCase();
    final roomId = (room['roomId'] ?? '').toString().trim();
    if (platform.isEmpty || roomId.isEmpty) return '';
    return '$platform:$roomId';
  }

  /// 本端值是否值得覆盖到对方数据上。
  /// 空串/null/空列表视为"本端没有数据"，保持对方原值。
  static bool _shouldOverlay(dynamic value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) return value.isNotEmpty;
    return true;
  }

  /// 按"对方的数据格式"补齐一个仅本地存在的房间条目。
  ///
  /// 模板字段来自上游 LiveRoom.toJson 的输出集合；上游 fromJson 对缺失键
  /// 均有默认值回退，语义不明的上游扩展字段（catchUpMode 等）刻意省略。
  /// 本地值仅在有意义时覆盖模板默认值。
  static Map<String, dynamic> buildRoomEntryForTarget(Map<String, dynamic> localRoom) {
    final template = <String, dynamic>{
      'roomId': null,
      'userId': null,
      'title': '',
      'nick': '',
      'avatar': '',
      'cover': '',
      'area': '',
      'watching': '0',
      'audienceMetricType': null,
      'popularity': '',
      'onlineViewers': '',
      'totalViewers': '',
      'followers': '0',
      'platform': '',
      'tagIds': <String>[],
      'liveStatus': 1,
      'isRecord': false,
      'status': false,
      'notice': '',
      'introduction': '',
      'epgId': null,
      'currentProgramme': null,
      'currentProgrammeDescription': null,
      'catchUpUrl': null,
      'isCatchUp': false,
      'catchUpStart': null,
      'catchUpEnd': null,
      'lastWatchedAt': null,
    };

    for (final entry in localRoom.entries) {
      if (!_shouldOverlay(entry.value)) continue;
      template[entry.key] = deepCopy(entry.value);
    }

    return template;
  }

  // ---------------------------------------------------------------------------
  // 通用工具
  // ---------------------------------------------------------------------------

  static List<dynamic> _filterRoomList(dynamic rooms) {
    return _filterObjectList(rooms, knownRoomFields);
  }

  static List<dynamic> _filterObjectList(dynamic list, Set<String> knownFields) {
    if (list is! List) return <dynamic>[];
    final out = <dynamic>[];
    for (final item in list) {
      if (item is! Map) continue;
      final entry = Map<String, dynamic>.from(item);
      out.add(_filterMapByKnownKeys(entry, knownFields));
    }
    return out;
  }

  /// 按 knownFields 过滤 Map；knownFields 为 null 时不做过滤（无法判定 schema）。
  static Map<String, dynamic> _filterMapByKnownKeys(
    Map<String, dynamic> map,
    Set<String>? knownFields,
  ) {
    if (knownFields == null) return Map<String, dynamic>.from(map);
    return Map<String, dynamic>.fromEntries(
      map.entries.where((entry) => knownFields.contains(entry.key)),
    );
  }

  /// JSON 安全深拷贝（Map/List/原始值）。
  ///
  /// Map 分支必须显式产出 `Map<String, dynamic>`：`value is Map` 会把
  /// dynamic 提升为 `Map<dynamic, dynamic>`，不指定类型参数的 `.map()`
  /// 会原样返回 `Map<dynamic, dynamic>`，在调用点隐式下行转换时运行时报错。
  static dynamic deepCopy(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>((k, v) => MapEntry(k.toString(), deepCopy(v)));
    }
    if (value is List) {
      return value.map(deepCopy).toList();
    }
    return value;
  }
}
