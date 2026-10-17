import 'package:pure_live/get/get.dart';
import 'package:pure_live/recorder/pages/local_playback/local_playback_controller.dart';

class LocalPlaybackBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(() => LocalPlaybackController());
  }
}
