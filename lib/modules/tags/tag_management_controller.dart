import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/tags/live_tag.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';

class TagManagementController extends GetxController {
  static const String _storageKey = 'user_custom_tags_v5';
  static const String _roomTagsMappingKey = 'room_to_tags_mapping_v1';
  final RxMap<String, List<String>> roomTagsMap = <String, List<String>>{}.obs;
  final RxList<LiveTag> tags = <LiveTag>[].obs;
  static const Map<String, String> allTag = {'all': '全部'};

  static const String untaggedTagKey = '__untagged__';
  static const String untaggedTagLabel = '无标签';

  static const Set<String> reservedTagNames = {'无标签', '全部', 'all', 'untagged'};

  static String get allTagKey => allTag.keys.first;
  static String get allTagLabel => allTag.values.first;

  @override
  void onInit() {
    super.onInit();
    _loadTags();
    _invalidateValidIdsCache();
    _loadRoomTagsMapping();
    _sanitizeRoomTagsMap();
  }

  void _loadTags() {
    final List<dynamic>? storedTags = HivePrefUtil.getAnyPref(_storageKey);
    if (storedTags != null) {
      final list = storedTags.map((e) => LiveTag.fromJson(Map<String, dynamic>.from(e))).toList();
      list.sort((a, b) => a.order.compareTo(b.order));
      tags.assignAll(list);
    } else {
      tags.clear();
    }
  }

  Future<void> saveTags() async {
    await HivePrefUtil.setAnyPref(_storageKey, tags.map((e) => e.toJson()).toList());
  }

  Future<void> saveRoomTagsMapping() async {
    await HivePrefUtil.setAnyPref(_roomTagsMappingKey, roomTagsMap);
  }

  void _loadRoomTagsMapping() {
    final Map<dynamic, dynamic>? storedMap = HivePrefUtil.getAnyPref(_roomTagsMappingKey);
    if (storedMap != null) {
      final convertedMap = storedMap.map((key, value) {
        return MapEntry(key.toString(), List<String>.from(value as List));
      });
      roomTagsMap.assignAll(convertedMap);
    }
  }

  void _sanitizeRoomTagsMap() {
    if (roomTagsMap.isEmpty) return;
    final validTagIds = tags.map((t) => t.id).toSet();
    var changed = false;
    for (final key in List<String>.from(roomTagsMap.keys)) {
      final ids = roomTagsMap[key];
      if (ids == null) {
        roomTagsMap.remove(key);
        changed = true;
        continue;
      }
      final valid = ids.where((id) => validTagIds.contains(id)).toList();
      if (valid.length != ids.length) {
        changed = true;
        if (valid.isEmpty) {
          roomTagsMap.remove(key);
        } else {
          roomTagsMap[key] = valid;
        }
      }
    }
    if (changed) {
      roomTagsMap.refresh();
      saveRoomTagsMapping();
    }
  }

  void setRoomTags(LiveRoom room, List<String> newTagIds) {
    final roomKey = room.identityKey;
    final legacyKey = room.normalizedRoomId;
    var mapChanged = false;

    if (newTagIds.isEmpty) {
      if (roomTagsMap.remove(roomKey) != null) mapChanged = true;
      if (legacyKey.isNotEmpty && legacyKey != roomKey) {
        if (roomTagsMap.remove(legacyKey) != null) mapChanged = true;
      }
    } else {
      roomTagsMap[roomKey] = List<String>.from(newTagIds);
      mapChanged = true;
      if (legacyKey.isNotEmpty && legacyKey != roomKey && roomTagsMap.containsKey(legacyKey)) {
        roomTagsMap.remove(legacyKey);
        mapChanged = true;
      }
    }

    if (mapChanged) {
      roomTagsMap.refresh();
      saveRoomTagsMapping();
    }
  }

  void migrateLegacyRoomTagKeys(Iterable<LiveRoom> rooms) {
    var changed = false;
    final migratedLegacyKeys = <String>{};
    for (final room in rooms) {
      final legacyKey = room.normalizedRoomId;
      if (legacyKey.isEmpty || room.normalizedPlatformId.isEmpty) continue;
      final legacyTags = roomTagsMap[legacyKey];
      if (legacyTags == null) continue;
      roomTagsMap.putIfAbsent(room.identityKey, () => List<String>.from(legacyTags));
      migratedLegacyKeys.add(legacyKey);
      changed = true;
    }
    for (final key in migratedLegacyKeys) {
      roomTagsMap.remove(key);
    }
    if (!changed) return;
    roomTagsMap.refresh();
    saveRoomTagsMapping();
  }

  List<String> getTagsForRoom(LiveRoom room) {
    final ids = roomTagsMap[room.identityKey] ?? roomTagsMap[room.normalizedRoomId] ?? <String>[];
    if (ids.isEmpty) return <String>[];
    final validIds = _cachedValidIds;
    if (validIds.isEmpty) return <String>[];
    return ids.where((id) => validIds.contains(id)).toList();
  }

  Set<String> _cachedValidIds = {};

  void _invalidateValidIdsCache() {
    _cachedValidIds = tags.map((t) => t.id).toSet();
  }

  String? get pinTagId => tags.isEmpty ? null : tags.first.id;

  bool isPinRoom(LiveRoom room) {
    final pinId = pinTagId;
    if (pinId == null) return false;
    return getTagsForRoom(room).contains(pinId);
  }

  bool addTag(String name, String description) {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return false;
    if (reservedTagNames.contains(cleanName.toLowerCase())) return false;

    final exists = tags.any((tag) => tag.name.toLowerCase() == cleanName.toLowerCase());
    if (exists) return false;

    final newTag = LiveTag(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: cleanName,
      description: description.trim(),
      order: tags.length,
    );

    tags.add(newTag);
    _invalidateValidIdsCache();
    saveTags();
    return true;
  }

  LiveTag? findTagByName(String name) {
    final cleanName = name.trim().toLowerCase();
    if (cleanName.isEmpty) return null;
    if (reservedTagNames.contains(cleanName)) return null;
    for (final tag in tags) {
      if (tag.name.trim().toLowerCase() == cleanName) return tag;
    }
    return null;
  }

  LiveTag? ensureTagByNameSafe(String name) {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return null;
    if (reservedTagNames.contains(cleanName.toLowerCase())) return null;
    final existing = findTagByName(cleanName);
    if (existing != null) return existing;
    final newTag = LiveTag(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: cleanName,
      description: '',
      order: tags.length,
    );
    tags.add(newTag);
    _invalidateValidIdsCache();
    saveTags();
    return newTag;
  }

  LiveTag ensureTagByName(String name) {
    final cleanName = name.trim();
    final existing = findTagByName(cleanName);
    if (existing != null) return existing;
    final newTag = LiveTag(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: cleanName,
      description: '',
      order: tags.length,
    );
    tags.add(newTag);
    _invalidateValidIdsCache();
    saveTags();
    return newTag;
  }

  void updateAllTags(List<LiveTag> newList) {
    tags.assignAll(newList);
    for (int i = 0; i < tags.length; i++) {
      tags[i].order = i;
    }
    tags.refresh();
    _invalidateValidIdsCache();
    saveTags();
  }

  bool updateTag(int index, String newName, String newDescription) {
    final cleanName = newName.trim();
    if (cleanName.isEmpty) return false;
    if (reservedTagNames.contains(cleanName.toLowerCase())) return false;

    if (tags[index].name != cleanName) {
      final exists = tags.any((tag) => tag.name.toLowerCase() == cleanName.toLowerCase());
      if (exists) return false;
    }

    tags[index].name = cleanName;
    tags[index].description = newDescription.trim();
    tags.refresh();
    _invalidateValidIdsCache();
    saveTags();
    return true;
  }

  void pinToTop(int index) {
    if (index <= 0 || index >= tags.length) return;
    final targetTag = tags.removeAt(index);
    tags.insert(0, targetTag);
    _refreshSequentialOrders();
  }

  void togglePinStatus(int index) {
    _refreshSequentialOrders();
  }

  void deleteTag(int index) {
    if (index < 0 || index >= tags.length) return;
    final removed = tags.removeAt(index);
    var mapChanged = false;
    for (final roomKey in List<String>.from(roomTagsMap.keys)) {
      final ids = roomTagsMap[roomKey];
      if (ids == null || !ids.contains(removed.id)) continue;
      ids.remove(removed.id);
      mapChanged = true;
      if (ids.isEmpty) {
        roomTagsMap.remove(roomKey);
      }
    }
    if (mapChanged) {
      roomTagsMap.refresh();
      saveRoomTagsMapping();
    }
    _invalidateValidIdsCache();
    _refreshSequentialOrders();
  }

  void _refreshSequentialOrders() {
    for (int i = 0; i < tags.length; i++) {
      tags[i].order = i;
    }
    tags.refresh();
    saveTags();
  }

  Map<String, dynamic> exportToJson() {
    return {'tags': tags.map((e) => e.toJson()).toList(), 'roomTagsMap': roomTagsMap};
  }

  void importFromJson(Map<String, dynamic>? json) {
    if (json == null) return;

    if (json.containsKey('tags') && json['tags'] != null) {
      final storedTags = json['tags'] as List;
      final list = storedTags.map((e) => LiveTag.fromJson(Map<String, dynamic>.from(e))).toList();
      list.sort((a, b) => a.order.compareTo(b.order));
      tags.assignAll(list);
      _invalidateValidIdsCache();
      saveTags();
    }

    if (json.containsKey('roomTagsMap') && json['roomTagsMap'] != null) {
      final storedMap = json['roomTagsMap'] as Map;
      final convertedMap = storedMap.map((key, value) {
        return MapEntry(key.toString(), List<String>.from(value as List));
      });
      roomTagsMap.assignAll(convertedMap);
      _sanitizeRoomTagsMap();
      saveRoomTagsMapping();
    }
  }
}
