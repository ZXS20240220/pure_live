import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// JSON 树中的一行：定位路径 + 展示内容。
class _JsonRow {
  const _JsonRow({
    required this.path,
    required this.depth,
    required this.key,
    required this.value,
    required this.isContainer,
    required this.isMapEntry,
  });

  /// 从根到该节点的路径（Map 键为 String，数组下标为 int）。
  final List<Object> path;

  /// 缩进层级（顶层为 0）。
  final int depth;

  /// Map 键（String）或数组下标（int）。
  final Object key;

  final dynamic value;

  /// Map / List 视为容器（可折叠），其余为叶子（可编辑）。
  final bool isContainer;

  final bool isMapEntry;
}

/// 可折叠的 JSON 树视图，样式对齐 flutter_json 的 JsonWidget
/// （键色 primary、数值绿、字符串紫、布尔橙），但额外支持：
/// - 固定行高 + 虚拟渲染，顶层键可编程跳转（[jumpToTopLevelKey]）；
/// - 叶子节点点击回调 [onLeafTap]，由宿主页面负责编辑逻辑；
/// - 全部展开 / 折叠（[expandAll] / [collapseAll]）。
///
/// 只负责展示与定位，不持有 JSON 数据本身；宿主数据变化后经
/// didUpdateWidget 自动重建行。
class RemoteSyncJsonTree extends StatefulWidget {
  const RemoteSyncJsonTree({super.key, required this.json, this.onLeafTap, this.isUnknownPath});

  final Map<String, dynamic> json;

  /// 叶子节点被点击时回调（path 为从根到该叶子的路径）。
  final void Function(List<Object> path, dynamic value)? onLeafTap;

  /// 返回该路径是否属于"本端不识别的字段/模块"；为 true 的行整行置灰，
  /// 仍可正常点击编辑。
  final bool Function(List<Object> path)? isUnknownPath;

  @override
  RemoteSyncJsonTreeState createState() => RemoteSyncJsonTreeState();
}

class RemoteSyncJsonTreeState extends State<RemoteSyncJsonTree> {
  /// 单行固定高度，保证跳转偏移可精确计算。
  static const double rowExtent = 28;

  /// 默认展开深度（对齐 JsonWidget 的 initialExpandDepth: 2）。
  static const int initialExpandDepth = 2;

  /// 水平方向最小内容宽度（深层嵌套时出现横向滚动）。
  static const double minContentWidth = 860;

  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();

  /// 展开状态覆盖表：jsonEncode(path) -> bool。
  /// 未记录的路径默认 depth < initialExpandDepth 时展开。
  final Map<String, bool> _expanded = {};

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  bool _isExpanded(List<Object> path, int depth) =>
      _expanded[jsonEncode(path)] ?? depth < initialExpandDepth;

  void _toggle(List<Object> path, int depth) {
    setState(() => _expanded[jsonEncode(path)] = !_isExpanded(path, depth));
  }

  void expandAll() {
    setState(() => _forEachContainerPath((p) => _expanded[p] = true));
  }

  void collapseAll() {
    setState(() => _forEachContainerPath((p) => _expanded[p] = false));
  }

  /// 跳转并展开指定顶层键所在的数据块。
  void jumpToTopLevelKey(String key) {
    final rows = _flatten();
    final index = rows.indexWhere((row) => row.depth == 0 && row.key == key);
    if (index < 0) return;

    setState(() => _expanded[jsonEncode(rows[index].path)] = true);

    // 展开会改变行数，等下一帧布局完成后再滚动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalController.hasClients) return;
      final target = (index * rowExtent - 8).clamp(
        0.0,
        _verticalController.position.maxScrollExtent,
      );
      _verticalController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _forEachContainerPath(void Function(String pathKey) action) {
    void walk(dynamic value, List<Object> prefix) {
      if (value is Map) {
        for (final entry in value.entries) {
          final path = [...prefix, entry.key as Object];
          if (entry.value is Map || entry.value is List) {
            action(jsonEncode(path));
            walk(entry.value, path);
          }
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          final path = [...prefix, i];
          if (value[i] is Map || value[i] is List) {
            action(jsonEncode(path));
            walk(value[i], path);
          }
        }
      }
    }

    walk(widget.json, const <Object>[]);
  }

  List<_JsonRow> _flatten() {
    final rows = <_JsonRow>[];

    void walk(dynamic value, int depth, List<Object> prefix) {
      if (value is Map) {
        for (final entry in value.entries) {
          final path = [...prefix, entry.key as Object];
          final v = entry.value;
          final isContainer = v is Map || v is List;
          rows.add(
            _JsonRow(
              path: path,
              depth: depth,
              key: entry.key as Object,
              value: v,
              isContainer: isContainer,
              isMapEntry: true,
            ),
          );
          if (isContainer && _isExpanded(path, depth)) walk(v, depth + 1, path);
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          final path = [...prefix, i];
          final v = value[i];
          final isContainer = v is Map || v is List;
          rows.add(
            _JsonRow(
              path: path,
              depth: depth,
              key: i,
              value: v,
              isContainer: isContainer,
              isMapEntry: false,
            ),
          );
          if (isContainer && _isExpanded(path, depth)) walk(v, depth + 1, path);
        }
      }
    }

    walk(widget.json, 0, const <Object>[]);
    return rows;
  }

  Color _colorFor(dynamic value, ThemeData theme) {
    if (value is Map || value is List) return theme.colorScheme.outline;
    if (value is String) return const Color(0xFFCD44D9);
    if (value is num) return const Color(0xFF199B4D);
    if (value is bool) return Colors.orange;
    return theme.colorScheme.outline; // null
  }

  String _preview(dynamic value) {
    if (value is Map) return '{…} ${value.length} 项';
    if (value is List) return '[…] ${value.length} 项';
    if (value is String) return '"$value"';
    if (value == null) return 'null';
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _flatten();

    return LayoutBuilder(
      builder: (context, constraints) {
        return Scrollbar(
          controller: _verticalController,
          thumbVisibility: true,
          // 嵌套滚动条谓词不能写反：内层水平滚动容器自身的通知 depth 为 0，
          // 垂直 ListView 的通知穿过它之后 depth 为 1。若写反，两个滚动条
          // 都会绑到错误的轴上，表现为"滚动条消失"。
          notificationPredicate: (notification) => notification.depth == 1,
          child: Scrollbar(
            controller: _horizontalController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _horizontalController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(constraints.maxWidth, minContentWidth),
                child: ListView.builder(
                  controller: _verticalController,
                  itemExtent: rowExtent,
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _buildRow(context, theme, rows[index]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, ThemeData theme, _JsonRow row) {
    final value = row.value;
    final isUnknown = widget.isUnknownPath?.call(row.path) ?? false;

    final Widget leading = row.isContainer
        ? Icon(
            _isExpanded(row.path, row.depth)
                ? Icons.keyboard_arrow_down
                : Icons.keyboard_arrow_right,
            size: 16,
            color: isUnknown
                ? theme.colorScheme.outline.withValues(alpha: 0.5)
                : theme.colorScheme.outline,
          )
        : const SizedBox(width: 16);

    // 未识别字段整行降为灰色，与正常数据明显区分（数据双向保持原样）。
    final Color valueColor = isUnknown
        ? theme.colorScheme.outline.withValues(alpha: 0.6)
        : _colorFor(value, theme);

    final Widget valueText = Flexible(
      child: Text(
        _preview(value),
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: valueColor),
      ),
    );

    final Widget editIcon = row.isContainer
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(
              Icons.edit_outlined,
              size: 11,
              color: theme.colorScheme.outline.withValues(alpha: 0.5),
            ),
          );

    return InkWell(
      onTap: () {
        if (row.isContainer) {
          _toggle(row.path, row.depth);
        } else {
          widget.onLeafTap?.call(row.path, row.value);
        }
      },
      // 行不参与键盘焦点遍历：Tab 移动焦点会触发 Scrollable.ensureVisible，
      // 导致 JSON 视图内容意外滚动偏移。
      canRequestFocus: false,
      child: SizedBox(
        height: rowExtent,
        child: Row(
          children: [
            SizedBox(width: row.depth * 12.0),
            leading,
            const SizedBox(width: 2),
            Text(
              row.isMapEntry ? '${row.key}' : '[${row.key}]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: row.isMapEntry ? FontWeight.bold : FontWeight.normal,
                color: isUnknown
                    ? theme.colorScheme.outline.withValues(alpha: 0.6)
                    : row.isMapEntry
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
            const Text(': ', style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
            valueText,
            editIcon,
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
