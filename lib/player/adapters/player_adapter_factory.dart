import 'package:pure_live/player/models/player_engine.dart';
import 'package:pure_live/player/adapters/media_kit_adapter.dart';
import 'package:pure_live/player/interface/unified_player_interface.dart';

class PlayerAdapterFactory {
  static Future<UnifiedPlayer> create(PlayerEngine engine) async {
    // 仅存 media_kit（mpv）内核；engine 参数保留以兼容现有调用链。
    return MediaKitAdapter();
  }
}
