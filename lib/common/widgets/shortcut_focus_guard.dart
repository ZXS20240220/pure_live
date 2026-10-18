import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:pure_live/common/base/focus_util.dart';

/// 阻止 Flutter 原生焦点系统对快捷键按键的默认响应。
///
/// 项目中各页面的快捷键通过 `HardwareKeyboard.instance.addHandler` 注册全局回调。
/// 该回调与 Flutter 的 Focus/Shortcuts/Actions 系统是两条并行路径，返回 `true`
/// 无法阻止原生焦点系统同时处理同一按键。
///
/// 具体冲突：
/// - 方向键：Flutter 原生会移动焦点到下一个可聚焦 Widget
/// - 空格/回车：若焦点在按钮上，会触发按钮的 `onPressed`（ActivateIntent）
///
/// 本组件将这些按键映射到 [DoNothingIntent]，由 Shortcuts 系统消费事件，
/// 从而阻止上述默认行为。`HardwareKeyboard` 的全局回调仍然并行执行。
///
/// 焦点位于文本输入框（EditableText，如 TextField）内时本组件不拦截，原因：
/// - 方向键移动光标依赖 `WidgetsApp` 安装的 `DefaultTextEditingShortcuts`，
///   它位于页面外层，优先级低于本组件，拦截会导致方向键无法移动光标；
/// - Windows 引擎对已被框架处理的按键事件不会重新派发给系统生成字符输入，
///   拦截空格/回车会导致文本框无法输入。
class ShortcutFocusGuard extends StatelessWidget {
  final Widget child;

  const ShortcutFocusGuard({super.key, required this.child});

  static const Map<ShortcutActivator, Intent> _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.space): DoNothingIntent(),
    SingleActivator(LogicalKeyboardKey.enter): DoNothingIntent(),
    SingleActivator(LogicalKeyboardKey.arrowUp): DoNothingIntent(),
    SingleActivator(LogicalKeyboardKey.arrowDown): DoNothingIntent(),
    SingleActivator(LogicalKeyboardKey.arrowLeft): DoNothingIntent(),
    SingleActivator(LogicalKeyboardKey.arrowRight): DoNothingIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts.manager(
      manager: _GuardShortcutManager(shortcuts: _shortcuts),
      child: child,
    );
  }
}

/// 焦点在文本输入框内时跳过拦截，让按键事件继续沿焦点链冒泡给
/// `DefaultTextEditingShortcuts`（光标移动、剪贴板等），并保持引擎对
/// 未处理按键的重新派发（字符输入依赖此机制）。
class _GuardShortcutManager extends ShortcutManager {
  _GuardShortcutManager({required super.shortcuts});

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (isEditingFocused()) {
      return KeyEventResult.ignored;
    }
    return super.handleKeypress(context, event);
  }
}
