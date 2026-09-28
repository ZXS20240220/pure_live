import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pure_live/plugins/locale_helper.dart';
import 'package:pure_live/common/style/app_text_styles.dart';

class CountButton extends StatefulWidget {
  const CountButton({
    super.key,
    required this.minValue,
    required this.maxValue,
    required this.selectedValue,
    this.step = 1,
    this.backgroundColor,
    this.foregroundColor,
    this.buttonSize = const Size(35, 35),
    this.incrementIcon,
    this.decrementIcon,
    this.semanticLabel,
    this.incrementSemanticLabel,
    this.decrementSemanticLabel,
    this.borderRadius = 12.0,
    required this.onChanged,
    this.valueBuilder,
    this.textStyle,
  }) : assert(maxValue > minValue),
       assert(selectedValue >= minValue && selectedValue <= maxValue),
       assert(step > 0);

  final int minValue;
  final int maxValue;
  final int selectedValue;
  final int step;

  final Color? backgroundColor;
  final Color? foregroundColor;
  final Size buttonSize;

  final Widget? incrementIcon;
  final Widget? decrementIcon;
  final String? semanticLabel;
  final String? incrementSemanticLabel;
  final String? decrementSemanticLabel;

  final double borderRadius;

  final ValueChanged<int> onChanged;

  final Widget Function(int value)? valueBuilder;

  final TextStyle? textStyle;

  @override
  State<CountButton> createState() => _CountButtonState();
}

class _CountButtonState extends State<CountButton> {
  Timer? incrementTimer;
  Timer? decrementTimer;

  // 点击编辑状态：数值框可临时变为输入框，失焦/回车提交，Esc 取消。
  bool _editing = false;
  TextEditingController? _editController;
  FocusNode? _editFocusNode;

  @override
  void didUpdateWidget(covariant CountButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 编辑期间 +/- 被点击或外部值变化（如套用模板）时同步文本框。
    if (_editing && widget.selectedValue != oldWidget.selectedValue) {
      final controller = _editController;
      if (controller != null) {
        controller.text = widget.selectedValue.toString();
        controller.selection = TextSelection.collapsed(offset: controller.text.length);
      }
    }
  }

  @override
  void dispose() {
    _editController?.dispose();
    _editFocusNode?.dispose();
    incrementTimer?.cancel();
    decrementTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.backgroundColor ?? Theme.of(context).colorScheme.primary;
    final foregroundColor = widget.foregroundColor ?? Colors.white;
    final effectiveTextStyle = widget.textStyle ?? AppTextStyles.t15.copyWith(color: Colors.white);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: widget.buttonSize.width,
            height: widget.buttonSize.height,
            child: GestureDetector(
              onLongPress: startDecrementTimer,
              onLongPressEnd: (_) {
                decrementTimer?.cancel();
                decrementTimer = null;
              },
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: backgroundColor,
                  foregroundColor: foregroundColor,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(widget.borderRadius),
                      bottomLeft: Radius.circular(widget.borderRadius),
                    ),
                  ),
                ),
                onPressed: _decrement,
                child: _buildSemanticIcon(
                  widget.decrementIcon ?? Icon(Icons.remove, color: foregroundColor),
                  widget.decrementSemanticLabel,
                ),
              ),
            ),
          ),

          Semantics(
            label: widget.semanticLabel == null ? null : '${widget.semanticLabel}, ${widget.selectedValue}',
            excludeSemantics: widget.semanticLabel != null,
            child: _buildValueBox(backgroundColor, effectiveTextStyle),
          ),

          SizedBox(
            width: widget.buttonSize.width,
            height: widget.buttonSize.height,
            child: GestureDetector(
              onLongPress: startIncrementTimer,
              onLongPressEnd: (_) {
                incrementTimer?.cancel();
                incrementTimer = null;
              },
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: backgroundColor,
                  foregroundColor: foregroundColor,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(widget.borderRadius),
                      bottomRight: Radius.circular(widget.borderRadius),
                    ),
                  ),
                ),
                onPressed: _increment,
                child: _buildSemanticIcon(
                  widget.incrementIcon ?? Icon(Icons.add, color: foregroundColor),
                  widget.incrementSemanticLabel,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 中间数值框：未编辑时显示数值并支持点击进入编辑；编辑时为整数输入框。
  Widget _buildValueBox(Color backgroundColor, TextStyle effectiveTextStyle) {
    final editable = widget.valueBuilder == null;
    Widget box = MouseRegion(
      cursor: editable ? SystemMouseCursors.text : MouseCursor.defer,
      child: GestureDetector(
        onTap: editable ? _startEditing : null,
        child: Container(
          height: widget.buttonSize.height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.symmetric(horizontal: BorderSide(color: backgroundColor, width: 2)),
          ),
          child: _editing
              ? SizedBox(
                  width: 48,
                  child: TextField(
                    controller: _editController,
                    focusNode: _editFocusNode,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      // 仅允许整数；负号仅在该区间本身包含负值时放行。
                      FilteringTextInputFormatter.allow(RegExp(widget.minValue < 0 ? r'-?\d*' : r'\d*')),
                    ],
                    style: effectiveTextStyle,
                    cursorWidth: 1.2,
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                )
              : widget.valueBuilder != null
              ? widget.valueBuilder!(widget.selectedValue)
              : Text(widget.selectedValue.toString(), style: effectiveTextStyle),
        ),
      ),
    );
    if (editable && !_editing) {
      box = Tooltip(message: i18n('click_to_edit_value'), waitDuration: const Duration(milliseconds: 500), child: box);
    }
    return box;
  }

  void _startEditing() {
    if (_editing) return;
    final controller = TextEditingController(text: widget.selectedValue.toString());
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    final focusNode = FocusNode(onKeyEvent: _handleEditKeyEvent)..addListener(_handleEditFocusChanged);
    setState(() {
      _editing = true;
      _editController = controller;
      _editFocusNode = focusNode;
    });
    focusNode.requestFocus();
  }

  KeyEventResult _handleEditKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _endEditing(save: false);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        _endEditing(save: true);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _handleEditFocusChanged() {
    final node = _editFocusNode;
    if (node != null && !node.hasFocus) _endEditing(save: true);
  }

  void _endEditing({required bool save}) {
    if (!_editing) return;
    final text = _editController?.text ?? '';
    final controller = _editController;
    final focusNode = _editFocusNode;
    _editController = null;
    _editFocusNode = null;
    _editing = false;
    if (mounted) setState(() {});
    focusNode
      ?..removeListener(_handleEditFocusChanged)
      ..unfocus();
    // 延迟到帧末释放，避免 TextField 仍在树中时释放其依赖。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusNode?.dispose();
      controller?.dispose();
    });
    if (save) _applyText(text);
  }

  /// 将输入解析为合法值：非法输入直接回显原值；合法值先对齐步长，
  /// 再夹取到 [CountButton.minValue, CountButton.maxValue]，避免越界值破坏父级状态。
  void _applyText(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    final stepped = widget.minValue + ((parsed - widget.minValue) / widget.step).round() * widget.step;
    final clamped = stepped.clamp(widget.minValue, widget.maxValue).toInt();
    if (clamped != widget.selectedValue) widget.onChanged(clamped);
  }

  Widget _buildSemanticIcon(Widget icon, String? label) {
    if (label == null) return icon;
    return Semantics(
      label: label,
      child: ExcludeSemantics(child: icon),
    );
  }

  void _increment() {
    final value = widget.selectedValue + widget.step;
    if (value <= widget.maxValue) {
      widget.onChanged(value);
    }
  }

  void _decrement() {
    final value = widget.selectedValue - widget.step;
    if (value >= widget.minValue) {
      widget.onChanged(value);
    }
  }

  void startIncrementTimer() {
    incrementTimer?.cancel();
    incrementTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final value = widget.selectedValue + widget.step;
      if (value <= widget.maxValue) {
        widget.onChanged(value);
      } else {
        incrementTimer?.cancel();
        incrementTimer = null;
      }
    });
  }

  void startDecrementTimer() {
    decrementTimer?.cancel();
    decrementTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final value = widget.selectedValue - widget.step;
      if (value >= widget.minValue) {
        widget.onChanged(value);
      } else {
        decrementTimer?.cancel();
        decrementTimer = null;
      }
    });
  }
}
