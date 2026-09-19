import 'dart:convert';
import 'dart:math' as math;

import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/backup_controller.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_data_merger.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_json_tree.dart';
import 'package:pure_live/modules/backup/remote_receiver/remote_sync_service.dart';

/// 编辑对话框的保存结果；cancelled 为 false 时 value 为用户确认的新值
/// （可能为 null，因此不能直接用可空类型表达）。
class _LeafEditResult {
  const _LeafEditResult(this.value);

  final dynamic value;
}

/// schema 基线缺失的标记（路径不在对方原始数据里，按当前值类型推断）。
class _SchemaAbsent {
  const _SchemaAbsent._();

  static const instance = _SchemaAbsent._();
}

/// 右侧 JSON 的预览模式。
enum _PreviewMode {
  /// 返回配置模式：右侧为对方原始数据 + 勾选模块合并的本地数据 + 手动编辑，
  /// "返回配置给对方"把该内容发送给对方。
  pushBack,

  /// 应用到本地模式：右侧初始为本地完整配置（深拷贝），勾选数据块即把
  /// 归一化后的对方模块数据（自动过滤本端不识别字段）覆盖进预览，
  /// "应用到本地"按当前勾选与预览内容（含手动编辑）应用到本机。
  applyLocal,
}

/// 双模式同步预览页：
/// - 返回配置模式（默认）：右侧"原始 JSON（返回内容）"是返回给对方的唯一依据；
/// - 应用到本地模式：右侧"本地 JSON（应用预览）"是应用到本机的数据依据。
/// 两种模式通过底栏按钮互相切换，切换时清空勾选并按新模式重建 JSON 内容。
class RemoteSyncPreviewPage extends StatefulWidget {
  final String ip;
  final int port;
  final Map<String, dynamic> settings;

  const RemoteSyncPreviewPage({
    super.key,
    required this.ip,
    required this.port,
    required this.settings,
  });

  @override
  State<RemoteSyncPreviewPage> createState() => _RemoteSyncPreviewPageState();
}

class _RemoteSyncPreviewPageState extends State<RemoteSyncPreviewPage> {
  /// 数据块勾选状态，默认全不选（切换模式时重置）。
  late final Map<String, bool> _selections;

  late final Map<String, dynamic> _localSnapshot;
  late final RemoteSyncMergeReport _report;

  /// 当前预览模式。
  _PreviewMode _mode = _PreviewMode.pushBack;

  /// 返回配置模式下右侧"原始 JSON"树的内容，是"返回配置给对方"的唯一依据。
  /// 初始为对方原始数据的深拷贝，保证 widget.settings 不被就地修改。
  late Map<String, dynamic> _payload;

  /// 应用到本地模式下右侧"本地 JSON"预览的内容，是"应用到本地"的数据依据。
  /// 初始为本地快照的深拷贝；勾选数据块后对应模块被归一化的对方数据覆盖。
  late Map<String, dynamic> _applyPayload;

  /// 对方原始数据的叶子类型基线：jsonEncode(path) -> 原始标量值。
  /// 值为 null 表示基线允许任意类型；路径缺失表示无基线（按当前值推断）。
  final Map<String, dynamic> _schema = {};

  final GlobalKey<RemoteSyncJsonTreeState> _treeKey = GlobalKey();

  double _leftFraction = 0.5;
  double? _dragStartX;
  double? _dragStartFraction;
  bool _isApplying = false;
  bool _isPushing = false;

  static const _keyLabels = {
    'app': '应用设置',
    'theme': '主题设置',
    'font': '字体设置',
    'player': '播放器设置',
    'danmaku': '弹幕设置',
    'volume': '音量设置',
    'favorite': '关注列表',
    'history': '观看历史',
    'webdav': 'WebDAV 同步',
    'iptv': 'IPTV 列表',
    'cookie': '登录凭据',
    'proxy': '代理设置',
    'windowSize': '窗口/悬浮窗尺寸',
    'exit': '退出行为',
    'startup': '启动行为',
    'refresh': '刷新配置',
    'page': '页面设置',
    'panelSize': '侧边面板尺寸',
    'roomCard': '房间卡片样式',
    'tags': '标签管理',
    'favoriteCtrl': '关注排序/置顶（扩展）',
    'backupDirectory': '备份目录路径',
  };

  static const _extensionKeys = {'favoriteCtrl', 'panelSize'};

  static const _metadataKeys = {'backupVersion', 'sensitiveDataIncluded'};

  @override
  void initState() {
    super.initState();

    Map<String, dynamic> localSnapshot = {};
    RemoteSyncMergeReport report = RemoteSyncMergeReport(unknownModules: {}, unknownFields: {});

    try {
      localSnapshot = Get.find<BackupController>().exportAllSettings(includeSensitiveData: true);
      report = RemoteSyncDataMerger.analyze(widget.settings, localSnapshot);
    } catch (_) {
      // 本地快照读取失败时退化为不过滤字段，仅保留原有能力。
    }

    _localSnapshot = localSnapshot;
    _report = report;
    _payload = RemoteSyncDataMerger.deepCopy(widget.settings) as Map<String, dynamic>;
    _applyPayload = RemoteSyncDataMerger.deepCopy(_localSnapshot) as Map<String, dynamic>;
    _buildSchema(widget.settings, const <Object>[]);
    _selections = {for (final key in _userVisibleKeys()) key: false};
  }

  /// 当前模式下右侧树展示与编辑的内容。
  Map<String, dynamic> get _currentPayload =>
      _mode == _PreviewMode.applyLocal ? _applyPayload : _payload;

  List<String> _userVisibleKeys() {
    return widget.settings.keys
        .where((k) => !_metadataKeys.contains(k))
        // 本端不识别的数据块不可选：双向都保持原样。
        .where((k) => !_report.unknownModules.contains(k))
        .where((k) => widget.settings[k] is Map || widget.settings[k] is String)
        .toList();
  }

  Set<String> _unknownFieldsOf(String key) => _report.unknownFields[key] ?? const {};

  // ---------------------------------------------------------------------------
  // 数据块勾选 -> 实时更新右侧 JSON 树（按模式分流）
  // ---------------------------------------------------------------------------

  void _refreshSensitiveFlag(Map<String, dynamic> payload) {
    payload['sensitiveDataIncluded'] =
        payload.containsKey('webdav') || payload.containsKey('cookie');
  }

  /// 应用模式：把归一化结果覆盖进本地预览（勾选），或恢复本地原值（取消）。
  /// 覆盖范围是 normalize 输出的全部非元数据键（含 windowSize 附带的
  /// 过滤 player 块），保证"所见即所应用"；取消时跳过仍处于勾选状态的
  /// 模块（如先勾 player 再取消 windowSize，不应重置 player）。
  void _overlayApplyModule(bool value, Map<String, dynamic> normalized) {
    for (final entry in normalized.entries) {
      if (_metadataKeys.contains(entry.key)) continue;
      if (value) {
        _applyPayload[entry.key] = RemoteSyncDataMerger.deepCopy(entry.value);
      } else if (_selections[entry.key] == true) {
        continue;
      } else if (_localSnapshot.containsKey(entry.key)) {
        _applyPayload[entry.key] = RemoteSyncDataMerger.deepCopy(_localSnapshot[entry.key]);
      } else {
        _applyPayload.remove(entry.key);
      }
    }
  }

  void _setSelected(String key, bool value) {
    setState(() {
      _selections[key] = value;

      if (_mode == _PreviewMode.applyLocal) {
        // 单独归一化该模块：本端不认识的字段已被过滤，不会进入预览。
        final normalized = RemoteSyncDataMerger.normalizeForLocalApply(widget.settings, {
          key,
        }, _localSnapshot);
        _overlayApplyModule(value, normalized);
        return;
      }

      final next = value
          ? RemoteSyncDataMerger.mergeModuleFromLocal(
              base: _payload,
              moduleKey: key,
              localSnapshot: _localSnapshot,
            )
          : RemoteSyncDataMerger.restoreModuleFromRaw(
              base: _payload,
              moduleKey: key,
              raw: widget.settings,
            );
      _refreshSensitiveFlag(next);
      _payload = next;
    });
  }

  void _selectAll(bool value) {
    setState(() {
      if (_mode == _PreviewMode.applyLocal) {
        for (final key in _selections.keys.toList()) {
          _selections[key] = value;
          final normalized = RemoteSyncDataMerger.normalizeForLocalApply(widget.settings, {
            key,
          }, _localSnapshot);
          _overlayApplyModule(value, normalized);
        }
        return;
      }

      var next = _payload;
      for (final key in _selections.keys.toList()) {
        _selections[key] = value;
        next = value
            ? RemoteSyncDataMerger.mergeModuleFromLocal(
                base: next,
                moduleKey: key,
                localSnapshot: _localSnapshot,
              )
            : RemoteSyncDataMerger.restoreModuleFromRaw(
                base: next,
                moduleKey: key,
                raw: widget.settings,
              );
      }
      _refreshSensitiveFlag(next);
      _payload = next;
    });
  }

  // ---------------------------------------------------------------------------
  // 模式切换与重置：都清空勾选，并按当前模式重建 JSON 内容
  // ---------------------------------------------------------------------------

  /// 切换返回配置 / 应用到本地两种预览模式。
  void _switchMode() {
    setState(() {
      _mode = _mode == _PreviewMode.pushBack ? _PreviewMode.applyLocal : _PreviewMode.pushBack;
      _resetSelectionsAndPayload();
    });
  }

  /// 重置当前模式：清空所有勾选，JSON 内容回到该模式初始状态。
  void _resetCurrentMode() {
    setState(_resetSelectionsAndPayload);
  }

  void _resetSelectionsAndPayload() {
    for (final key in _selections.keys) {
      _selections[key] = false;
    }
    if (_mode == _PreviewMode.applyLocal) {
      _applyPayload = RemoteSyncDataMerger.deepCopy(_localSnapshot) as Map<String, dynamic>;
    } else {
      _payload = RemoteSyncDataMerger.deepCopy(widget.settings) as Map<String, dynamic>;
      _refreshSensitiveFlag(_payload);
    }
  }

  // ---------------------------------------------------------------------------
  // 树内叶子值编辑（只允许改值，键与结构不可动）
  // ---------------------------------------------------------------------------

  void _buildSchema(dynamic node, List<Object> path) {
    if (node is Map) {
      for (final entry in node.entries) {
        _buildSchema(entry.value, [...path, entry.key as Object]);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _buildSchema(node[i], [...path, i]);
      }
    } else {
      _schema[jsonEncode(path)] = node;
    }
  }

  dynamic _valueAtPath(List<Object> path) {
    dynamic node = _currentPayload;
    for (var i = 0; i < path.length - 1; i++) {
      final seg = path[i];
      node = node is List ? node[seg as int] : (node as Map)[seg];
    }
    final last = path.last;
    return node is List ? node[last as int] : (node as Map)[last];
  }

  void _setPathValue(List<Object> path, dynamic value) {
    dynamic node = _currentPayload;
    for (var i = 0; i < path.length - 1; i++) {
      final seg = path[i];
      node = node is List ? node[seg as int] : (node as Map)[seg];
    }
    final last = path.last;
    if (node is List) {
      node[last as int] = value;
    } else {
      (node as Map)[last] = value;
    }
  }

  String _pathLabel(List<Object> path) {
    final buffer = StringBuffer();
    for (final seg in path) {
      if (seg is int) {
        buffer.write('[$seg]');
      } else {
        if (buffer.isNotEmpty) buffer.write(' → ');
        buffer.write(seg);
      }
    }
    return buffer.toString();
  }

  /// 判断路径是否属于"本端不识别的字段/模块"（返回配置模式中置灰区分；
  /// 应用到本地模式中这类字段已被过滤，不会出现在预览里）。
  ///
  /// analyze 的 unknownFields 记录的是模块内相对逻辑路径（数组下标写作 []，
  /// 如 favoriteRooms[].catchUpMode），这里把树行路径转成同样的逻辑形式后
  /// 做相等或前缀匹配（前缀覆盖未知对象内部的嵌套叶子）。
  bool _isUnknownPath(List<Object> path) {
    if (path.isEmpty) return false;
    final moduleKey = path.first;
    if (moduleKey is! String) return false;
    if (_report.unknownModules.contains(moduleKey)) return true;

    final unknown = _report.unknownFields[moduleKey];
    if (unknown == null || unknown.isEmpty) return false;

    final buffer = StringBuffer();
    for (var i = 1; i < path.length; i++) {
      final seg = path[i];
      buffer.write(seg is int ? '[]' : '.$seg');
    }
    final raw = buffer.toString();
    final relative = raw.startsWith('.') ? raw.substring(1) : raw;

    for (final entry in unknown) {
      if (relative == entry || relative.startsWith('$entry.')) return true;
    }
    return false;
  }

  Future<void> _editLeaf(List<Object> path) async {
    final current = _valueAtPath(path);
    final hasSchema = _schema.containsKey(jsonEncode(path));
    final schemaValue = hasSchema ? _schema[jsonEncode(path)] : _SchemaAbsent.instance;

    final result = await Get.dialog<_LeafEditResult>(
      _LeafEditDialog(pathLabel: _pathLabel(path), currentValue: current, schemaValue: schemaValue),
      barrierDismissible: false,
    );

    if (result == null || !mounted) return;
    setState(() => _setPathValue(path, result.value));
  }

  // ---------------------------------------------------------------------------
  // 应用到本地（模式动作：以右侧"本地 JSON（应用预览）"当前内容为准）
  // ---------------------------------------------------------------------------

  /// 应用模式下找出"预览内容与本地快照不一致"的未勾选模块
  /// （即只被手动编辑过的模块），它们无需勾选也应纳入应用范围。
  Set<String> _manuallyEditedModules() {
    final edited = <String>{};
    for (final key in _selections.keys) {
      if (_selections[key] == true) continue;
      if (!_applyPayload.containsKey(key)) continue;
      if (!_deepEquals(_applyPayload[key], _localSnapshot[key])) {
        edited.add(key);
      }
    }
    return edited;
  }

  Future<void> _applySelected() async {
    if (_mode != _PreviewMode.applyLocal) {
      return;
    }

    // 应用范围 = 勾选的数据块 + 预览内容与本地快照不一致（被手动编辑过）的
    // 未勾选数据块：只编辑值而不勾选时同样可以应用。
    final checkedKeys = _selections.entries.where((e) => e.value).map((e) => e.key).toSet();
    final editedKeys = _manuallyEditedModules();
    final allowedKeys = <String>{...checkedKeys, ...editedKeys};

    if (allowedKeys.isEmpty) {
      ToastUtil.show('请至少选择一个数据块，或先在右侧 JSON 中编辑字段值');
      return;
    }

    final sourceNote = [
      if (checkedKeys.isNotEmpty) '勾选 ${checkedKeys.length} 个',
      if (editedKeys.isNotEmpty) '手动编辑 ${editedKeys.length} 个',
    ].join('，');

    final confirm = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('应用选中配置'),
        content: Text(
          '将把右侧"本地 JSON（应用预览）"中变动的 ${allowedKeys.length} 个模块应用到本地'
          '（$sourceNote；对应数据被覆盖，包含手动编辑，本端不识别的字段已自动过滤），'
          '未涉及的模块保持不变。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(i18n('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(i18n('confirm')),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    setState(() => _isApplying = true);

    try {
      final backup = Get.find<BackupController>();

      // 先按本端 schema 归一化（携带 backupVersion，并保留 windowSize 附带的
      // 过滤 player 块供 extractConfig 回读），选中模块再用预览内容
      // （含手动编辑）覆盖，做到"所见即所应用"。
      final normalized = RemoteSyncDataMerger.normalizeForLocalApply(
        widget.settings,
        allowedKeys,
        _localSnapshot,
      );
      for (final key in allowedKeys) {
        if (_applyPayload.containsKey(key)) {
          normalized[key] = RemoteSyncDataMerger.deepCopy(_applyPayload[key]);
        }
      }

      backup.importPartialSettings(normalized, allowedKeys);

      // 若本页数据正是"接收推送"的暂存数据，应用成功后清掉暂存标记。
      if (identical(widget.settings, Get.find<RemoteSyncService>().pendingReceivedSettings.value)) {
        Get.find<RemoteSyncService>().clearPendingReceivedSettings();
      }

      if (!mounted) return;
      ToastUtil.show('已应用 ${allowedKeys.length} 项配置');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ToastUtil.show('应用失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 返回配置给对方（模式动作：以右侧"原始 JSON（返回内容）"当前内容为准）
  // ---------------------------------------------------------------------------

  Future<void> _pushBackSelected() async {
    if (_mode != _PreviewMode.pushBack) {
      return;
    }

    final selectedCount = _selections.values.where((v) => v).length;

    final confirm = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('返回配置给对方'),
        content: Text(
          selectedCount == 0
              ? '未勾选任何数据块，将把右侧"原始 JSON"中的配置'
                    '（即对方原始数据，可能包含你的手动编辑）发送到 ${widget.ip}:${widget.port}。是否继续？'
              : '将把右侧"原始 JSON"中的配置'
                    '（已按选中的 $selectedCount 个数据块合并本地数据，包含手动编辑；'
                    '未勾选的数据块保持对方原值）发送到 ${widget.ip}:${widget.port}。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(i18n('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(i18n('confirm')),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    setState(() => _isPushing = true);

    try {
      final service = Get.find<RemoteSyncService>();
      final payload = RemoteSyncDataMerger.deepCopy(_payload) as Map<String, dynamic>;
      final success = await service.pushSettings(widget.ip, widget.port, payload);

      if (!mounted) return;

      if (success) {
        ToastUtil.show('已成功返回配置');
        // 若本页数据正是"接收推送"的暂存数据，回传成功后清掉暂存标记。
        if (identical(widget.settings, service.pendingReceivedSettings.value)) {
          service.clearPendingReceivedSettings();
        }
      } else {
        ToastUtil.show('返回配置失败');
      }
    } catch (e) {
      if (!mounted) return;
      ToastUtil.show('返回配置失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isPushing = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配置预览 / 选择性同步')),
      body: Column(
        children: [
          _buildSummary(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final leftWidth = (constraints.maxWidth * _leftFraction)
                    .clamp(220.0, math.max(220.0, constraints.maxWidth - 260.0))
                    .toDouble();
                return Row(
                  children: [
                    SizedBox(width: leftWidth, child: _buildLeftPanel()),
                    _buildDragDivider(constraints.maxWidth),
                    Expanded(child: _buildRightPanel()),
                  ],
                );
              },
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final isApply = _mode == _PreviewMode.applyLocal;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(80),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isApply
                  ? '来自 ${widget.ip}:${widget.port} · 应用到本地模式：右侧为本地配置预览'
                        '（初始为 Windows 本地数据），左侧勾选数据块即替换为本端可识别的对方数据'
                        '（自动过滤未识别字段）；点击值可编辑，"应用到本地"按右侧预览内容生效'
                  : '来自 ${widget.ip}:${widget.port} · 返回配置模式：右侧为返回内容预览'
                        '（初始为对方原始数据），左侧勾选数据块即把本地数据合并进对应模块；'
                        '点击值可编辑，"返回配置给对方"把右侧 JSON 原样发送给对方',
              maxLines: 3,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    final selectedCount = _selections.values.where((v) => v).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '数据块（已选 $selectedCount/${_selections.length}）',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(onPressed: () => _selectAll(true), child: const Text('全选')),
              TextButton(onPressed: () => _selectAll(false), child: const Text('全不选')),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            physics: const PureLiveScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              if (_report.unknownModules.isNotEmpty) ...[
                _buildUnknownModules(),
                const SizedBox(height: 8),
              ],
              ..._selections.keys.map(_buildKeyTile),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUnknownModules() {
    final unknown = _report.unknownModules.toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, size: 16, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本端不识别的数据块（保持原样，不可选）',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final key in unknown)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline.withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _keyLabels[key] ?? key,
                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 数据块条目：复选框与"点击定位"分离——
  /// 复选框只控制是否勾选，点击条目其余区域跳转到右侧 JSON 对应位置。
  Widget _buildKeyTile(String key) {
    final isApply = _mode == _PreviewMode.applyLocal;
    final isExtension = _extensionKeys.contains(key);
    final unknownFields = _unknownFieldsOf(key);
    final label = _keyLabels[key] ?? key;
    final hasData = widget.settings[key] != null;

    final subtitle = hasData ? _describeValue(widget.settings[key]) : '(空)';
    final note = unknownFields.isNotEmpty
        ? '\n未识别: ${unknownFields.join(', ')}（${isApply ? '应用时将被过滤' : '将保持原样'}）'
        : '';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: () => _treeKey.currentState?.jumpToTopLevelKey(key),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _selections[key] ?? false,
                onChanged: (v) => _setSelected(key, v ?? false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          if (isExtension) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.orange.withAlpha(40),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '扩展',
                                style: TextStyle(fontSize: 10, color: Colors.orange),
                              ),
                            ),
                          ],
                          if (unknownFields.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.outline.withAlpha(30),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '未识别字段 ${unknownFields.length}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$subtitle$note',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分隔条拖动用 Listener 直接监听指针事件：
  /// GestureDetector 的水平拖动手势会进入竞技场、可能被祖先手势识别器
  /// 抢走导致"有拖动光标但拖不动"；Listener 命中即收事件，行为确定。
  Widget _buildDragDivider(double totalWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: Listener(
        onPointerDown: (event) {
          _dragStartX = event.position.dx;
          _dragStartFraction = _leftFraction;
        },
        onPointerMove: (event) {
          final startX = _dragStartX;
          final startFraction = _dragStartFraction;
          if (startX == null || startFraction == null) return;
          final delta = (event.position.dx - startX) / totalWidth;
          final next = ((startFraction + delta).clamp(0.2, 0.8)).toDouble();
          if (next != _leftFraction) {
            setState(() => _leftFraction = next);
          }
        },
        onPointerUp: (_) {
          _dragStartX = null;
          _dragStartFraction = null;
        },
        onPointerCancel: (_) {
          _dragStartX = null;
          _dragStartFraction = null;
        },
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 12,
          child: Center(child: Container(width: 1.5, color: Theme.of(context).dividerColor)),
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    final theme = Theme.of(context);
    final isApply = _mode == _PreviewMode.applyLocal;

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isApply ? '本地 JSON（应用预览）' : '原始 JSON（返回内容）',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isApply ? '勾选数据块即替换为对方对应数据，点击值可编辑' : '点击值可编辑（键与结构不可改）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              IconButton(
                tooltip: '重置选择与 JSON 内容',
                onPressed: _resetCurrentMode,
                icon: const Icon(Icons.restart_alt, size: 18),
              ),
              IconButton(
                tooltip: '全部展开',
                onPressed: () => _treeKey.currentState?.expandAll(),
                icon: const Icon(Icons.unfold_more, size: 18),
              ),
              IconButton(
                tooltip: '全部折叠',
                onPressed: () => _treeKey.currentState?.collapseAll(),
                icon: const Icon(Icons.unfold_less, size: 18),
              ),
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 4),
          Expanded(
            child: RemoteSyncJsonTree(
              key: _treeKey,
              json: _currentPayload,
              onLeafTap: (path, value) => _editLeaf(path),
              isUnknownPath: _isUnknownPath,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final isApply = _mode == _PreviewMode.applyLocal;
    final busy = _isApplying || _isPushing;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 4, offset: const Offset(0, -1)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: isApply
                  ? FilledButton.icon(
                      onPressed: busy ? null : _applySelected,
                      icon: const Icon(Icons.check),
                      label: Text(_isApplying ? '应用中...' : '应用到本地'),
                    )
                  : OutlinedButton.icon(
                      onPressed: busy ? null : _pushBackSelected,
                      icon: const Icon(Icons.arrow_back),
                      label: Text(_isPushing ? '返回中...' : '返回配置给对方'),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Tooltip(
                message: '切换模式（选择与 JSON 内容将重置）',
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _switchMode,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(isApply ? '切换为返回配置' : '切换为应用到本地'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _describeValue(dynamic value) {
    if (value == null) return 'null';
    if (value is Map) return 'Map(${value.length})';
    if (value is List) return 'List(${value.length})';
    if (value is String) return value.length > 40 ? '${value.substring(0, 40)}...' : value;
    return value.toString();
  }
}

/// 深比较两个 JSON 值是否相等（Map/List 递归比较，标量用 ==）。
/// 用于判断预览模块内容相对本地快照是否被手动编辑过。
bool _deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

// -----------------------------------------------------------------------------
// 叶子值编辑对话框：类型基于对方原始 schema 锁定，非法输入默认阻止、可强行保存
// -----------------------------------------------------------------------------

class _LeafEditDialog extends StatefulWidget {
  const _LeafEditDialog({
    required this.pathLabel,
    required this.currentValue,
    required this.schemaValue,
  });

  final String pathLabel;
  final dynamic currentValue;

  /// 对方原始 schema 中的值；为 _SchemaAbsent.instance 时按当前值类型推断。
  final dynamic schemaValue;

  @override
  State<_LeafEditDialog> createState() => _LeafEditDialogState();
}

class _LeafEditDialogState extends State<_LeafEditDialog> {
  late final TextEditingController _textController;
  late bool _boolChoice;

  /// 自由模式下的目标类型：'null' | 'string' | 'num' | 'bool'。
  late String _typeChoice;
  String? _errorText;

  bool get _isBoolMode => widget.currentValue is bool || widget.schemaValue is bool;
  bool get _isNumMode => !_isBoolMode && widget.schemaValue is num;
  bool get _isStringMode => !_isBoolMode && !_isNumMode && widget.schemaValue is String;
  bool get _isFreeMode => !_isBoolMode && !_isNumMode && !_isStringMode;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.currentValue == null ? '' : widget.currentValue.toString(),
    );
    _boolChoice = widget.currentValue is bool
        ? widget.currentValue as bool
        : (widget.schemaValue is bool ? widget.schemaValue as bool : true);
    _typeChoice = _initialTypeChoice();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String _initialTypeChoice() {
    if (!_isFreeMode) return '';
    final current = widget.currentValue;
    if (current == null) return 'null';
    if (current is num) return 'num';
    if (current is bool) return 'bool';
    return 'string';
  }

  num? _parseNum(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t) ?? double.tryParse(t);
  }

  String? _computeError() {
    if (_isBoolMode) return null;
    if (_isStringMode) return null;
    if (_isNumMode) {
      return _parseNum(_textController.text) == null ? '该字段应为数值' : null;
    }
    if (_typeChoice == 'num' && _parseNum(_textController.text) == null) {
      return '所选类型为数值，输入内容无法解析为数值';
    }
    return null;
  }

  void _validate() => setState(() => _errorText = _computeError());

  dynamic _buildValue() {
    if (_isBoolMode) return _boolChoice;
    if (_isNumMode) return _parseNum(_textController.text);
    if (_isStringMode) return _textController.text;
    switch (_typeChoice) {
      case 'string':
        return _textController.text;
      case 'num':
        return _parseNum(_textController.text);
      case 'bool':
        return _boolChoice;
      default:
        return null;
    }
  }

  void _save() => Navigator.of(context).pop(_LeafEditResult(_buildValue()));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.currentValue;

    return AlertDialog(
      title: const Text('编辑字段值'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.pathLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '当前值：${_describe(current)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_isBoolMode)
              DropdownButtonFormField<bool>(
                initialValue: _boolChoice,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '值（布尔）',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: true, child: Text('true')),
                  DropdownMenuItem(value: false, child: Text('false')),
                ],
                onChanged: (v) => setState(() => _boolChoice = v ?? true),
              )
            else if (_isFreeMode) ...[
              DropdownButtonFormField<String>(
                initialValue: _typeChoice,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '类型',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'null', child: Text('null')),
                  DropdownMenuItem(value: 'string', child: Text('文本')),
                  DropdownMenuItem(value: 'num', child: Text('数值')),
                  DropdownMenuItem(value: 'bool', child: Text('布尔')),
                ],
                onChanged: (v) {
                  setState(() {
                    _typeChoice = v ?? 'null';
                    _errorText = _computeError();
                  });
                },
              ),
              if (_typeChoice == 'string' || _typeChoice == 'num') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _textController,
                  autofocus: true,
                  keyboardType: _typeChoice == 'num' ? TextInputType.number : TextInputType.text,
                  onChanged: (_) => _validate(),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: _typeChoice == 'num' ? '值（数值）' : '值（文本）',
                    isDense: true,
                    errorText: _errorText,
                  ),
                ),
              ],
            ] else
              TextField(
                controller: _textController,
                autofocus: true,
                keyboardType: _isNumMode ? TextInputType.number : TextInputType.text,
                onChanged: (_) => _validate(),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: _isNumMode ? '值（数值）' : '值（文本）',
                  isDense: true,
                  errorText: _errorText,
                ),
              ),
            if (_errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                '可强行保存，但类型不符可能导致对方解析异常或数据丢失。',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (current != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const _LeafEditResult(null)),
            child: const Text('置为 null'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel'))),
        if (_errorText != null)
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
            onPressed: _save,
            child: const Text('强行保存'),
          ),
        FilledButton(onPressed: _errorText == null ? _save : null, child: Text(i18n('confirm'))),
      ],
    );
  }

  String _describe(dynamic value) {
    if (value == null) return 'null';
    if (value is String) {
      final text = '"$value"';
      return text.length > 60 ? '${text.substring(0, 60)}...' : text;
    }
    if (value is Map) return 'Map(${value.length} 项)';
    if (value is List) return 'List(${value.length} 项)';
    return value.toString();
  }
}
