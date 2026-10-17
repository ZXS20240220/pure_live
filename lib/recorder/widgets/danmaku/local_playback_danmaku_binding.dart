import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_settings_binding.dart';

class LocalPlaybackDanmakuBinding implements DanmakuSettingsBinding {
  LocalPlaybackDanmakuBinding(this._dm);

  final dynamic _dm;

  @override
  RxBool get noEmojiMode => _dm.noEmojiMode;

  @override
  RxDouble get danmakuArea => _dm.danmakuArea;

  @override
  RxDouble get danmakuTopArea => _dm.danmakuTopArea;

  @override
  RxDouble get danmakuBottomArea => _dm.danmakuBottomArea;

  @override
  RxDouble get danmakuSpeed => _dm.danmakuSpeed;

  @override
  RxDouble get danmakuFontSize => _dm.danmakuFontSize;

  @override
  RxInt get danmakuFontWeight => _dm.danmakuFontWeight;

  @override
  RxDouble get danmakuFontBorder => _dm.danmakuFontBorder;

  @override
  RxDouble get danmakuOpacity => _dm.danmakuOpacity;

  @override
  RxBool get enableDanmakuStroke => _dm.enableDanmakuStroke;

  @override
  RxInt get danmakuFps => _dm.danmakuFps;
}
