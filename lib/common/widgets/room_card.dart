import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/cache_manager.dart';
import 'package:pure_live/routes/app_navigation.dart';
import 'package:pure_live/common/widgets/common_avatar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/common/utils/share_command_handler.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';
import 'package:pure_live/plugins/event_bus.dart';
import 'package:pure_live/common/services/settings/watch_time_service.dart';

class RoomCard extends StatelessWidget {
  const RoomCard({
    super.key,
    required this.room,
    this.dense = false,
    this.statusPending = false,
    this.statusPendingLabel,
    this.showDelete = false,
    this.onDelete,
    this.deleteTooltip,
    this.isPinned = false,
    this.isDormant = false,
    this.onTapOverride,
    this.dormantRefreshing = false,
  });
  final LiveRoom room;
  final bool dense;
  final bool statusPending;
  final String? statusPendingLabel;
  final bool showDelete;
  final VoidCallback? onDelete;
  final String? deleteTooltip;

  /// 是否判定为置顶房间（由调用方按 enablePinned + pinTagId 计算，5.1/5.2）。
  final bool isPinned;

  /// 是否为暂弃（下沉）房间：显示"已弃用"遮罩，强制显示删除按钮，隐藏置顶；
  /// 左键点击默认刷新该房间状态（行为由 [onTapOverride] 决定）。
  final bool isDormant;

  /// 覆盖默认的左键打开行为（暂弃卡片点击时刷新状态而非直接进入直播间）。
  final void Function(BuildContext context)? onTapOverride;

  /// 暂弃卡片正在单次刷新：遮罩中央以转圈动画暂时替代"已弃用"标识。
  final bool dormantRefreshing;
  Widget _buildCover(BuildContext context, bool isDark) {
    final coverUrl = normalizeNetworkImageUrl(room.cover);

    if (coverUrl.isEmpty) {
      return _coverFallback(context, isDark);
    }

    // Keep a stable image element and an encoded disk entry. The previous
    // global epoch rebuilt every visible Image.network at once, discarded the
    // old pixels and forced independent network/decode progress callbacks for
    // the full grid. That was the main source of mixed placeholders, flashes
    // and CPU spikes during refresh and tab switching.
    return Obx(() {
      final epoch = SettingsService.to.cache.imageCacheEpoch.value;
      return LayoutBuilder(
        builder: (context, constraints) {
          final logicalWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width / 2;
          final cacheWidth = (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round().clamp(240, 720).toInt();

          return CachedNetworkImage(
            imageUrl: coverUrl,
            cacheKey: epoch == 0 ? coverUrl : '$coverUrl#$epoch',
            httpHeaders: networkImageHeaders(coverUrl),
            cacheManager: CustomImageCacheManager.instance,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            memCacheWidth: cacheWidth,
            // maxWidthDiskCache: 720,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            useOldImageOnUrlChange: true,
            placeholder: (context, _) => _coverPlaceholder(context, isDark),
            errorWidget: (context, _, _) => _coverFallback(context, isDark),
          );
        },
      );
    });
  }

  Widget _coverPlaceholder(BuildContext context, bool isDark) {
    return Container(
      color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
      child: Center(
        // Do not create one infinite AnimationController per loading card. A
        // page of failed/slow covers used to repaint the complete grid at the
        // monitor refresh rate and could saturate Android CPU during startup.
        child: Icon(Icons.live_tv_rounded, size: 24, color: isDark ? Colors.white24 : Colors.black12),
      ),
    );
  }

  Widget _coverFallback(BuildContext context, bool isDark) {
    return Container(
      color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
      child: AppStatusView(type: AppStatusType.error, title: "", subtitle: "", isMini: true),
    );
  }

  /// 未开播时封面遮罩上的“上次直播”两行文本（5.x 开发版独有显示项）。
  String _offlineCoverText() {
    final ts = room.startTime;
    if (ts == null || ts <= 0) return i18n('offline');
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final y = dt.year;
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '${i18n('last_live_time_prefix')}\n$y-$mo-$d $h:$mi';
  }

  void onTap(BuildContext context) async {
    // Windows 桌面：按住 Ctrl 点击直接在悬浮窗中播放该房间。
    if (Platform.isWindows && HardwareKeyboard.instance.isControlPressed) {
      await GlobalPlayerService.instance.player.openAppFloatingFromRoom(room);
      return;
    }
    AppNavigator.toLiveRoomDetail(liveRoom: room);
  }

  static void showFollowDialog(
    BuildContext context,
    ThemeData theme, {
    required String anchorName,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            i18n('follow'),
            style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
          ),
          content: Text(
            i18n('dialog_follow_anchor_ask').replaceAll('{name}', anchorName),
            style: AppTextStyles.t14.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(i18n('cancel'), style: AppTextStyles.t14.copyWith(color: theme.colorScheme.secondary)),
            ),
            Theme(
              data: ThemeData(useMaterial3: true),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  onConfirm();
                },
                child: Text(
                  i18n('follow'),
                  style: AppTextStyles.t14.copyWith(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void onLongPress(BuildContext context) => showRoomInfoDialog(context, room);

  static void showRoomInfoDialog(BuildContext context, LiveRoom room) {
    final TagManagementController tagController = Get.find<TagManagementController>();
    final theme = Theme.of(context);
    final bool isFollowed = SettingsService.to.fav.isFavorite(room);
    // 观看时长与观众数据概览：全部读取内存/本地存储，不发网络请求。
    final watchSeconds = room.identityKey.isNotEmpty ? WatchTimeService.secondsFor(room.identityKey) : 0;
    final appSettings = SettingsService.to.app;
    final audienceValue = room.audienceValue(
      preferRealOnline: appSettings.preferRealOnlineCounts.v,
      platformEnabled: appSettings.isRealOnlineEnabledFor(room.platform),
    );
    final title = room.title?.trim() ?? '';
    final nick = room.nick?.trim() ?? '';
    final link = room.link?.trim() ?? '';
    final area = room.area?.trim() ?? '';
    final followers = room.followers?.trim() ?? '';
    final anchorLevel = room.anchorLevel?.trim() ?? '';
    final unionName = room.unionName?.trim() ?? '';
    final introduction = room.introduction?.trim() ?? '';
    final notice = room.notice?.trim() ?? '';
    final roomId = room.roomId?.trim() ?? '';
    final startTime = room.startTime;
    final lastWatchedAt = room.lastWatchedAt;

    // 直播状态：文案 + 语义色。
    final (statusText, statusColor) = switch (room.effectiveLiveStatus) {
      LiveStatus.live => (i18n('live'), const Color(0xFF43A047)),
      LiveStatus.replay => (i18n('replay'), const Color(0xFFF57C00)),
      LiveStatus.banned => (i18n('live_status_banned'), const Color(0xFFE53935)),
      LiveStatus.offline => (i18n('offline'), theme.colorScheme.onSurfaceVariant),
      LiveStatus.unknown => (i18n('live_status_unknown'), theme.colorScheme.onSurfaceVariant),
    };

    // 信息网格：有什么显示什么；每个单元格点击即复制其值。
    final cells = <Widget>[
      _RoomInfoCell(label: i18n('live_status'), value: statusText, valueColor: statusColor),
      if (audienceValue.isNotEmpty)
        _RoomInfoCell(label: i18n(room.audienceMetricI18nKey), value: readableCount(audienceValue)),
      if (LiveRoom.parseAudienceNumber(followers) > 0)
        _RoomInfoCell(label: i18n('fans_count'), value: readableCount(followers)),
      if (area.isNotEmpty) _RoomInfoCell(label: i18n('room_area'), value: area),
      if (startTime != null && startTime > 0)
        _RoomInfoCell(label: i18n('live_start_time'), value: _formatTimestamp(startTime * 1000)),
      if (anchorLevel.isNotEmpty && anchorLevel != '0')
        _RoomInfoCell(label: i18n('anchor_level'), value: 'Lv.$anchorLevel'),
      if (unionName.isNotEmpty) _RoomInfoCell(label: i18n('union_name'), value: unionName),
      if (lastWatchedAt != null && lastWatchedAt > 0)
        _RoomInfoCell(label: i18n('last_watched'), value: _formatTimestamp(lastWatchedAt)),
      if (watchSeconds > 0)
        _RoomInfoCell(label: i18n('watch_time_total'), value: WatchTimeService.formatCompact(watchSeconds)),
      if (roomId.isNotEmpty) _RoomInfoCell(label: i18n('room_id'), value: roomId),
    ];
    final infoRows = <Widget>[];
    for (var i = 0; i < cells.length; i += 2) {
      infoRows.add(
        Row(
          children: [
            Expanded(child: cells[i]),
            if (i + 1 < cells.length) Expanded(child: cells[i + 1]) else const Spacer(),
          ],
        ),
      );
    }

    Get.dialog(
      AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Tooltip(
                message: Sites.of(room.platform!).name,
                waitDuration: const Duration(milliseconds: 400),
                child: Image.asset(Sites.of(room.platform!).logo, width: 28, height: 28),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Tooltip(
                message: nick,
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: () => _copyText(context, nick),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      nick,
                      style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),

            IconButton(
              tooltip: i18n('share'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(RemixIcons.share_forward_line, size: 20, color: theme.colorScheme.primary),
              onPressed: () {
                Navigator.pop(context);
                ShareCommandHandler.instance.onShareRoomPressed(room);
              },
            ),
            SizedBox(width: 6),
            IconButton(
              tooltip: i18n('set_room_tags'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(
                Remix.price_tag_3_line,
                size: 20,
                color: isFollowed ? theme.colorScheme.primary : theme.disabledColor.withValues(alpha: 0.6),
              ),
              onPressed: () {
                Navigator.pop(context);
                if (isFollowed) {
                  unawaited(showTagSelectionGridModal(context, theme, tagController, room));
                } else {
                  SmartDialog.showToast(i18n('tags_need_follow_tip'));
                  showFollowDialog(
                    context,
                    theme,
                    anchorName: room.nick ?? '',
                    onConfirm: () {
                      SettingsService.to.fav.addRoom(room);
                      unawaited(showTagSelectionGridModal(context, theme, tagController, room));
                    },
                  );
                }
              },
            ),
          ],
        ),
        content: Container(
          width: double.maxFinite,
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty) ...[
                SizedBox(
                  width: double.infinity,
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.04), width: 0.8),
                    ),
                    child: InkWell(
                      onTap: () => _copyText(context, title),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Tooltip(
                          message: title,
                          waitDuration: const Duration(milliseconds: 400),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${i18n('title_label')}：',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text: title,
                                  style: AppTextStyles.t14.copyWith(
                                    color: theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w500,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (introduction.isNotEmpty) _RoomInfoParagraph(label: i18n('introduction'), text: introduction),
              if (notice.isNotEmpty) _RoomInfoParagraph(label: i18n('notice'), text: notice),
              if (introduction.isNotEmpty || notice.isNotEmpty) const SizedBox(height: 6),
              // 信息网格：每行两列，单元格点击即复制。
              ...infoRows,
              if (link.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: _RoomInfoCell(label: i18n('web_link'), value: link),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FollowButton(room: room),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(context),
            child: Text(
              i18n('close'),
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 点哪复制哪：复制任意信息并提示，不关闭弹窗。
  static Future<void> _copyText(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    ToastUtil.show(i18n('copied_to_clipboard'));
  }

  /// 毫秒时间戳 → yyyy-MM-dd HH:mm（本地时区）。
  static String _formatTimestamp(int millisecondsSinceEpoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 打开房间标签选择弹窗（开发版 3.2：进入时自动选中该房间已有标签）。
  /// 原为基础版私有实例方法；为供播放页 header（live_play_header）复用而静态化，
  /// 房间对象改为参数传入，弹窗内部逻辑与原实现完全一致。
  static Future<void> showTagSelectionGridModal(
    BuildContext context,
    ThemeData theme,
    TagManagementController tagController,
    LiveRoom room,
  ) async {
    final availableTagIds = tagController.tags.map((tag) => tag.id).toSet();
    final tempSelectedIds = tagController
        .getTagsForRoom(room)
        .where(availableTagIds.contains)
        .toSet()
        .toList(growable: true);
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final nameFocusNode = FocusNode();

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final bool isSmallScreen = screenWidth < 600;

    bool showAddSection = false;
    String? nameErrorText;
    final tagScrollController = ScrollController();
    void clearName(StateSetter setModalState) {
      nameController.clear();
      if (nameErrorText != null) setModalState(() => nameErrorText = null);
      nameFocusNode.requestFocus();
    }

    void submitNewTag(StateSetter setModalState) {
      final name = nameController.text.trim();
      final validation = tagController.validateTagName(name);
      if (validation != TagNameValidation.valid) {
        setModalState(() {
          nameErrorText = switch (validation) {
            TagNameValidation.empty => i18n('tag_name_empty_error'),
            TagNameValidation.duplicate => i18n('tag_name_duplicate_error'),
            TagNameValidation.valid => null,
          };
        });
        nameFocusNode.requestFocus();
        return;
      }
      if (!tagController.addTag(name, descController.text)) {
        setModalState(() => nameErrorText = i18n('tag_invalid_or_duplicate'));
        nameFocusNode.requestFocus();
        return;
      }
      final newTag = tagController.tags.firstWhere((tag) => tag.name.toLowerCase() == name.toLowerCase());
      tempSelectedIds.add(newTag.id);
      nameController.clear();
      descController.clear();
      nameFocusNode.unfocus();
      setModalState(() {
        nameErrorText = null;
        showAddSection = false;
      });
    }

    await Get.dialog<void>(
      StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
          titlePadding: EdgeInsets.fromLTRB(16, MediaQuery.textScalerOf(context).scale(1) >= 2 ? 8 : 24, 16, 0),
          contentPadding: MediaQuery.textScalerOf(context).scale(1) >= 2
              ? const EdgeInsets.fromLTRB(12, 8, 12, 4)
              : const EdgeInsets.fromLTRB(28, 20, 28, 12),
          actionsPadding: MediaQuery.textScalerOf(context).scale(1) >= 2
              ? const EdgeInsets.fromLTRB(8, 0, 8, 8)
              : const EdgeInsets.fromLTRB(20, 0, 20, 20),
          insetPadding: isSmallScreen
              ? EdgeInsets.symmetric(
                  horizontal: screenWidth * 0.05,
                  vertical: MediaQuery.textScalerOf(context).scale(1) >= 2 ? 8 : 24,
                )
              : const EdgeInsets.symmetric(horizontal: 40.0, vertical: 24.0),
          title: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: showAddSection ? 4 : 12),
                  child: Text(
                    i18n('set_room_tags'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.4),
                  ),
                ),
              ),
              showAddSection
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('room-tag-cancel-new'),
                          tooltip: i18n('cancel'),
                          onPressed: () {
                            nameController.clear();
                            descController.clear();
                            nameFocusNode.unfocus();
                            setModalState(() {
                              nameErrorText = null;
                              showAddSection = false;
                            });
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                        IconButton(
                          key: const ValueKey('room-tag-submit-new'),
                          tooltip: i18n('add_tag'),
                          onPressed: () => submitNewTag(setModalState),
                          icon: const Icon(Icons.check_rounded),
                        ),
                      ],
                    )
                  : IconButton(
                      tooltip: i18n('add_tag'),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      icon: Icon(Remix.add_circle_line, size: 20, color: theme.colorScheme.primary),
                      onPressed: () {
                        setModalState(() {
                          showAddSection = true; // Slide open text fields inputs section block
                        });
                      },
                    ),
            ],
          ),
          content: Container(
            width: isSmallScreen ? screenWidth : 440,
            constraints: BoxConstraints(
              maxHeight: isSmallScreen
                  ? screenHeight * (MediaQuery.textScalerOf(context).scale(1) >= 2 ? 0.30 : 0.54)
                  : 390,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showAddSection)
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('room-tag-add-form-scroll'),
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.03), width: 0.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              i18n('add_tag'),
                              style: AppTextStyles.t12.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              key: const ValueKey('room-tag-name'),
                              controller: nameController,
                              focusNode: nameFocusNode,
                              autofocus: true,
                              maxLength: 15,
                              maxLines: 1,
                              textInputAction: TextInputAction.next,
                              onChanged: (_) {
                                if (nameErrorText != null) setModalState(() => nameErrorText = null);
                              },
                              style: AppTextStyles.t13.copyWith(fontWeight: FontWeight.w500),
                              decoration: InputDecoration(
                                hintText: i18n('tag_input_hint'),
                                errorText: nameErrorText,
                                counterText: '',
                                hintStyle: TextStyle(color: theme.hintColor.withValues(alpha: 0.5)),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: theme.dividerColor.withValues(alpha: 0.05)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                    width: 1.2,
                                  ),
                                ),
                                errorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.75)),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: theme.colorScheme.error, width: 1.2),
                                ),
                                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: nameController,
                                  builder: (context, value, _) => value.text.isNotEmpty
                                      ? Semantics(
                                          key: const ValueKey('room-tag-clear-name'),
                                          container: true,
                                          excludeSemantics: true,
                                          label: i18n('clear_tag_name'),
                                          button: true,
                                          onTap: () => clearName(setModalState),
                                          child: IconButton(
                                            tooltip: i18n('clear_tag_name'),
                                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                            icon: const Icon(Icons.clear, size: 18),
                                            onPressed: () => clearName(setModalState),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              key: const ValueKey('room-tag-description'),
                              controller: descController,
                              maxLength: 40,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => submitNewTag(setModalState),
                              style: AppTextStyles.t13.copyWith(fontWeight: FontWeight.w500),
                              decoration: InputDecoration(
                                hintText: i18n('tag_desc_hint'),
                                counterText: '',
                                hintStyle: TextStyle(color: theme.hintColor.withValues(alpha: 0.5)),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: theme.dividerColor.withValues(alpha: 0.05)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                    width: 1.2,
                                  ),
                                ),
                                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: descController,
                                  builder: (context, value, _) => value.text.isNotEmpty
                                      ? Semantics(
                                          key: const ValueKey('room-tag-clear-description'),
                                          container: true,
                                          excludeSemantics: true,
                                          label: i18n('clear_tag_description'),
                                          button: true,
                                          onTap: descController.clear,
                                          child: IconButton(
                                            tooltip: i18n('clear_tag_description'),
                                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                            icon: const Icon(Icons.clear, size: 18),
                                            onPressed: descController.clear,
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (!showAddSection)
                  Expanded(
                    child: tagController.tags.isEmpty
                        ? SingleChildScrollView(
                            key: const ValueKey('room-tag-empty-scroll'),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Remix.price_tag_3_line,
                                    size: 36,
                                    color: theme.disabledColor.withValues(alpha: 0.4),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    i18n('no_tags_tip'),
                                    textAlign: TextAlign.center,
                                    style: AppTextStyles.t13.copyWith(color: theme.disabledColor),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Scrollbar(
                            controller: tagScrollController,
                            thumbVisibility: true,
                            thickness: 4.0,
                            radius: const Radius.circular(4),
                            child: GridView.builder(
                              key: const ValueKey('room-tag-assignment-list'),
                              controller: tagScrollController,
                              shrinkWrap: true,
                              physics: const PureLiveScrollPhysics(),
                              itemCount: tagController.tags.length,
                              padding: const EdgeInsets.only(right: 10, top: 4, bottom: 4, left: 2),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: isSmallScreen || MediaQuery.textScalerOf(context).scale(1) >= 1.6
                                    ? 1
                                    : 2,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                mainAxisExtent: MediaQuery.textScalerOf(context).scale(1) >= 2 ? 136 : 68,
                              ),
                              itemBuilder: (context, index) {
                                final tag = tagController.tags[index];
                                final isSelected = tempSelectedIds.contains(tag.id);
                                return Semantics(
                                  label: tag.name,
                                  selected: isSelected,
                                  button: true,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeInOut,
                                    child: InkWell(
                                      onTap: () {
                                        if (isSelected) {
                                          tempSelectedIds.remove(tag.id);
                                        } else {
                                          tempSelectedIds.add(tag.id);
                                        }
                                        setModalState(() {});
                                      },
                                      borderRadius: BorderRadius.circular(14),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? theme.colorScheme.primary.withValues(alpha: 0.06)
                                              : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: isSelected
                                                ? theme.colorScheme.primary
                                                : theme.dividerColor.withValues(alpha: 0.05),
                                            width: isSelected ? 1.4 : 0.6,
                                          ),
                                          boxShadow: isSelected
                                              ? [
                                                  BoxShadow(
                                                    color: theme.colorScheme.primary.withValues(alpha: 0.04),
                                                    blurRadius: 8,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    tag.name,
                                                    style: AppTextStyles.t13.copyWith(
                                                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                                      color: isSelected
                                                          ? theme.colorScheme.primary
                                                          : theme.colorScheme.onSurface,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  if (tag.description.isNotEmpty) ...[
                                                    const SizedBox(height: 3),
                                                    Text(
                                                      tag.description,
                                                      style: AppTextStyles.t11.copyWith(
                                                        color: theme.colorScheme.onSurfaceVariant.withValues(
                                                          alpha: 0.5,
                                                        ),
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            AnimatedContainer(
                                              duration: const Duration(milliseconds: 150),
                                              width: 18,
                                              height: 18,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                                                border: Border.all(
                                                  color: isSelected
                                                      ? Colors.transparent
                                                      : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
                                                  width: isSelected ? 0 : 1.5,
                                                ),
                                              ),
                                              child: isSelected
                                                  ? Icon(
                                                      Icons.check_rounded,
                                                      size: 12,
                                                      color: theme.colorScheme.onPrimary,
                                                    )
                                                  : null,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(context),
              child: Text(
                i18n('cancel'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              ),
              onPressed: showAddSection
                  ? null
                  : () async {
                      await tagController.setRoomTags(room, tempSelectedIds);
                      if (context.mounted) Navigator.pop(context);
                    },
              child: Text(i18n('confirm'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      descController.dispose();
      nameFocusNode.dispose();
      tagScrollController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // GridView already inserts a RepaintBoundary around every child. Avoid a
    // second composited layer per card and keep the cover clip lightweight.
    return Obx(() {
      final config = SettingsService.to.roomCard.current;
      final radius = config.cornerRadius;

      final showPinBadge = config.showPinBadge && isPinned && !isDormant;
      final effectiveShowDelete = showDelete || isDormant;
      return Card(
        key: const ValueKey('room-card-surface'),
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        color: isDark ? Colors.grey[900] : Colors.white,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          // 暂弃房间左键由 onTapOverride 决定（刷新状态），右键仍可触发弹窗
          onTap: () => (onTapOverride ?? onTap)(context),
          onLongPress: () => onLongPress(context),
          onSecondaryTap: () => onLongPress(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: ColoredBox(
                        color: isDark ? Colors.grey[850]! : Colors.grey.shade100,
                        child: _buildCover(context, isDark),
                      ),
                    ),
                  ),
                  // 暂弃房间优先显示"已弃用"遮罩，覆盖未开播遮罩
                  if (isDormant)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: isDark ? 0.65 : 0.55)),
                          child: Center(
                            // 单次刷新期间以转圈动画暂时替代"已弃用"标识。
                            child: dormantRefreshing
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: dense ? 20 : 28,
                                        height: dense ? 20 : 28,
                                        child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '刷新中…',
                                        maxLines: 1,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: dense ? 11 : 13,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.5,
                                          shadows: const [
                                            Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Remix.archive_line, size: dense ? 20 : 28, color: Colors.white70),
                                      const SizedBox(height: 4),
                                      Text(
                                        '已弃用',
                                        maxLines: 1,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: dense ? 11 : 14,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.5,
                                          shadows: const [
                                            Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    )
                  else if (config.showLastLiveTime && !room.isLiveNow)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.45)),
                          child: Center(
                            child: Text(
                              _offlineCoverText(),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: dense ? 11 : 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                                height: 1.4,
                                shadows: const [Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1))],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (config.showPlatformBadge)
                    Positioned(
                      key: const ValueKey('room-card-platform-badge'),
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 3 : 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          room.platform?.toUpperCase() ?? '',
                          style: AppTextStyles.t11.copyWith(
                            fontSize: dense ? 10 : null,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (config.showReplayBadge && room.isRecord == true)
                    Positioned(
                      key: const ValueKey('room-card-replay-badge'),
                      // 置顶徽章固定占用右上角 24px 槽位，回放徽章随之左移。
                      right: (effectiveShowDelete ? (dense ? 44 : 48) : 8) + (showPinBadge ? 24 : 0),
                      top: 8,
                      child: CountChip(
                        icon: Icons.videocam_rounded,
                        count: i18n("replay"),
                        dense: dense,
                        color: Get.theme.primaryColor,
                      ),
                    ),
                  // 置顶徽章（5.2）：右上角 24×24，primary 底色图钉图标。
                  if (showPinBadge)
                    Positioned(
                      key: const ValueKey('room-card-pin-badge'),
                      right: 8,
                      top: 8,
                      child: Tooltip(
                        message: i18n('favorite_pinned_badge'),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Icon(
                            RemixIcons.pushpin_fill,
                            color: Theme.of(context).colorScheme.onPrimary,
                            size: dense ? 14 : 16,
                          ),
                        ),
                      ),
                    ),
                  if (statusPending)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: CoverMetricBadge(
                        icon: Icons.sync_rounded,
                        value: statusPendingLabel ?? i18n('favorite_status_verifying'),
                        semanticLabel: statusPendingLabel ?? i18n('favorite_status_verifying'),
                        dense: dense,
                      ),
                    )
                  else if (config.showAudience && room.isLiveNow)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Obx(() {
                        final app = SettingsService.to.app;
                        final preferReal = app.preferRealOnlineCounts.v;
                        final platformEnabled = app.isRealOnlineEnabledFor(room.platform);
                        final type = room.audienceType(preferRealOnline: preferReal, platformEnabled: platformEnabled);
                        final value = room.audienceValue(
                          preferRealOnline: preferReal,
                          platformEnabled: platformEnabled,
                        );
                        final labelKey = switch (type) {
                          AudienceMetricType.popularity => 'audience_popularity',
                          AudienceMetricType.onlineViewers => 'audience_online',
                          AudienceMetricType.totalViewers => 'audience_total',
                          AudienceMetricType.followers => 'audience_followers',
                          AudienceMetricType.unknown => 'audience_count',
                        };
                        final displayValue = value.isEmpty ? i18n('audience_waiting') : readableCount(value);
                        final tooltipValue = value.isEmpty ? i18n('audience_waiting') : value;
                        return CoverMetricBadge(
                          key: const ValueKey('cover-audience-metric'),
                          icon: switch (type) {
                            AudienceMetricType.onlineViewers => Icons.people_alt_rounded,
                            AudienceMetricType.followers => Icons.favorite_rounded,
                            AudienceMetricType.totalViewers => Icons.visibility_rounded,
                            _ => Icons.whatshot_rounded,
                          },
                          value: displayValue,
                          semanticLabel: '${i18n(labelKey)} $tooltipValue',
                          dense: dense,
                        );
                      }),
                    ),
                  // 累计观看时长徽标（5.x）：封面左下角，Obx 响应式，无记录不占位。
                  if (config.showWatchTimeBadge && room.identityKey.isNotEmpty)
                    Positioned(
                      key: const ValueKey('room-card-watchtime-badge'),
                      left: 8,
                      bottom: 8,
                      child: Get.isRegistered<WatchTimeService>()
                          ? Obx(() {
                              final seconds = WatchTimeService.secondsFor(room.identityKey);
                              if (seconds <= 0) return const SizedBox.shrink();
                              return CoverMetricBadge(
                                icon: Icons.schedule_rounded,
                                value: WatchTimeService.formatCompact(seconds),
                                semanticLabel: '${i18n('watch_time_total')} ${WatchTimeService.formatFull(seconds)}',
                                dense: dense,
                              );
                            })
                          : const SizedBox.shrink(),
                    ),
                  if (effectiveShowDelete)
                    Positioned(
                      right: showPinBadge ? 32 : 0,
                      top: 0,
                      child: IconButton(
                        key: const ValueKey('room-card-delete'),
                        tooltip: deleteTooltip ?? (isDormant ? '移出暂时弃用' : i18n('delete')),
                        onPressed: onDelete,
                        padding: const EdgeInsets.all(10),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                          child: Icon(
                            isDormant ? RemixIcons.archive_line : RemixIcons.delete_bin_line,
                            color: Colors.white,
                            size: dense ? 16 : 18,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ListTile(
                dense: dense,
                minLeadingWidth: dense ? 34 : 40,
                contentPadding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12, vertical: dense ? 0 : 2),
                horizontalTitleGap: dense ? 8 : 12,
                leading: config.showAvatar
                    ? KeyedSubtree(
                        key: const ValueKey('room-card-avatar'),
                        child: CommonAvatar(avatarUrl: room.avatar, fallbackName: room.nick, dense: dense),
                      )
                    : null,
                title: Text(
                  room.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: (dense ? AppTextStyles.t13 : AppTextStyles.t15).copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                subtitle: config.showAnchorName
                    ? Text(
                        room.nick ?? '',
                        key: const ValueKey('room-card-anchor-name'),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: (dense ? AppTextStyles.t12 : AppTextStyles.t13).copyWith(
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.grey[400] : Colors.grey[700],
                        ),
                      )
                    : null,
                // 平台徽章只在封面左上角显示（config.showPlatformBadge），
                // 信息栏不再重复显示。
              ),
            ],
          ),
        ),
      );
    });
  }
}

class FollowButton extends StatefulWidget {
  const FollowButton({super.key, required this.room});

  final LiveRoom room;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  bool _busy = false;

  Future<void> _toggleFavorite(bool isFavorite) async {
    if (_busy) return;
    setState(() => _busy = true);

    final favorites = SettingsService.to.fav;
    try {
      if (!isFavorite) {
        final changed = favorites.addRoom(widget.room);
        if (changed) EventBus.instance.emit('changeFavorite', true);

        if (mounted && (changed || favorites.isFavorite(widget.room))) {
          Navigator.of(context).pop();
        }
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          title: Text(i18n('unfollow')),
          content: Text(i18n('unfollow_message', args: {'name': widget.room.nick ?? ''})),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(i18n('cancel'))),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(i18n('confirm'))),
          ],
        ),
      );

      if (!mounted || confirmed != true) return;

      final changed = favorites.removeRoom(widget.room);
      if (changed) EventBus.instance.emit('changeFavorite', true);
      if (!favorites.isFavorite(widget.room)) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final favoriteRooms = SettingsService.to.fav.favoriteRooms.value;
      final isFavorite = favoriteRooms.any((candidate) => candidate.hasSameIdentity(widget.room));

      return FilledButton.tonal(
        onPressed: _busy ? null : () => _toggleFavorite(isFavorite),
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
        child: Text(
          isFavorite ? i18n('unfollow') : i18n('follow'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    });
  }
}

class CountChip extends StatelessWidget {
  const CountChip({super.key, required this.icon, required this.count, this.dense = false, required this.color});

  final IconData icon;
  final String count;
  final bool dense;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: const StadiumBorder(),
      color: color,
      shadowColor: Colors.transparent,

      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12, vertical: dense ? 4 : 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: dense ? 16 : 18),
            const SizedBox(width: 4),
            Text(
              count,
              style: (dense ? AppTextStyles.t12 : AppTextStyles.t13).copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A cover metric stays compact and readable without obscuring thumbnails.
/// The full metric name remains available to accessibility and hover users.
class CoverMetricBadge extends StatelessWidget {
  const CoverMetricBadge({
    super.key,
    required this.icon,
    required this.value,
    required this.semanticLabel,
    this.dense = false,
  });

  final IconData icon;
  final String value;
  final String semanticLabel;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Keep the background mostly neutral so the badge works on both bright
    // and dark cover images. The theme primary color is used as the accent.
    final backgroundColor = theme.brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.black.withValues(alpha: 0.48);

    final foregroundColor = Colors.white;

    return Tooltip(
      message: semanticLabel,
      child: Semantics(
        label: semanticLabel,
        container: true,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 4 : 5),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(dense ? 10 : 12),
            border: Border.all(color: theme.primaryColor.withValues(alpha: 0.12), width: 0.6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foregroundColor, size: dense ? 14 : 16),
              SizedBox(width: dense ? 4 : 5),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: dense ? 11 : 12,
                  color: foregroundColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 房间信息弹窗的两列信息单元格：label：value，点击即复制 value。
class _RoomInfoCell extends StatelessWidget {
  const _RoomInfoCell({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      fontWeight: FontWeight.w600,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      color: valueColor ?? theme.colorScheme.onSurface,
      fontWeight: FontWeight.w700,
    );
    return InkWell(
      onTap: () => RoomCard._copyText(context, value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        child: Tooltip(
          message: value,
          waitDuration: const Duration(milliseconds: 400),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$label：', style: labelStyle),
                TextSpan(text: value, style: valueStyle),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

/// 房间信息弹窗的介绍/公告段落：完整文本块，点击即复制全文。
class _RoomInfoParagraph extends StatelessWidget {
  const _RoomInfoParagraph({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => RoomCard._copyText(context, text),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Tooltip(
              message: text,
              waitDuration: const Duration(milliseconds: 400),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$label：',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: text,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface, height: 1.45),
                    ),
                  ],
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
