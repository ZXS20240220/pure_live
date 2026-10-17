import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
/// TextField 不受影响：EditableText 自身的 Shortcuts 离焦点更近，优先级更高。
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
    return Shortcuts(shortcuts: _shortcuts, child: child);
  }
}
