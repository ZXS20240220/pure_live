import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/favorite_room_controller.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';

class DanmakuMessageActions {
  DanmakuMessageActions._();

  static Future<void> show(BuildContext context, LiveMessage message) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Wrap(
            children: [
              _DanmakuInfoCard(message: message),
              ListTile(
                leading: const Icon(Icons.copy_all_rounded),
                title: Text(i18n('copy')),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await Clipboard.setData(ClipboardData(text: '${message.userName}: ${message.message}'));
                  ToastUtil.show(i18n('copied_to_clipboard'));
                },
              ),
              if (!message.isLocal && message.userName.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_off_rounded),
                  title: Text(i18n('block_danmaku_user')),
                  subtitle: Text(message.userName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    SettingsService.to.fav.addBlockedDanmakuUser(message.userName);
                    if (Get.isRegistered<LivePlayController>()) {
                      Get.find<LivePlayController>().removeDanmakuWhere(
                        (item) => item.userName.trim().toLowerCase() == message.userName.trim().toLowerCase(),
                      );
                    }
                    Navigator.of(sheetContext).pop();
                    ToastUtil.show(i18n('danmaku_user_blocked'));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.filter_alt_rounded),
                title: Text(i18n('block_danmaku_keyword')),
                subtitle: Text(message.message, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showKeywordDialog(sheetContext, message.message);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> showKeywordDialog(BuildContext context, String message) async {
    final keyword = await showDialog<String>(
      context: context,
      builder: (_) => _DanmakuKeywordDialog(initialText: message),
    );
    if (keyword == null || keyword.isEmpty) return;
    SettingsService.to.fav.addShieldList(keyword);
    if (Get.isRegistered<LivePlayController>()) {
      Get.find<LivePlayController>().removeDanmakuWhere(
        (item) => item.message.toLowerCase().contains(keyword.toLowerCase()),
      );
    }
    ToastUtil.show(i18n('danmaku_keyword_blocked'));
  }
}

class _DanmakuInfoCard extends StatelessWidget {
  const _DanmakuInfoCard({required this.message});
  final LiveMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.45);
    final borderColor = theme.colorScheme.primary.withValues(alpha: 0.25);

    final showUserLevel = message.userLevel.isNotEmpty && message.userLevel != '0';
    final showFansName = message.fansName.isNotEmpty;
    final showFansLevel = message.fansLevel.isNotEmpty && message.fansLevel != '0';
    final showFans = showFansName || showFansLevel;
    final showUserId = message.userId.isNotEmpty;
    final showSentAt = message.sentAt != null;
    final colorSwatch = Color.fromARGB(255, message.color.r, message.color.g, message.color.b);
    final isWhite = message.color.r == 255 && message.color.g == 255 && message.color.b == 255;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  message.userName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (message.isLocal)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '本地',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message.message,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (showUserLevel)
                _InfoChip(
                  icon: Icons.badge_outlined,
                  label: 'Lv.${message.userLevel}',
                  color: theme.colorScheme.primary,
                ),
              if (showFans)
                _InfoChip(
                  icon: Icons.shield_outlined,
                  label: [if (showFansName) message.fansName, if (showFansLevel) 'Lv.${message.fansLevel}'].join(' '),
                  color: theme.colorScheme.tertiary,
                ),
              if (showUserId)
                _InfoChip(icon: Icons.person_outline, label: message.userId, color: theme.colorScheme.secondary),
              if (!isWhite)
                _InfoChip(
                  icon: Icons.palette_outlined,
                  label:
                      '#${message.color.r.toRadixString(16).padLeft(2, '0')}'
                      '${message.color.g.toRadixString(16).padLeft(2, '0')}'
                      '${message.color.b.toRadixString(16).padLeft(2, '0')}',
                  color: colorSwatch,
                ),
              if (showSentAt)
                _InfoChip(
                  icon: Icons.schedule_outlined,
                  label: _formatSentAt(message.sentAt!),
                  color: theme.colorScheme.outline,
                ),
              if (message.type != LiveMessageType.chat)
                _InfoChip(icon: Icons.label_outline, label: _typeLabel(message.type), color: theme.colorScheme.outline),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatSentAt(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm:$ss';
    return '${local.month}/${local.day} $hh:$mm:$ss';
  }

  static String _typeLabel(LiveMessageType type) {
    switch (type) {
      case LiveMessageType.chat:
        return '聊天';
      case LiveMessageType.gift:
        return '礼物';
      case LiveMessageType.online:
        return '在线';
      case LiveMessageType.superChat:
        return '醒目留言';
    }
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textColor = color.computeLuminance() > 0.55 ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: textColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor, height: 1.2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _DanmakuKeywordDialog extends StatefulWidget {
  const _DanmakuKeywordDialog({required this.initialText});
  final String initialText;

  @override
  State<_DanmakuKeywordDialog> createState() => _DanmakuKeywordDialogState();
}

class _DanmakuKeywordDialogState extends State<_DanmakuKeywordDialog> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    // A dialog result completes before its exit transition unmounts TextField.
    // Keep the draft alive for exactly the dialog subtree's lifetime.
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(i18n('block_danmaku_keyword')),
    content: TextField(
      controller: _textController,
      autofocus: true,
      maxLength: FavoriteRoomController.maxShieldKeywordLength,
      decoration: InputDecoration(hintText: i18n('please_enter_keyword')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel'))),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_textController.text.trim()),
        child: Text(i18n('confirm')),
      ),
    ],
  );
}
