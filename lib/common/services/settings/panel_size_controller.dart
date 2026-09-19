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

  final RxDouble storedPanelWidth = hiveDouble('live_panel_width', kDefaultPanelWidth);
  final RxDouble storedImmersiveOpacity = hiveDouble('live_panel_immersive_opacity', kDefaultImmersiveOpacity);

  double get panelWidth => storedPanelWidth.v;

  double get immersiveOpacity => storedImmersiveOpacity.v.clamp(kMinImmersiveOpacity, kMaxImmersiveOpacity);

  set immersiveOpacity(double value) {
    storedImmersiveOpacity.v = value.clamp(kMinImmersiveOpacity, kMaxImmersiveOpacity);
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
    return {'panelWidth': storedPanelWidth.v, 'immersiveOpacity': storedImmersiveOpacity.v};
  }

  void fromJson(Map<String, dynamic> json) {
    storedPanelWidth.v = (json['panelWidth'] ?? kDefaultPanelWidth).toDouble();
    storedImmersiveOpacity.v = (json['immersiveOpacity'] ?? kDefaultImmersiveOpacity).toDouble();
  }
}
