import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/widgets/local_interaction/local_interaction_controller.dart';
import 'package:pure_live/modules/live_play/widgets/local_interaction/local_danmaku_style_editor.dart';

class LocalInteractionSheet extends StatefulWidget {
  const LocalInteractionSheet({super.key, required this.controller, required this.platform, required this.onMessage});

  final LocalInteractionController controller;
  final String platform;
  final void Function(LiveMessage message, bool showAsDanmaku) onMessage;

  @override
  State<LocalInteractionSheet> createState() => _LocalInteractionSheetState();
}

class _LocalInteractionSheetState extends State<LocalInteractionSheet> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _scMessageController = TextEditingController();
  final TextEditingController _scPriceController = TextEditingController(text: '50');
  final TextEditingController _scDurationController = TextEditingController(text: '60');
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.controller.userName.v);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scMessageController.dispose();
    _scPriceController.dispose();
    _scDurationController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _sendChat() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    widget.onMessage(widget.controller.createChat(text, platform: widget.platform), widget.controller.showAsDanmaku.v);
    _messageController.clear();
  }

  void _sendSuperChat() {
    final text = _scMessageController.text.trim();
    if (text.isEmpty) return;
    final price = int.tryParse(_scPriceController.text.trim()) ?? 0;
    final duration = int.tryParse(_scDurationController.text.trim()) ?? 60;
    final message = widget.controller.sendSuperChat(content: text, price: price, durationSeconds: duration);
    if (message == null) return;
    // SC 卡片不走弹幕通道，showAsDanmaku 固定 false。
    widget.onMessage(message, false);
    _scMessageController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.controller;
    final gifts = LocalInteractionController.giftsForPlatform(widget.platform);
    final pack = LocalInteractionController.packForPlatform(widget.platform);
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(i18n('local_interaction_title'), style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
              Text(i18n('local_interaction_desc'), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      maxLength: 20,
                      decoration: InputDecoration(labelText: i18n('local_user_name'), counterText: ''),
                      onSubmitted: local.updateName,
                      onChanged: local.updateName,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Obx(
                    () => Chip(
                      avatar: const Icon(Icons.toll_rounded, size: 18),
                      label: Text('${local.coins.v} ${i18n(pack.currencyKey)} · ${i18n(pack.levelKey)} ${local.level}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(i18n('local_title_select'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Obx(
                () => Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: LocalInteractionController.titles
                      .map(
                        (title) => ChoiceChip(
                          label: Text(i18n('local_title_$title')),
                          selected: local.selectedTitle.v == title,
                          onSelected: (_) => local.selectedTitle.v = title,
                        ),
                      )
                      .toList(),
                ),
              ),
              Obx(
                () => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i18n('local_overlay_message')),
                  subtitle: Text(i18n('local_overlay_message_desc')),
                  value: local.showAsDanmaku.v,
                  onChanged: (value) => local.showAsDanmaku.v = value,
                ),
              ),
              ExpansionTile(
                key: const ValueKey('local-interaction-danmaku-style'),
                tilePadding: EdgeInsets.zero,
                leading: const Icon(Icons.auto_awesome_rounded),
                title: Text(i18n('local_danmaku_style')),
                subtitle: Text(i18n('local_danmaku_style_sync_desc')),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: LocalDanmakuStyleEditor(controller: local, compact: true),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendChat(),
                      decoration: InputDecoration(hintText: i18n('local_message_hint')),
                    ),
                  ),
                  IconButton.filled(onPressed: _sendChat, icon: const Icon(Icons.send_rounded)),
                ],
              ),
              const SizedBox(height: 16),
              Text(i18n('local_super_chat'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _scMessageController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendSuperChat(),
                      decoration: InputDecoration(hintText: i18n('local_super_chat_hint')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _scPriceController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(hintText: '￥', labelText: '￥'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _scDurationController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(hintText: 's', labelText: 's', suffixText: 's'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(onPressed: _sendSuperChat, icon: const Icon(Icons.local_fire_department_rounded)),
                ],
              ),
              const SizedBox(height: 16),
              Text(i18n('local_gift_center'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: .9,
                ),
                itemCount: gifts.length,
                itemBuilder: (context, index) {
                  final gift = gifts[index];
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      final message = local.sendGift(gift, platform: widget.platform);
                      if (message == null) {
                        ToastUtil.show(i18n('local_coins_insufficient'));
                        return;
                      }
                      widget.onMessage(message, local.showAsDanmaku.v);
                    },
                    child: Ink(
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(gift.emoji, style: const TextStyle(fontSize: 28)),
                          Text(i18n(gift.nameKey), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text('${gift.price}', style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(i18n('local_experience_coins'), style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  for (final value in const [500, 2000, 10000])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: OutlinedButton(
                        onPressed: () {
                          local.recharge(value);
                        },
                        child: Text('+$value'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Obx(
                () => ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(i18n('local_history')),
                  children: local.history.isEmpty
                      ? [ListTile(contentPadding: EdgeInsets.zero, title: Text(i18n('local_history_empty')))]
                      : local.history
                            .take(10)
                            .map((entry) => ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(entry)))
                            .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
