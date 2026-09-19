import 'dart:io';

import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/event_bus.dart';

class FavoriteFloatingButton extends StatelessWidget {
  const FavoriteFloatingButton({super.key, required this.room, this.compact = false});

  final LiveRoom room;
  final bool compact;

  Future<void> _toggleFavorite(bool isFavorite) async {
    if (!isFavorite) {
      if (SettingsService.to.fav.addRoom(room)) {
        EventBus.instance.emit('changeFavorite', true);
      }
      return;
    }
    // Bind the actions to the dialog route itself. A global Get context may
    // point at the page navigator while routes are transitioning.
    final confirmed = await Get.dialog<bool>(
      Builder(
        builder: (dialogContext) => AlertDialog(
          title: Text(i18n('unfollow')),
          content: Text(i18n('unfollow_message', args: {'name': room.nick ?? ''})),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(i18n('cancel'))),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(i18n('confirm'))),
          ],
        ),
      ),
    );
    if (confirmed == true && SettingsService.to.fav.removeRoom(room)) {
      EventBus.instance.emit('changeFavorite', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Explicitly observe the persisted list. The former EventBus + local
      // setState path missed canonical room-id changes and external updates.
      final favoriteRooms = SettingsService.to.fav.favoriteRooms.value;
      final isFavorite = favoriteRooms.any((candidate) => candidate.hasSameIdentity(room));
      final label = i18n(isFavorite ? 'followed' : 'follow');

      if (compact) {
        return Tooltip(
          message: label,
          child: IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 38),
            padding: EdgeInsets.zero,
            onPressed: () => _toggleFavorite(isFavorite),
            icon: Icon(isFavorite ? Remix.heart_3_fill : Remix.heart_3_line, size: 19),
          ),
        );
      }
      return FilledButton(
        style: ButtonStyle(
          padding: WidgetStateProperty.all(Platform.isWindows ? const EdgeInsets.all(12) : const EdgeInsets.all(5)),
          backgroundColor: WidgetStateProperty.all(
            isFavorite ? Get.theme.colorScheme.primary.withAlpha(125) : Get.theme.colorScheme.primary,
          ),
          shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
          textStyle: WidgetStateProperty.all(AppTextStyles.t12),
          minimumSize: WidgetStateProperty.all(Size.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => _toggleFavorite(isFavorite),
        // Fans count sits inside the button, to the left of the follow label,
        // mirroring the platform web pages' hover cards.
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_fansText.isNotEmpty) ...[
              Tooltip(message: '订阅数:${room.followers?.trim() ?? ''}', child: Text(_fansText)),
              const SizedBox(width: 8),
              Container(width: 1, height: 12, color: Colors.white.withValues(alpha: 0.35)),
              const SizedBox(width: 8),
            ],
            Text(label),
          ],
        ),
      );
    });
  }

  /// Formatted fans count ('' when the platform leaves it empty). Numbers
  /// above 10k collapse to the 'x.x万' form used across the app.
  String get _fansText {
    final raw = room.followers?.trim() ?? '';
    if (raw.isEmpty || raw == '0' || raw == 'null') return '';
    return readableCount(raw);
  }
}
