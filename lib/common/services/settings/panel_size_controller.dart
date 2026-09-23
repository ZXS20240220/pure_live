import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';

class PanelSizeController extends GetxController {
  static PanelSizeController get to => Get.find<PanelSizeController>();

  static const double kDefaultPanelWidth = 380.0;
  static const double kMinPanelWidth = 335.0;
  static const double kMaxPanelRatio = 0.5;

  static const double kDefaultImmersiveOpacity = 0.92;
  static const double kMinImmersiveOpacity = 0.1;
  static const double kMaxImmersiveOpacity = 1.0;

  /// 换台面板房间列表布局：standard（封面卡片网格）/ compact（紧凑列表）。
  /// 由用户手动切换，不再随侧栏宽度自动变化。
  static const String roomSwitchLayoutStandard = 'standard';
  static const String roomSwitchLayoutCompact = 'compact';

  final RxDouble storedPanelWidth = hiveDouble('live_panel_width', kDefaultPanelWidth);
  final RxDouble storedImmersiveOpacity = hiveDouble('live_panel_immersive_opacity', kDefaultImmersiveOpacity);
  final RxString roomSwitchLayoutMode = hiveString('live_panel_room_switch_layout', roomSwitchLayoutStandard);

  double get panelWidth => storedPanelWidth.v;

  double get immersiveOpacity => storedImmersiveOpacity.v.clamp(kMinImmersiveOpacity, kMaxImmersiveOpacity);

  set immersiveOpacity(double value) {
    storedImmersiveOpacity.v = value.clamp(kMinImmersiveOpacity, kMaxImmersiveOpacity);
  }

  /// 换台面板是否处于紧凑列表布局。
  bool get isRoomSwitchCompact => roomSwitchLayoutMode.v == roomSwitchLayoutCompact;

  /// 显式设置换台面板布局，仅接受合法值。
  void setRoomSwitchLayout(String mode) {
    if (mode != roomSwitchLayoutStandard && mode != roomSwitchLayoutCompact) return;
    roomSwitchLayoutMode.v = mode;
  }

  /// 在卡片 / 列表布局之间切换。
  void toggleRoomSwitchLayout() {
    roomSwitchLayoutMode.v = isRoomSwitchCompact ? roomSwitchLayoutStandard : roomSwitchLayoutCompact;
  }

  double clampWidth(double width, double screenWidth) {
    final maxWidth = (screenWidth * kMaxPanelRatio).floorToDouble();
    return width.clamp(kMinPanelWidth, maxWidth);
  }

  void setPanelWidth(double width, double screenWidth) {
    storedPanelWidth.v = clampWidth(width, screenWidth);
  }

  void reset(double screenWidth) {
    storedPanelWidth.v = clampWidth(kDefaultPanelWidth, screenWidth);
  }

  Map<String, dynamic> toJson() {
    return {
      'panelWidth': storedPanelWidth.v,
      'immersiveOpacity': storedImmersiveOpacity.v,
      'roomSwitchLayout': roomSwitchLayoutMode.v,
    };
  }

  void fromJson(Map<String, dynamic> json) {
    storedPanelWidth.v = (json['panelWidth'] ?? kDefaultPanelWidth).toDouble();
    storedImmersiveOpacity.v = (json['immersiveOpacity'] ?? kDefaultImmersiveOpacity).toDouble();
    final layout = json['roomSwitchLayout'];
    if (layout is String && (layout == roomSwitchLayoutStandard || layout == roomSwitchLayoutCompact)) {
      roomSwitchLayoutMode.v = layout;
    }
  }
}
