/// 远程同步数据合并器。
///
/// 本端（Windows 基础版）与同步对端（官方上游 / Windows 开发版）的备份数据
/// 结构存在双向差异：
/// - 上游与开发版拥有本端 LiveRoom.fromJson 不解析的房间字段
///   （如 anchorLevel/unionName/startTime/location/aiHighlights）；
/// - 本端已合并上游的时移与 IPTV 请求头字段
///   （catchUpMode/catchUpSource/catchUpDays/catchUpCorrectionHours/httpHeaders），
///   对端可能不认识这些字段。
///
/// 同步策略（以目标端的数据结构为准）：
/// - 接收方向（对方 → 本地应用）：把对方数据块过滤成本端认识的字段后，
///   通过 BackupController.importPartialSettings 覆盖选中的模块；
///   本端完全不认识的模块与字段仅标记，不写入。
/// - 回传方向（本地 → 对方）：以对方原始数据为底稿深拷贝，选中模块做
///   覆盖同步——数据内容以本端为准（房间列表整体替换为本端列表，对方
///   独有条目删除），数据结构以对方为准（条目字段集按对方 JSON 中实际
///   出现的字段动态对齐：对方没有的键不写入，本端没有的键留空补齐）。
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

  /// 本端 exportAllSettings 会输出的全部模块键。
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
  static const Map<String, String> roomListKeyByModule = {'favorite': 'favoriteRooms', 'history': 'historyRooms'};

  /// 本端 LiveRoom.fromJson 认识的全部房间字段。
  ///
  /// 与 Windows 开发版不同：本端不解析 anchorLevel/unionName/startTime/
  /// location/aiHighlights（来自对方也不会应用），但已合并上游的
  /// catchUpMode/catchUpSource/catchUpDays/catchUpCorrectionHours/httpHeaders。
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
    'platform',
    'tagIds',
    'liveStatus',
    'status',
    'notice',
    'introduction',
    'isRecord',
    'epgId',
    'currentProgramme',
    'currentProgrammeDescription',
    'catchUpUrl',
    'isCatchUp',
    'catchUpStart',
    'catchUpEnd',
    'catchUpMode',
    'catchUpSource',
    'catchUpDays',
    'catchUpCorrectionHours',
    'httpHeaders',
    'lastWatchedAt',
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
  /// - hotAreasList 不覆盖：两端支持的平台集合不同步，各端本地目录自治理。
  static const Set<String> favoriteOverlayKeys = {
    'shieldList',
    'blockedDanmakuUsers',
    'preferPlatform',
    'favoriteAreas',
  };

  // ---------------------------------------------------------------------------
  // 分析：标记未知模块与未知字段
  // ---------------------------------------------------------------------------

  static RemoteSyncMergeReport analyze(Map<String, dynamic> raw, Map<String, dynamic> localSnapshot) {
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
      final localPlayerKeys = localPlayer is Map ? localPlayer.keys.whereType<String>().toSet() : null;
      out['player'] = _filterMapByKnownKeys(Map<String, dynamic>.from(raw['player'] as Map), localPlayerKeys);
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
    payload['sensitiveDataIncluded'] = payload.containsKey('webdav') || payload.containsKey('cookie');

    return payload;
  }

  // ---------------------------------------------------------------------------
  // 交互式合并（预览页勾选 / 取消勾选单个数据块时使用）
  // ---------------------------------------------------------------------------

  /// 把单个模块从本地快照覆盖同步到底稿上，返回新 Map，不修改 [base]。
  ///
  /// 覆盖语义：数据内容以本端为准，数据结构以对方为准——
  /// - favorite/history：房间列表整体替换为本端列表（逐条按对方格式
  ///   重建，对方独有条目不保留；列表条目是可变数据，增删不破坏结构）；
  /// - 普通模块：对方块中与本端同名的键用本端值覆盖，对方独有键保持
  ///   原样（对方功能配置不被破坏），本端独有键不写入对方数据。
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
        // 本地独有键（本端扩展）不写入对方数据。
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

  static Map<String, dynamic> _mergeFavoriteBlock(Map<String, dynamic> base, Map<String, dynamic> local) {
    final merged = Map<String, dynamic>.from(base);

    for (final key in favoriteOverlayKeys) {
      if (!local.containsKey(key)) continue;
      merged[key] = deepCopy(local[key]);
    }

    final mergedRooms = _mergeRoomList(base['favoriteRooms'], local['favoriteRooms']);
    if (mergedRooms != null) merged['favoriteRooms'] = mergedRooms;

    return merged;
  }

  static Map<String, dynamic> _mergeHistoryBlock(Map<String, dynamic> base, Map<String, dynamic> local) {
    final merged = Map<String, dynamic>.from(base);

    // 历史条数上限两端语义一致，属于对应字段。
    if (local.containsKey('historyLimit')) {
      merged['historyLimit'] = local['historyLimit'];
    }

    final mergedRooms = _mergeRoomList(base['historyRooms'], local['historyRooms']);
    if (mergedRooms != null) merged['historyRooms'] = mergedRooms;

    return merged;
  }

  /// 房间列表覆盖同步（数据内容以本端为准，数据结构以对方为准）：
  /// - 数据结构动态判断：目标端条目字段集 = [baseRooms]（对方 JSON）中
  ///   实际出现的字段并集，而不是硬编码模板——对方没有的键（如本端 toJson
  ///   输出的 anchorLevel/location）不会写入，对方独有的键按"留空"补齐；
  /// - 数据内容以本端为准：输出列表 = 本端列表逐条按上述字段集重建，
  ///   顺序与本端一致，对方独有的条目不保留（列表条目是可变数据，
  ///   多一个少一个直播间只是数据不同，不破坏数据结构）。
  static List<dynamic>? _mergeRoomList(dynamic baseRooms, dynamic localRooms) {
    if (localRooms is! List) return null;

    // 对方条目字段并集；对方列表为空/无效时回退到硬编码模板键集。
    final targetKeys = <String>{};
    if (baseRooms is List) {
      for (final room in baseRooms) {
        if (room is! Map) continue;
        targetKeys.addAll(room.keys.whereType<String>());
      }
    }

    final merged = <dynamic>[];
    for (final item in localRooms) {
      if (item is! Map) continue;
      merged.add(buildRoomEntryForTarget(Map<String, dynamic>.from(item), targetKeys));
    }

    return merged;
  }

  /// 本端值是否值得写入重建的条目。
  /// 空串/null/空列表视为"本端没有数据"，保留模板默认值（即"留空"）。
  static bool _shouldOverlay(dynamic value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) return value.isNotEmpty;
    return true;
  }

  /// 按"对方的数据格式"重建一个房间条目（覆盖同步的条目级实现）。
  ///
  /// 数据结构以对方为准、动态判断：输出条目只含 [targetKeys]（对方 JSON
  /// 条目中实际出现的字段并集）内的键——本端 toJson 输出但对方没有的键
  /// （如 anchorLevel/location）不会泄漏进去，对方有而本端条目没有的键
  /// 留空补齐。[targetKeys] 为空时（对方列表无有效条目）回退到模板键集。
  ///
  /// 数据内容以本端为准：本端值仅在有意义时写入，否则取模板默认值
  /// （模板缺省的对方特有键填 null，即"补不上就留空"）。模板保留
  /// 上游 LiveRoom.toJson 的输出集合与默认值，仅作为回退依据；本端已
  /// 合并的时移字段（catchUpMode 等）在模板中列出但不会主动写入——
  /// 只有对方条目里实际出现时才会带上。
  static Map<String, dynamic> buildRoomEntryForTarget(Map<String, dynamic> localRoom, Set<String> targetKeys) {
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
      'catchUpMode': null,
      'catchUpSource': null,
      'catchUpDays': null,
      'catchUpCorrectionHours': null,
      'httpHeaders': null,
      'lastWatchedAt': null,
    };

    // 目标端字段集：对方 JSON 条目实际字段并集；为空时回退模板键集。
    final keys = targetKeys.isNotEmpty ? targetKeys : template.keys.toSet();

    final out = <String, dynamic>{};
    for (final key in keys) {
      final localValue = localRoom[key];
      if (_shouldOverlay(localValue)) {
        out[key] = deepCopy(localValue);
      } else if (template.containsKey(key)) {
        out[key] = template[key];
      } else {
        // 对方特有键且本端没有数据：留空。
        out[key] = null;
      }
    }

    return out;
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
  static Map<String, dynamic> _filterMapByKnownKeys(Map<String, dynamic> map, Set<String>? knownFields) {
    if (knownFields == null) return Map<String, dynamic>.from(map);
    return Map<String, dynamic>.fromEntries(map.entries.where((entry) => knownFields.contains(entry.key)));
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
