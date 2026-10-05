import 'dart:async';
import 'dart:developer' as developer;

import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/multiview/cells/multiview_cell_player.dart';
import 'package:pure_live/modules/multiview/danmaku/multiview_danmaku_session.dart';
import 'package:pure_live/modules/multiview/models/multiview_models.dart';
import 'package:pure_live/modules/multiview/multiview_controller.dart';

/// 进程内小窗的生命周期状态。
enum MiniPipStatus { resolving, playing, error, offline }

/// 单个小窗槽位：自持独立播放器实例与（按需创建的）弹幕会话。
///
/// 视图层（MiniPipHost）只消费这里的响应式状态，不持有任何原生资源。
class MiniPipSlot {
  MiniPipSlot({required this.room, required this.initialSize, this.initialPosition}) : size = initialSize.obs {
    // 弹幕默认关闭：弹幕会话惰性创建，按钮状态须与实际表现一致，
    // 避免默认"开"却无弹幕的误导。用户可按需开启（仍受全局小窗弹幕开关约束）。
    danmakuEnabled.value = false;
  }

  /// 房间标识与元数据（标题/昵称/弹幕参数随卡片一起带入）。
  ///
  /// 非 final：侧栏卡片只携带列表级数据，缺少仅详情接口才下发的弹幕连接
  /// 参数（danmakuData）。该参数在用户首次开启弹幕时由 getRoomDetail 惰性
  /// 拉取并原地回填（不挂在起播路径上）；回填前后 platform/roomId 身份一致。
  LiveRoom room;

  /// 解析/起播纪元：顶替、关闭、重试都会推进，迟到的异步结果必须以此自检。
  int epoch = 0;

  final Rx<MiniPipStatus> status = MiniPipStatus.resolving.obs;

  /// 独立 libmpv 实例（multiview 同款内核，静音起播）。
  MultiviewCellPlayerHandle? player;

  /// 窗口左上角相对宿主的逻辑坐标；null 表示尚未按宿主尺寸完成首帧定位。
  final Rxn<Offset> position = Rxn<Offset>();

  /// 窗口逻辑尺寸（固定 16:9，由视图层保证）。
  final Rx<Size> size;

  /// 被顶替补位时沿用上一窗的几何位置，避免新窗跳回初始锚点。
  final Offset? initialPosition;
  final Size initialSize;

  /// 弹幕显隐：默认跟随"小窗弹幕"开关；左上角按钮可逐窗切换。
  final RxBool danmakuEnabled = false.obs;

  /// 首次开启弹幕时的详情补全是否在途：等待 getRoomDetail 期间按钮状态
  /// 尚未翻转，用于吞掉用户连点，避免重复详情请求与重复建连。
  bool danmakuEnriching = false;

  /// 默认静音；可由音量条或静音按钮手动取消。
  final RxBool muted = true.obs;

  /// 播放状态响应式镜像：由控制器在播放器就绪后订阅 playingStream 驱动，
  /// 供播放/暂停按钮读取，避免视图层直接订阅流时错过首帧。
  final RxBool isPlaying = false.obs;

  /// 音量 0.0~1.0（静音时输出为 0，但保留该值供取消静音时恢复）。
  final RxDouble volume = 0.0.obs;

  /// 窗口不透明度 0.3~1.0；由左下角透明度条控制，默认完全不透明。
  final RxDouble opacity = 1.0.obs;

  /// 指针悬停：工具栏淡入淡出。
  final RxBool hovered = false.obs;

  /// 解码视频的实际宽高比（宽/高）；未知时为 16:9。
  /// 由控制器在收到视频尺寸流后更新，视图据此决定窗口比例与缩放约束。
  final RxDouble videoAspectRatio = (16.0 / 9.0).obs;

  MultiviewDanmakuSession? _danmakuSession;
  BarrageController? barrageController;
  StreamSubscription<void>? _sourceEndSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _videoWidthSub;
  StreamSubscription<int?>? _videoHeightSub;
  int? lastVideoWidth;
  int? lastVideoHeight;
  String? errorDetail;

  bool isSameRoom(LiveRoom other) => other.roomId == room.roomId && other.platform == room.platform;
}

/// 播放页进程内小窗组管理器（非 GetxController 注册，由 LivePlayController
/// 持有，生命周期严格跟随播放页：退出/返回时统一销毁全部实例）。
///
/// 与多画面同看共享 [MultiviewCellPlayer] 内核与解析链路，但管理策略不同：
/// - 固定上限 [maxWindows]，第 4 个房间顶替最旧槽位（位置沿用）；
/// - 始终最低清晰度、静音、关弹幕起播；
/// - 不做音频焦点模型（每窗独立静音开关），不做布局网格（自由浮窗）。
class MiniPipController {
  MiniPipController();

  /// 同时存在的小窗上限（主窗之外的额外 libmpv 实例数）。
  static const int maxWindows = 3;

  // 尺寸按"长边"约束，窗口比例跟随解码视频的实际宽高比，避免竖屏直播
  // 被强制塞进 16:9 窗口而出现上下黑边。16:9 下：长边 350→高约 197，
  // 长边 640→高 360；竖屏 9:16 下：长边 360→宽 202.5，长边 640→宽 360。
  static const double minLongSide = 350.0;
  static const double maxLongSide = 640.0;
  static const Size initialSize = Size(360, 202.5);

  @Deprecated('Use minLongSide/maxLongSide with slot.videoAspectRatio instead.')
  static const Size minSize = Size(350, 350 * 9 / 16);
  @Deprecated('Use minLongSide/maxLongSide with slot.videoAspectRatio instead.')
  static const Size maxSize = Size(640, 360);

  /// 给定视频宽高比与长边，计算窗口逻辑尺寸。
  static Size sizeForAspectRatio(double aspectRatio, double longSide) {
    final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
    final side = longSide.clamp(minLongSide, maxLongSide).toDouble();
    if (ratio >= 1) return Size(side, side / ratio);
    return Size(side * ratio, side);
  }

  /// 窗口透明度条范围：0.3（半透明）~ 1.0（完全不透明）。
  static const double minOpacity = 0.0;
  static const double maxOpacity = 1.0;

  /// 与主画面一致的滚轮手感：每格滚轮约 24px 宽，尺寸始终保持 16:9。
  static const double wheelWidthStep = 24.0;

  /// 有序槽位：尾部为 Z 序最前（最近聚焦/新建）。
  final RxList<MiniPipSlot> slots = <MiniPipSlot>[].obs;

  /// 所有小窗中的最大尺寸，用于约束主窗口最小尺寸，避免窗口缩到比小窗还小。
  final Rx<Size> maxSlotSize = Size.zero.obs;

  bool _disposed = false;

  bool get hasWindows => slots.isNotEmpty;

  /// 重新计算所有小窗的最大尺寸并通知；供主窗口最小尺寸约束使用。
  void _refreshMaxSlotSize() {
    var maxW = 0.0;
    var maxH = 0.0;
    for (final slot in slots) {
      final s = slot.size.value;
      if (s.width > maxW) maxW = s.width;
      if (s.height > maxH) maxH = s.height;
    }
    maxSlotSize.value = Size(maxW, maxH);
  }

  MiniPipSlot? slotOfRoom(LiveRoom room) {
    for (final slot in slots) {
      if (slot.isSameRoom(room)) return slot;
    }
    return null;
  }

  /// 打开（或聚焦已存在的）小窗。超过上限时顶替最旧槽位。
  Future<void> open(LiveRoom room) async {
    if (_disposed) return;
    if (room.platform == null || room.roomId == null || room.roomId!.isEmpty) return;

    // 目标房间正是主窗当前在播的房间：不再重复开小窗（主窗已经在展示）。
    if (_isSameAsMainRoom(room)) return;

    // 同房间已开：不重复创建，直接置顶聚焦。
    final existing = slotOfRoom(room);
    if (existing != null) {
      focus(existing);
      return;
    }

    MiniPipSlot? replaced;
    if (slots.length >= maxWindows) {
      replaced = slots.removeAt(0);
    }

    final slot = MiniPipSlot(
      room: room,
      initialSize: replaced?.size.value ?? initialSize,
      initialPosition: replaced?.position.value,
    );
    slot.position.value = slot.initialPosition;
    slots.add(slot);
    _refreshMaxSlotSize();

    if (replaced != null) {
      unawaited(_teardown(replaced));
    }

    final epoch = ++slot.epoch;
    bool isStale() => _disposed || slot.epoch != epoch || !slots.contains(slot);

    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final handle = MultiviewCellPlayer(
      renderWidth: (slot.initialSize.width * dpr).round(),
      renderHeight: (slot.initialSize.height * dpr).round(),
    );
    slot.player = handle;

    // 订阅播放状态流，驱动 slot.isPlaying 响应式镜像，供按钮实时反映。
    // playingStream 是广播流不回放历史值，因此订阅后须立即同步一次初值。
    slot.isPlaying.value = handle.isPlaying;
    slot._playingSub = handle.playingStream.listen((playing) {
      if (!isStale()) slot.isPlaying.value = playing;
    });

    try {
      final source = await MultiviewController.resolveRoomStream(room);
      if (isStale()) return;

      // 断流（服务器关闭直播）：进入离线态展示并释放空转的播放器，
      // 保留窗口壳供用户重试（不做自动重连）。
      slot._sourceEndSub = handle.sourceEnded.listen((_) {
        if (isStale()) return;
        slot.status.value = MiniPipStatus.offline;
        unawaited(_teardown(slot, keepSlot: true));
      });

      await MultiviewController.openResolvedSource(handle, source, start: true);
      if (isStale()) return;
      slot.status.value = MiniPipStatus.playing;
      _applySlotStateToPlayer(slot);
      // 播放器已创建，现在订阅解码视频尺寸流；此时流才是真实的
      // （_player 在 start() 中才实例化，之前订阅只会拿到空流）。
      _bindVideoDimensions(slot, handle);
    } on MultiviewRoomOffline {
      if (isStale()) return;
      slot.status.value = MiniPipStatus.offline;
      unawaited(_teardown(slot, keepSlot: true));
    } catch (error, stackTrace) {
      if (isStale()) return;
      developer.log(
        'MiniPip: open failed for ${room.platform}/${room.roomId}',
        name: 'MiniPip',
        error: error,
        stackTrace: stackTrace,
      );
      slot.errorDetail = error.toString();
      slot.status.value = MiniPipStatus.error;
      unawaited(_teardown(slot, keepSlot: true));
    }
  }

  /// 重试错误/离线小窗：复用原 slot（保留尺寸/位置），仅重新走解析起播。
  Future<void> retry(MiniPipSlot slot) async {
    if (_disposed || !slots.contains(slot)) return;
    // 释放旧播放器但保留 slot 本身及其几何信息。
    await _teardown(slot, keepSlot: true);
    slot.status.value = MiniPipStatus.resolving;
    slot.errorDetail = null;

    final epoch = ++slot.epoch;
    bool isStale() => _disposed || slot.epoch != epoch || !slots.contains(slot);

    final room = slot.room;
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final size = slot.size.value;
    final handle = MultiviewCellPlayer(
      renderWidth: (size.width * dpr).round(),
      renderHeight: (size.height * dpr).round(),
    );
    slot.player = handle;
    slot.isPlaying.value = handle.isPlaying;
    slot._playingSub = handle.playingStream.listen((playing) {
      if (!isStale()) slot.isPlaying.value = playing;
    });

    try {
      final source = await MultiviewController.resolveRoomStream(room);
      if (isStale()) return;
      slot._sourceEndSub = handle.sourceEnded.listen((_) {
        if (isStale()) return;
        slot.status.value = MiniPipStatus.offline;
        unawaited(_teardown(slot, keepSlot: true));
      });
      await MultiviewController.openResolvedSource(handle, source, start: true);
      if (isStale()) return;
      slot.status.value = MiniPipStatus.playing;
      _applySlotStateToPlayer(slot);
      // 播放器已创建，此时订阅解码视频尺寸流才能拿到真实数据。
      _bindVideoDimensions(slot, handle);
    } on MultiviewRoomOffline {
      if (isStale()) return;
      slot.status.value = MiniPipStatus.offline;
      unawaited(_teardown(slot, keepSlot: true));
    } catch (error, stackTrace) {
      if (isStale()) return;
      developer.log(
        'MiniPip: retry failed for ${room.platform}/${room.roomId}',
        name: 'MiniPip',
        error: error,
        stackTrace: stackTrace,
      );
      slot.errorDetail = error.toString();
      slot.status.value = MiniPipStatus.error;
      unawaited(_teardown(slot, keepSlot: true));
    }
  }

  /// 聚焦：置底 Z 序（列表尾部）。
  void focus(MiniPipSlot slot) {
    if (!slots.contains(slot) || slots.last == slot) return;
    slots.remove(slot);
    slots.add(slot);
  }

  /// 关闭单个小窗并释放其全部原生资源。
  Future<void> close(MiniPipSlot slot) {
    slots.remove(slot);
    _refreshMaxSlotSize();
    return _teardown(slot);
  }

  /// 双击小窗：将该房间提升为主窗播放，同时销毁此小窗。
  /// 复用 LivePlayController.switchRoom——它在切换前会自动关闭命中的小窗，
  /// 因此这里只需发起切换，小窗资源由 switchRoom 统一回收。
  Future<void> promoteToMain(MiniPipSlot slot) async {
    if (_disposed || !slots.contains(slot)) return;
    if (!Get.isRegistered<LivePlayController>()) return;
    final controller = Get.find<LivePlayController>();
    await controller.switchRoom(slot.room);
  }

  /// 判断目标房间是否就是主窗当前正在播放的房间。
  bool _isSameAsMainRoom(LiveRoom room) {
    if (!Get.isRegistered<LivePlayController>()) return false;
    final main = Get.find<LivePlayController>().state.value.room.detail;
    if (main == null) return false;
    return main.roomId == room.roomId && main.platform == room.platform;
  }

  /// 拉取房间完整详情并回填到槽位（弹幕能力的惰性补充）。
  ///
  /// 侧栏卡片只有列表元数据，而 B站/虎牙等平台的弹幕连接参数（danmakuData：
  /// token、真实房间号、WebSocket 地址等）仅由 getRoomDetail 下发。不回填时
  /// [MultiviewDanmakuSession.supportsRoom] 恒为 false，弹幕显隐按钮会被
  /// [toggleDanmaku] 直接拒绝开启——表现为"按钮无效"。
  ///
  /// 仅在用户**首次开启弹幕**时调用，不挂在起播路径上，避免为默认关闭的
  /// 弹幕能力让每次开小窗都多付一次详情请求与首帧延迟。已携带弹幕参数
  /// （如主窗口曾进入过该房间）时直接跳过，不重复请求。
  ///
  /// 失败时保留卡片房间（仅弹幕不可用），由调用方决定按钮状态。
  Future<void> _enrichRoomDetail(MiniPipSlot slot) async {
    final room = slot.room;
    final platform = room.platform;
    final roomId = room.roomId;
    if (platform == null || roomId == null || roomId.isEmpty) return;
    // 卡片房间已带弹幕参数（主窗口进过、或此前已回填）：无需再请求。
    if (MultiviewDanmakuSession.supportsRoom(room)) return;
    try {
      final detail = await Sites.of(platform).liveSite.getRoomDetail(roomId: roomId, platform: platform);
      // 只接受身份一致的详情，避免异常的短号/别名映射污染槽位身份。
      if (slots.contains(slot) && detail.hasIdentity(platform: platform, roomId: roomId)) {
        slot.room = detail;
      }
    } catch (error, stackTrace) {
      developer.log(
        'MiniPip: room detail enrich failed for $platform/$roomId',
        name: 'MiniPip',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 切换弹幕显隐；首次开启时惰性拉取房间详情并创建弹幕会话。
  Future<void> toggleDanmaku(MiniPipSlot slot) async {
    if (_disposed || !slots.contains(slot)) return;
    final enable = !slot.danmakuEnabled.value;
    if (enable && !MultiviewDanmakuSession.supportsRoom(slot.room)) {
      // 上一次点击的详情补全仍在途：忽略连点，按钮会随在途流程翻转。
      if (slot.danmakuEnriching) return;
      slot.danmakuEnriching = true;
      // 卡片房间缺少弹幕连接参数：惰性拉取一次完整详情。只在此时付费，
      // 起播路径不增加任何请求；主窗口进过该房间时 supportsRoom 直接放行。
      try {
        await _enrichRoomDetail(slot);
      } finally {
        slot.danmakuEnriching = false;
      }
      if (_disposed || !slots.contains(slot)) return;
      if (!MultiviewDanmakuSession.supportsRoom(slot.room)) {
        // 平台本身无弹幕实现，或详情拉取后仍无可用参数：保持关闭态，
        // 避免按钮状态与实际表现不一致。
        slot.danmakuEnabled.value = false;
        return;
      }
    }
    slot.danmakuEnabled.value = enable;
    if (!enable) {
      await slot._danmakuSession?.disconnect();
      slot._danmakuSession = null;
      return;
    }
    await _connectDanmaku(slot);
  }

  /// 惰性创建并连接弹幕会话。已存在则直接重连（retry 场景）。
  Future<void> _connectDanmaku(MiniPipSlot slot) async {
    if (slot._danmakuSession == null) {
      slot.barrageController ??= BarrageController();
      final barrage = slot.barrageController!;
      slot._danmakuSession = MultiviewDanmakuSession(
        engineFactory: (room) => Sites.of(room.platform!).liveSite.getDanmaku(),
        onChatMessage: (message) {
          barrage.send(
            BarrageItem(
              content: message.message,
              userId: message.userId,
              userName: message.userName,
              textColor: Color.fromARGB(255, message.color.r, message.color.g, message.color.b),
            ),
          );
        },
      );
    }
    try {
      await slot._danmakuSession!.connect(slot.room);
    } catch (error, stackTrace) {
      developer.log('MiniPip: danmaku connect failed', name: 'MiniPip', error: error, stackTrace: stackTrace);
    }
  }

  /// 起播成功后，将 slot 记录的状态一次性同步到新 player handle：
  /// 播放态、静音、音量、弹幕会话。根治 retry/首帧后按钮状态与实际脱节。
  void _applySlotStateToPlayer(MiniPipSlot slot) {
    final handle = slot.player;
    if (handle == null) return;
    // start: true 起播，按钮应显示暂停态；playingStream 随后会校验真实值。
    slot.isPlaying.value = true;
    handle.setMuted(slot.muted.value);
    if (!slot.muted.value) {
      handle.setVolume(slot.volume.value);
    }
    if (slot.danmakuEnabled.value) {
      unawaited(_connectDanmaku(slot));
    }
  }

  /// 切换单窗静音；取消静音时若音量为 0 则恢复到 0.5，避免"取消静音却无声"。
  Future<void> toggleMute(MiniPipSlot slot) async {
    if (_disposed || !slots.contains(slot)) return;
    final muted = !slot.muted.value;
    slot.muted.value = muted;
    if (!muted && slot.volume.value <= 0.001) {
      slot.volume.value = 0.5;
    }
    await slot.player?.setMuted(muted);
    if (!muted) {
      await slot.player?.setVolume(slot.volume.value);
    }
  }

  /// 由音量条设置音量（0.0~1.0）；大于 0 自动取消静音，等于 0 自动静音。
  Future<void> setVolume(MiniPipSlot slot, double volume) async {
    if (_disposed || !slots.contains(slot)) return;
    final v = volume.clamp(0.0, 1.0).toDouble();
    slot.volume.value = v;
    final muted = v <= 0.001;
    slot.muted.value = muted;
    await slot.player?.setMuted(muted);
    if (!muted) {
      await slot.player?.setVolume(v);
    }
  }

  /// 播放/暂停切换。立即同步 isPlaying 以保证按钮即时响应，
  /// 随后 playingStream 会再次校验真实状态。
  Future<void> togglePlayPause(MiniPipSlot slot) async {
    if (_disposed || !slots.contains(slot)) return;
    final player = slot.player;
    if (player == null) return;
    if (player.isPlaying) {
      await player.pause();
      slot.isPlaying.value = false;
    } else {
      await player.resume();
      slot.isPlaying.value = true;
    }
  }

  /// 设置窗口不透明度（0.3~1.0）。
  void setOpacity(MiniPipSlot slot, double opacity) {
    if (!slots.contains(slot)) return;
    slot.opacity.value = opacity.clamp(minOpacity, maxOpacity).toDouble();
  }

  /// 更新窗口尺寸并重新协商原生输出分辨率（由视图层在边界钳制后调用）。
  void updateSize(MiniPipSlot slot, Size size) {
    if (!slots.contains(slot)) return;
    slot.size.value = size;
    _refreshMaxSlotSize();
  }

  /// 订阅播放器的解码视频宽高流，首帧到达后按实际比例调整窗口尺寸。
  ///
  /// 窗口比例跟随视频而非固定 16:9，竖屏直播不再出现上下黑边。尺寸保持
  /// 当前长边（用户已调整的大小），仅钳制到 [minLongSide]/[maxLongSide]。
  void _bindVideoDimensions(MiniPipSlot slot, MultiviewCellPlayerHandle handle) {
    slot.lastVideoWidth = null;
    slot.lastVideoHeight = null;
    slot._videoWidthSub = handle.videoWidthStream.distinct().listen((width) {
      if (_disposed || !slots.contains(slot)) return;
      slot.lastVideoWidth = width;
      _applyVideoAspectRatio(slot);
    });
    slot._videoHeightSub = handle.videoHeightStream.distinct().listen((height) {
      if (_disposed || !slots.contains(slot)) return;
      slot.lastVideoHeight = height;
      _applyVideoAspectRatio(slot);
    });
  }

  /// 已获得视频宽高时，按实际比例重算窗口尺寸并更新。
  void _applyVideoAspectRatio(MiniPipSlot slot) {
    final width = slot.lastVideoWidth;
    final height = slot.lastVideoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final ratio = width / height;
    slot.videoAspectRatio.value = ratio;
    final current = slot.size.value;
    final longSide = current.width > current.height ? current.width : current.height;
    final next = sizeForAspectRatio(ratio, longSide);
    // 比例变化或尺寸差异明显时才更新，避免流抖动导致的反复重建。
    if ((next.width - current.width).abs() > 0.5 || (next.height - current.height).abs() > 0.5) {
      slot.size.value = next;
      _refreshMaxSlotSize();
    }
  }

  /// 播放页退出/返回：拆除所有小窗，释放全部 libmpv 与弹幕会话。
  void disposeAll() {
    if (_disposed) return;
    _disposed = true;
    final all = List<MiniPipSlot>.from(slots);
    slots.clear();
    _refreshMaxSlotSize();
    for (final slot in all) {
      unawaited(_teardown(slot));
    }
  }

  /// 统一释放路径，与 multiview 一致：pause → disposePlayer，
  /// 渲染控制器的原生清理由 player.dispose 的 release 钩子完成，
  /// 应用层绝不直接销毁 VideoController（双重释放会触发崩溃）。
  Future<void> _teardown(MiniPipSlot slot, {bool keepSlot = false}) async {
    slot.epoch++;
    slot._sourceEndSub?.cancel();
    slot._sourceEndSub = null;
    slot._playingSub?.cancel();
    slot._playingSub = null;
    slot._videoWidthSub?.cancel();
    slot._videoWidthSub = null;
    slot._videoHeightSub?.cancel();
    slot._videoHeightSub = null;
    slot.lastVideoWidth = null;
    slot.lastVideoHeight = null;
    slot.isPlaying.value = false;
    try {
      await slot._danmakuSession?.disconnect();
    } catch (error, stackTrace) {
      developer.log('MiniPip: danmaku disconnect failed', name: 'MiniPip', error: error, stackTrace: stackTrace);
    }
    slot._danmakuSession = null;
    final handle = slot.player;
    slot.player = null;
    if (handle == null) return;
    try {
      await handle.pause();
      await handle.disposePlayer();
    } catch (error, stackTrace) {
      developer.log(
        'MiniPip: player teardown failed for ${slot.room.platform}/${slot.room.roomId}',
        name: 'MiniPip',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // keepSlot 仅用于错误/离线态保留窗口壳以展示重试 UI；此时句柄已释放。
    if (!keepSlot && slot.barrageController != null) {
      // BarrageController 无显式释放要求（与 multiview 用法一致），随 GC 回收。
    }
  }
}
