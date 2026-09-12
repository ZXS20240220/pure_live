import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/layout/super_chat_card.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';

class SuperChatPage extends StatelessWidget {
  const SuperChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LivePlayController>();

    return Obx(() {
      final messages = controller.superChats;
      final notice = controller.state.value.room.detail?.notice?.trim() ?? '';
      final hasNotice = notice.isNotEmpty;

      // 后手：两者都为空时不渲染（和原逻辑一致）
      if (messages.isEmpty && !hasNotice) {
        return const SizedBox.shrink();
      }

      final uniqueMessages = <String, LiveSuperChatMessage>{};
      for (final message in messages) {
        final key = message.messageId.isNotEmpty
            ? message.messageId
            : '${message.userName}|${message.message}|${message.price}|${message.startTime.microsecondsSinceEpoch}';
        uniqueMessages.putIfAbsent(key, () => message);
      }

      final list = uniqueMessages.values.toList();
      final itemCount = (hasNotice ? 1 : 0) + list.length;

      return ListView.builder(
        primary: false,
        physics: const PureLiveScrollPhysics(),
        padding: const EdgeInsets.all(8),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (hasNotice && index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _AiHighlightCard(text: notice),
            );
          }
          final messageIndex = hasNotice ? index - 1 : index;
          final message = list[messageIndex];
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: SuperChatCard(message));
        },
      );
    });
  }
}

/// AI 看点 / 主播公告的轻量提示卡片。
/// 仅当 [text] 非空时由 [SuperChatPage] 置顶渲染。
class _AiHighlightCard extends StatelessWidget {
  const _AiHighlightCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 后端用 \n\n 分隔 AI 看点标题和正文
    final parts = text.split('\n\n');
    final title = parts.isNotEmpty ? parts[0].trim() : '';
    final body = parts.length > 1 ? parts.sublist(1).join('\n\n').trim() : '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 16, color: colorScheme.onPrimaryContainer),
              const SizedBox(width: 6),
              Text(
                'AI 看点',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(i18n('toolbox_copy_success')),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                child: Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: colorScheme.primary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // AI 看点的短标题（从 API 的 summary/title 来）
          if (body.isNotEmpty) ...[
            Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            // describe 正文
            Text(
              body,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onPrimaryContainer, height: 1.5),
            ),
          ] else
            // 其他平台（快手/虎牙）或降级场景：没有标题/正文分离，直接全部显示
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onPrimaryContainer, height: 1.5),
            ),
        ],
      ),
    );
  }
}
