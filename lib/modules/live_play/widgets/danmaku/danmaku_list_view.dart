import 'dart:async';
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_live/common/index.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/modules/live_play/states/ui_state.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_message_actions.dart';
import 'package:pure_live/modules/live_play/widgets/local_interaction/local_danmaku_style_editor.dart';

bool isDanmakuUserScrollStart(ScrollNotification notification, {bool acceptDirectionOnlyUserScroll = false}) {
  if (notification is ScrollStartNotification && notification.dragDetails != null) {
    return true;
  }
  if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
    return true;
  }
  if (acceptDirectionOnlyUserScroll) {
    if (notification is UserScrollNotification && notification.direction != ScrollDirection.idle) {
      return true;
    }
    if (notification is ScrollUpdateNotification && notification.scrollDelta != null && notification.scrollDelta != 0) {
      return true;
    }
  }
  return false;
}

@visibleForTesting
bool useEdgeToEdgeDanmakuList(double width) => width <= 680;

/// Invalidates tail-follow work that was queued before a user gesture.
///
/// `ScrollController.jumpTo` cancels an active drag. Message delivery used to
/// queue a jump for the next frame, then execute it even if the finger had
/// already started moving. A generation token makes that stale callback a
/// no-op before it reaches the controller.
@visibleForTesting
class DanmakuTailFollowGuard {
  int _revision = 0;

  int capture() => _revision;

  int invalidate() => ++_revision;

  bool isCurrent(int revision) => revision == _revision;
}

class DanmakuListView extends StatefulWidget {
  final LiveRoom room;

  const DanmakuListView({super.key, required this.room});

  @override
  State<DanmakuListView> createState() => DanmakuListViewState();
}

class DanmakuListViewState extends State<DanmakuListView> {
  final ScrollController _scrollController = createPureLiveScrollController();
  final TextEditingController _composerController = TextEditingController();

  static const Duration throttleDuration = Duration(milliseconds: 80);

  bool userScrolling = false;
  bool _autoScrollEnabled = true;
  bool _mouseInside = false;
  final ValueNotifier<int> _pendingMessageCount = ValueNotifier<int>(0);
  int _lastControllerLength = 0;
  LiveMessage? _lastControllerTail;
  List<LiveMessage> _visibleMessages = const [];
  final LinkedHashMap<LiveMessage, DanmakuItem> _itemCache = LinkedHashMap<LiveMessage, DanmakuItem>.identity();
  final DanmakuTailFollowGuard _tailFollowGuard = DanmakuTailFollowGuard();
  int _activeScrollPointers = 0;

  static const int _itemCacheCapacity = 160;

  Timer? throttleTimer;
  Worker? fullscreenWorker;
  Worker? windowFullscreenWorker;
  Worker? presentationWorker;
  StreamSubscription? messagesSub;
  StreamSubscription? removalsSub;

  LivePlayController get controller => Get.find<LivePlayController>();

  @override
  void initState() {
    super.initState();
    _visibleMessages = List<LiveMessage>.from(controller.danmakuMessages);
    _lastControllerLength = _visibleMessages.length;
    _lastControllerTail = _visibleMessages.isEmpty ? null : _visibleMessages.last;

    messagesSub = controller.danmakuMessages.listen((_) => _onMessagesChanged());
    removalsSub = controller.danmakuRemovals.listen((predicate) {
      if (!mounted) return;
      // A paused snapshot can contain rows already evicted from live history.
      // Remove only explicitly blocked rows; preserve unrelated frozen rows
      // and the user's paused position instead of replacing the snapshot.
      final filtered = _visibleMessages.where((message) => !predicate(message)).toList(growable: false);
      _itemCache.removeWhere((message, _) => predicate(message));
      if (filtered.length != _visibleMessages.length) setState(() => _visibleMessages = filtered);
    });

    fullscreenWorker = ever(GlobalPlayerState.to.isFullscreen, (value) {
      if (value == false && _autoScrollEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => forceScrollToBottom());
      }
    });

    windowFullscreenWorker = ever(GlobalPlayerState.to.isWindowFullscreen, (value) {
      if (value == false && _autoScrollEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => forceScrollToBottom());
      }
    });

    // LivePlayContent replaces the complete portrait subtree with the PiP
    // surface, so this State is normally disposed before isInPip becomes true
    // and recreated only after it is false. Listen to the persistent room
    // controller's presentation revision instead of trying to infer a
    // transition from this short-lived widget. The initial post-frame restore
    // also wins over synthetic viewport notifications emitted while Android
    // lays the portrait list out again.
    presentationWorker = ever<int>(controller.danmakuPresentationRevision, (_) => _scheduleLiveTailRestore());
    _scheduleLiveTailRestore();
  }

  void _onMessagesChanged() {
    if (!mounted) return;
    final currentMessages = controller.danmakuMessages;
    final nextLength = currentMessages.length;
    final nextTail = currentMessages.isEmpty ? null : currentMessages.last;
    final tailChanged = !identical(nextTail, _lastControllerTail);
    final lengthDelta = nextLength - _lastControllerLength;
    final addedCount = lengthDelta > 0 ? lengthDelta : (tailChanged ? 1 : 0);
    _lastControllerLength = nextLength;
    _lastControllerTail = nextTail;

    if (!_autoScrollEnabled) {
      if (addedCount > 0) {
        _pendingMessageCount.value = (_pendingMessageCount.value + addedCount).clamp(0, 9999);
      }
      return;
    }

    if (nextTail?.isLocal == true && addedCount > 0) {
      throttleTimer?.cancel();
      throttleTimer = null;
      setState(() => _visibleMessages = List<LiveMessage>.of(currentMessages, growable: false));
      WidgetsBinding.instance.addPostFrameCallback((_) => forceScrollToBottom());
      return;
    }

    throttleTimer ??= Timer(throttleDuration, () {
      throttleTimer = null;
      if (!mounted || !_autoScrollEnabled) return;
      setState(() => _visibleMessages = List<LiveMessage>.of(controller.danmakuMessages, growable: false));
      WidgetsBinding.instance.addPostFrameCallback((_) => forceScrollToBottom());
    });
  }

  @override
  void dispose() {
    _tailFollowGuard.invalidate();
    messagesSub?.cancel();
    removalsSub?.cancel();
    fullscreenWorker?.dispose();
    windowFullscreenWorker?.dispose();
    presentationWorker?.dispose();
    throttleTimer?.cancel();
    _composerController.dispose();
    _pendingMessageCount.dispose();
    _scrollController.dispose();
    _itemCache.clear();
    super.dispose();
  }

  Future<void> forceScrollToBottom() async {
    if (!mounted || !_autoScrollEnabled) return;
    final revision = _tailFollowGuard.capture();
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted ||
        !_autoScrollEnabled ||
        !_tailFollowGuard.isCurrent(revision) ||
        _activeScrollPointers > 0 ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions || position.isScrollingNotifier.value) return;
    if ((position.pixels - position.minScrollExtent).abs() > 0.5) {
      _scrollController.jumpTo(position.minScrollExtent);
    }
  }

  void _pauseAutoScroll() {
    _tailFollowGuard.invalidate();
    if (!_autoScrollEnabled) return;
    throttleTimer?.cancel();
    throttleTimer = null;
    setState(() {
      _autoScrollEnabled = false;
      userScrolling = true;
    });
    _pendingMessageCount.value = 0;
  }

  void _scheduleLiveTailRestore() {
    final revision = _tailFollowGuard.invalidate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _activeScrollPointers == 0 && _tailFollowGuard.isCurrent(revision)) {
        unawaited(_resumeAutoScroll());
      }
    });
  }

  Future<void> _resumeAutoScroll() async {
    if (!mounted || _activeScrollPointers > 0) return;
    _tailFollowGuard.invalidate();
    throttleTimer?.cancel();
    throttleTimer = null;
    final messages = controller.danmakuMessages;
    setState(() {
      _visibleMessages = List<LiveMessage>.from(messages);
      _autoScrollEnabled = true;
      userScrolling = false;
    });
    _lastControllerLength = messages.length;
    _lastControllerTail = messages.isEmpty ? null : messages.last;
    _pendingMessageCount.value = 0;
    await forceScrollToBottom();
  }

  Future<void> _clearMessages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(i18n('danmaku_clear_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(i18n('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(i18n('confirm'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    controller.clearDanmakuMessages();
    _itemCache.clear();
    _pendingMessageCount.value = 0;
    setState(() {
      _visibleMessages = const [];
      _autoScrollEnabled = true;
      userScrolling = false;
    });
  }

  void onScrollNotification(ScrollNotification notification) {
    if (!_scrollController.hasClients) return;

    // 滚回“直播边缘”（列表顶部）自动恢复跟随，无需点按钮。
    if (!_autoScrollEnabled && _isAtLiveEdge()) {
      _resumeAutoScroll();
      return;
    }

    final isDesktop = PlatformUtils.isDesktop;
    // Desktop mouse wheel: a single upward wheel notch emits a direction-only
    // UserScrollNotification and must lock the list immediately (previously
    // the first notch was swallowed). Touch keeps the active-pointer guard so
    // synthetic viewport notifications cannot pause live-follow.
    if (isDanmakuUserScrollStart(notification, acceptDirectionOnlyUserScroll: isDesktop)) {
      if (!isDesktop && _activeScrollPointers == 0) return;
      _pauseAutoScroll();
    }
  }

  bool _isAtLiveEdge() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return false;
    return (position.pixels - position.minScrollExtent).abs() < 1.5;
  }

  void _sendLocalMessage() {
    final text = _composerController.text.trim();
    final local = controller.localInteractionController;
    if (!local.enabled.v || text.isEmpty) return;
    controller.emitLocalMessage(
      local.createChat(text, platform: controller.site),
      showAsDanmaku: local.showAsDanmaku.v,
      delay: LivePlayController.localChatDeliveryDelay,
    );
    _composerController.clear();
    ToastUtil.show(i18n('local_message_queued'));
  }

  void _removeActiveScrollPointer() {
    if (_activeScrollPointers > 0) _activeScrollPointers--;
  }

  DanmakuItem _itemFor(LiveMessage message) {
    final cached = _itemCache.remove(message);
    if (cached != null) {
      _itemCache[message] = cached;
      return cached;
    }
    while (_itemCache.length >= _itemCacheCapacity) {
      _itemCache.remove(_itemCache.keys.first);
    }
    final item = DanmakuItem(key: ObjectKey(message), danmaku: message);
    _itemCache[message] = item;
    return item;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final edgeToEdge = useEdgeToEdgeDanmakuList(constraints.maxWidth);
        final radius = edgeToEdge ? BorderRadius.zero : BorderRadius.circular(10);
        return Container(
          key: const ValueKey('danmaku-list-surface'),
          margin: edgeToEdge ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: radius,
            border: edgeToEdge
                ? null
                : Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35), width: 0.5),
            boxShadow: edgeToEdge
                ? null
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Column(
              children: [
                Expanded(
                  child: MouseRegion(
                    onEnter: (_) {
                      if (!_mouseInside) setState(() => _mouseInside = true);
                    },
                    onExit: (_) {
                      if (_mouseInside) setState(() => _mouseInside = false);
                    },
                    child: Stack(
                      children: [
                        Listener(
                          onPointerDown: (_) {
                            _activeScrollPointers++;
                            // Cancel a queued live-tail jump at pointer-down, before
                            // touch slop delays the first ScrollStartNotification.
                            _tailFollowGuard.invalidate();
                          },
                          onPointerUp: (_) => _removeActiveScrollPointer(),
                          onPointerCancel: (_) => _removeActiveScrollPointer(),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              onScrollNotification(notification);
                              return false;
                            },
                            child: ScrollConfiguration(
                              behavior: const _DanmakuListScrollBehavior(),
                              child: ListView.builder(
                                key: const ValueKey('danmaku-message-list'),
                                addAutomaticKeepAlives: false,
                                addRepaintBoundaries: false,
                                controller: _scrollController,
                                reverse: true,
                                dragStartBehavior: DragStartBehavior.down,
                                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                physics: const PureLiveScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                                scrollCacheExtent: const ScrollCacheExtent.pixels(360),
                                itemCount: _visibleMessages.length,
                                itemBuilder: (_, index) {
                                  final msg = _visibleMessages[_visibleMessages.length - 1 - index];
                                  return _itemFor(msg);
                                },
                              ),
                            ),
                          ),
                        ),
                        if (_mouseInside)
                          Positioned(
                            right: 10,
                            top: 10,
                            child: IconButton.filled(
                              key: const ValueKey('danmaku-clear'),
                              tooltip: i18n('danmaku_clear'),
                              style: IconButton.styleFrom(
                                backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
                                foregroundColor: theme.colorScheme.onSurface,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: _clearMessages,
                              icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                            ),
                          ),
                        // Transparency for engine-side drops: the flame
                        // renderer discards over-age/overflow items the chat
                        // list never sees, so surface the count here.
                        Obx(() {
                          final dropped = controller.state.value.player.videoController?.droppedDanmakuCount.value ?? 0;
                          if (dropped <= 0) return const SizedBox.shrink();
                          return Positioned(
                            left: 10,
                            top: 10,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.visibility_off_outlined,
                                      size: 13,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      i18n('danmaku_dropped_hidden', args: {'count': '$dropped'}),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                        if (userScrolling)
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: FilledButton.icon(
                              key: const ValueKey('danmaku-resume-live'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.92),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                              label: ValueListenableBuilder<int>(
                                valueListenable: _pendingMessageCount,
                                builder: (context, count, _) => Text(
                                  count > 0
                                      ? i18n('danmaku_new_messages', args: {'count': '$count'})
                                      : i18n('scroll_to_bottom'),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              onPressed: _resumeAutoScroll,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Obx(() {
                  if (!controller.localInteractionController.enabled.v) return const SizedBox.shrink();
                  final state = controller.state.value;
                  final screenMode = state.ui.screenMode;
                  return Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _composerController,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _sendLocalMessage(),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: i18n('local_message_hint'),
                                  prefixIcon: IconButton(
                                    key: const ValueKey('portrait-local-danmaku-style'),
                                    tooltip: i18n('local_danmaku_style'),
                                    onPressed: () => showLocalDanmakuStyleEditor(
                                      context,
                                      controller: controller.localInteractionController,
                                    ),
                                    icon: Icon(
                                      Icons.auto_awesome_rounded,
                                      size: 19,
                                      color: screenMode == VideoMode.normal
                                          ? Theme.of(context).primaryColor
                                          : Color(controller.localInteractionController.danmakuColor.v),
                                    ),
                                  ),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.filled(
                              tooltip: i18n('local_send_message'),
                              onPressed: _sendLocalMessage,
                              icon: const Icon(Icons.send_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuListScrollBehavior extends MaterialScrollBehavior {
  const _DanmakuListScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.mouse,
    PointerDeviceKind.unknown,
  };
}

class DanmakuItem extends StatelessWidget {
  final LiveMessage danmaku;

  const DanmakuItem({super.key, required this.danmaku});

  Future<void> _copyMessage() async {
    await Clipboard.setData(ClipboardData(text: '${danmaku.userName}: ${danmaku.message}'));
    ToastUtil.show(i18n('copied_to_clipboard'));
  }

  Future<void> _showActions(BuildContext context) => DanmakuMessageActions.show(context, danmaku);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final baseColor = Color.fromARGB(255, danmaku.color.r, danmaku.color.g, danmaku.color.b);

    final vibrantColor =
        baseColor.toARGB32() == Colors.white.toARGB32() || baseColor.toARGB32() == Colors.black.toARGB32()
        ? (isDark ? Colors.white : Colors.black)
        : HSLColor.fromColor(baseColor).withLightness(isDark ? 0.75 : 0.52).withSaturation(1).toColor();

    final cardBgColor = isDark ? theme.cardColor.withValues(alpha: 0.65) : Colors.white.withValues(alpha: 0.72);

    final textColor = isDark ? Colors.white70 : Colors.black87;

    final showLevel = danmaku.userLevel.isNotEmpty && danmaku.userLevel != '0';
    final showFans = danmaku.fansLevel.isNotEmpty && danmaku.fansLevel != '0';
    final showRepeat = danmaku.repeatCount >= 2;

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cardBgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: vibrantColor.withValues(alpha: 0.08), width: 0.5),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTap: () => _showActions(context),
            onLongPress: () => _showActions(context),
            onDoubleTap: _copyMessage,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text.rich(
                TextSpan(
                  style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w500, color: textColor, height: 1.45),
                  children: [
                    if (showLevel)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: _LevelBadge(level: danmaku.userLevel, color: vibrantColor),
                        ),
                      ),
                    if (showFans)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: _FansBadge(fansName: danmaku.fansName, fansLevel: danmaku.fansLevel),
                        ),
                      ),
                    TextSpan(
                      text: '${danmaku.userName}: ',
                      style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w700, color: textColor),
                    ),
                    TextSpan(children: parseEmojis(danmaku.message, AppTextStyles.t14.fontSize!, textColor)),
                    if (showRepeat)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _RepeatBadge(count: danmaku.repeatCount, color: vibrantColor),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final String level;
  final Color color;
  const _LevelBadge({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    final textColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(4)),
      child: Text(
        level,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: textColor, height: 1.2),
      ),
    );
  }
}

class _FansBadge extends StatelessWidget {
  final String fansName;
  final String fansLevel;
  const _FansBadge({required this.fansName, required this.fansLevel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0x55FFFFFF), width: 0.5),
      ),
      child: Text(
        [fansName, fansLevel].where((s) => s.isNotEmpty).join(' '),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70, height: 1.2),
      ),
    );
  }
}

class _RepeatBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _RepeatBadge({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    final textColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(3)),
      child: Text(
        '×$count',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: textColor, height: 1.1),
      ),
    );
  }
}

/// A bounded LRU avoids retaining every unique chat line seen during an
/// overnight stream.  The old unbounded map was one of the main causes of the
/// steadily rising desktop heap.
const int emojiTokenCacheCapacity = 512;
final LinkedHashMap<String, List<EmojiToken>> emojiCache = LinkedHashMap<String, List<EmojiToken>>();

class EmojiToken {
  final bool isEmoji;
  final String value;

  const EmojiToken({required this.isEmoji, required this.value});
}

List<EmojiToken> _parseEmojiTokens(String text) {
  final cached = emojiCache[text];
  if (cached != null) {
    // LinkedHashMap does not reorder entries on lookup; reinsert to make this
    // a true least-recently-used cache.
    emojiCache.remove(text);
    emojiCache[text] = cached;
    return cached;
  }

  final regex = EmojiAtlas.instance.regex;

  if (regex == null) {
    final tokens = [EmojiToken(isEmoji: false, value: text)];
    _storeEmojiTokens(text, tokens);
    return tokens;
  }

  final tokens = <EmojiToken>[];

  int last = 0;

  for (final match in regex.allMatches(text)) {
    if (match.start > last) {
      tokens.add(EmojiToken(isEmoji: false, value: text.substring(last, match.start)));
    }

    tokens.add(EmojiToken(isEmoji: true, value: match.group(0)!));

    last = match.end;
  }

  if (last < text.length) {
    tokens.add(EmojiToken(isEmoji: false, value: text.substring(last)));
  }

  _storeEmojiTokens(text, tokens);

  return tokens;
}

void _storeEmojiTokens(String text, List<EmojiToken> tokens) {
  while (emojiCache.length >= emojiTokenCacheCapacity) {
    emojiCache.remove(emojiCache.keys.first);
  }
  emojiCache[text] = tokens;
}

List<InlineSpan> parseEmojis(String text, double size, Color color) {
  final tokens = _parseEmojiTokens(text);

  final spans = <InlineSpan>[];

  final style = TextStyle(fontSize: size, color: color);

  final emojiSize = size * 1.25;

  for (final token in tokens) {
    if (!token.isEmoji) {
      spans.add(TextSpan(text: token.value, style: style));
      continue;
    }

    final info = EmojiAtlas.instance.find(token.value);
    final image = info != null ? EmojiAtlas.instance.image(info.id) : null;

    if (image == null) {
      spans.add(TextSpan(text: token.value, style: style));
      continue;
    }

    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: RawImage(image: image, width: emojiSize, height: emojiSize),
      ),
    );
  }

  return spans;
}

class EmojiPainter extends CustomPainter {
  final ui.Image image;

  EmojiPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant EmojiPainter oldDelegate) {
    return oldDelegate.image != image;
  }
}
