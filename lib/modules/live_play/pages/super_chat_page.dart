import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/layout/super_chat_card.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';

class SuperChatPage extends StatefulWidget {
  const SuperChatPage({super.key});

  @override
  State<SuperChatPage> createState() => _SuperChatPageState();
}

class _SuperChatPageState extends State<SuperChatPage> {
  final _refreshController = EasyRefreshController(
    controlFinishRefresh: true,
    controlFinishLoad: true,
  );

  Future<void> _onRefresh() async {
    final controller = Get.find<LivePlayController>();
    await controller.refreshSuperChatAndHighlights();
    if (mounted) {
      _refreshController.finishRefresh(IndicatorResult.success);
      _refreshController.resetFooter();
    }
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LivePlayController>();

    return Obx(() {
      final messages = controller.superChats;
      final detail = controller.state.value.room.detail;
      final notice = detail?.notice?.trim() ?? '';
      final aiHighlights = detail?.aiHighlights;
      final hasHighlight = (aiHighlights != null && aiHighlights.isNotEmpty) || notice.isNotEmpty;
      final hasContent = messages.isNotEmpty || hasHighlight;

      final uniqueMessages = <String, LiveSuperChatMessage>{};
      for (final message in messages) {
        final key = message.messageId.isNotEmpty
            ? message.messageId
            : '${message.userName}|${message.message}|${message.price}|${message.startTime.microsecondsSinceEpoch}';
        uniqueMessages.putIfAbsent(key, () => message);
      }

      final list = uniqueMessages.values.toList();

      return SizedBox.expand(
        child: EasyRefresh(
          controller: _refreshController,
          onRefresh: _onRefresh,
          onLoad: () async => _refreshController.finishLoad(IndicatorResult.noMore),
          child: hasContent
              ? _AiHighlightOverlay(
                  aiHighlights: aiHighlights,
                  noticeText: notice,
                  child: ListView.builder(
                    primary: false,
                    padding: const EdgeInsets.all(8),
                    itemCount: (hasHighlight ? 1 : 0) + list.length,
                    itemBuilder: (context, index) {
                      if (hasHighlight && index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _AiHighlightCompact(
                            aiHighlights: aiHighlights,
                            noticeText: notice,
                          ),
                        );
                      }
                      final messageIndex = hasHighlight ? index - 1 : index;
                      final message = list[messageIndex];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SuperChatCard(message),
                      );
                    },
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: const Center(child: Text('暂无内容', style: TextStyle(fontSize: 12))),
                      ),
                    );
                  },
                ),
        ),
      );
    });
  }
}

class _AiHighlightOverlay extends StatefulWidget {
  const _AiHighlightOverlay({
    required this.child,
    required this.aiHighlights,
    required this.noticeText,
  });

  final Widget child;
  final List<Map<String, dynamic>>? aiHighlights;
  final String noticeText;

  @override
  State<_AiHighlightOverlay> createState() => _AiHighlightOverlayState();
}

class _AiHighlightOverlayState extends State<_AiHighlightOverlay> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  void _collapse() => setState(() => _expanded = false);

  @override
  Widget build(BuildContext context) {
    final hasData =
        (widget.aiHighlights != null && widget.aiHighlights!.isNotEmpty) ||
        widget.noticeText.isNotEmpty;

    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (_expanded && hasData)
          Positioned.fill(
            child: _AiHighlightExpanded(
              aiHighlights: widget.aiHighlights,
              noticeText: widget.noticeText,
              onCollapse: _collapse,
            ),
          ),
      ],
    );
  }
}

class _AiHighlightCompact extends StatelessWidget {
  const _AiHighlightCompact({required this.aiHighlights, required this.noticeText});

  final List<Map<String, dynamic>>? aiHighlights;
  final String noticeText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final first = aiHighlights?.first;
    final title = _extractTitle(first, noticeText);
    final body = _extractBody(first, noticeText);

    return Builder(
      builder: (context) {
        final overlayState = context.findAncestorStateOfType<_AiHighlightOverlayState>();
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: overlayState?._toggle,
            child: Container(
              padding: const EdgeInsets.all(10),
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
                      Icon(
                        Icons.visibility_outlined,
                        size: 15,
                        color: colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'AI 看点',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (first != null) ...[
                        const SizedBox(width: 10),
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: 14,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          _formatHeat(first['heat']),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTimeRange(first),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                      if (aiHighlights != null && aiHighlights!.length > 1) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${aiHighlights!.length}条',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _FadeTitle(
                    text: title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onPrimaryContainer, height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AiHighlightExpanded extends StatelessWidget {
  const _AiHighlightExpanded({
    required this.aiHighlights,
    required this.noticeText,
    required this.onCollapse,
  });

  final List<Map<String, dynamic>>? aiHighlights;
  final String noticeText;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = aiHighlights?.length ?? 0;
    final effectiveList = aiHighlights ?? const <Map<String, dynamic>>[];
    final hasNoticeOnly = aiHighlights == null && noticeText.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(8),
      color: colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCollapse,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.primary.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.visibility_outlined, size: 16, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    'AI 看点${count > 0 ? ' · $count条' : ''}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.keyboard_arrow_up, size: 18, color: colorScheme.onPrimaryContainer),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: hasNoticeOnly
                ? _NoticeOnlyBody(noticeText: noticeText)
                : ListView.separated(
                    physics: const PureLiveScrollPhysics(),
                    itemCount: effectiveList.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _HighlightItemCard(data: effectiveList[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HighlightItemCard extends StatelessWidget {
  const _HighlightItemCard({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = _extractTitle(data, '');
    final body = _extractBody(data, '');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _FadeTitle(
                  text: title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.local_fire_department_rounded, size: 13, color: Colors.orange.shade700),
              const SizedBox(width: 2),
              Text(
                _formatHeat(data['heat']),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.access_time_rounded,
                size: 12,
                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 2),
              Text(
                _formatTimeRange(data),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8)),
              ),
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onPrimaryContainer, height: 1.6),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoticeOnlyBody extends StatelessWidget {
  const _NoticeOnlyBody({required this.noticeText});

  final String noticeText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = _extractTitle(null, noticeText);
    final body = _extractBody(null, noticeText);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.w700),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: colorScheme.primary.withValues(alpha: 0.25)),
              const SizedBox(height: 10),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onPrimaryContainer, height: 1.7),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FadeTitle extends StatelessWidget {
  const _FadeTitle({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(text, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: style),
    );
  }
}

String _extractTitle(Map<String, dynamic>? data, String noticeText) {
  if (data != null) {
    final t = (data['summary'] ?? data['title'] ?? '').toString().trim();
    if (t.isNotEmpty) return t;
  }
  final parts = noticeText.split('\n\n');
  return parts.isNotEmpty ? parts[0].trim() : noticeText.trim();
}

String _extractBody(Map<String, dynamic>? data, String noticeText) {
  if (data != null) {
    final b = (data['describe'] ?? '').toString().trim();
    if (b.isNotEmpty) return b;
  }
  final parts = noticeText.split('\n\n');
  if (parts.length > 1) return parts.sublist(1).join('\n\n').trim();
  return '';
}

String _formatHeat(dynamic raw) {
  if (raw == null) return '';
  final n = int.tryParse(raw.toString());
  if (n == null) return raw.toString();
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
  return n.toString();
}

String _formatTimeRange(Map<String, dynamic> data) {
  final start = data['startTime'];
  final end = data['endTime'];
  if (start == null) return '';
  final startDt = DateTime.fromMillisecondsSinceEpoch((start as int) * 1000);
  final endDt = end != null && end != 0
      ? DateTime.fromMillisecondsSinceEpoch((end as int) * 1000)
      : DateTime.now();
  return '${_fmtTime(startDt)} ~ ${_fmtTime(endDt)}';
}

String _fmtTime(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
