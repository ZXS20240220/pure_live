import 'dart:io';

import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/controllers/saved_wallpapers_controller.dart';
import 'package:pure_live/modules/wallpaper/services/wallpaper_thumbnail_service.dart';

/// 已保存壁纸网格中的一项
class SavedWallpaperTile extends StatefulWidget {
  const SavedWallpaperTile({
    super.key,
    required this.item,
    required this.isCurrent,
    required this.onTap,
    required this.onDelete,
  });

  final SavedWallpaperItem item;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<SavedWallpaperTile> createState() => _SavedWallpaperTileState();
}

class _SavedWallpaperTileState extends State<SavedWallpaperTile> {
  String? _thumbPath;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo) _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant SavedWallpaperTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path && widget.item.isVideo) {
      _thumbPath = null;
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final path = await WallpaperThumbnailService.to.getThumbnail(widget.item.path);
    if (mounted && path != null) setState(() => _thumbPath = path);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BorderRadius radius = BorderRadius.circular(14);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _artwork(theme),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                widget.item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  shadows: const <Shadow>[Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ),
            if (widget.item.isVideo)
              const Positioned(top: 6, left: 8, child: Icon(Remix.play_circle_line, color: Colors.white, size: 20)),
            Positioned(top: 4, right: 4, child: _DeleteButton(onPressed: widget.onDelete)),
            if (widget.isCurrent)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(color: theme.colorScheme.primary, width: 3),
                    ),
                  ),
                ),
              ),
            if (widget.isCurrent)
              Positioned(
                top: 4,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.check_line, size: 14, color: theme.colorScheme.onPrimary),
                      const SizedBox(width: 2),
                      Text('当前', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimary)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _artwork(ThemeData theme) {
    if (widget.item.isVideo) {
      if (_thumbPath != null) {
        return Image.file(
          File(_thumbPath!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _videoPlaceholder(theme),
        );
      }
      return _videoPlaceholder(theme);
    }
    final file = File(widget.item.path);
    if (!file.existsSync()) {
      return Center(child: Icon(Remix.image_line, color: theme.colorScheme.onSurfaceVariant, size: 36));
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) =>
          Center(child: Icon(Remix.image_line, color: theme.colorScheme.onSurfaceVariant, size: 36)),
    );
  }

  Widget _videoPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(Remix.film_line, color: theme.colorScheme.onSurfaceVariant, size: 36)),
    );
  }
}

class _DeleteButton extends StatefulWidget {
  const _DeleteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_DeleteButton> createState() => _DeleteButtonState();
}

class _DeleteButtonState extends State<_DeleteButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          opacity: _hovered ? 1.0 : 0.6,
          duration: const Duration(milliseconds: 150),
          child: CircleAvatar(
            radius: 11,
            backgroundColor: Colors.black54,
            child: Icon(Remix.delete_bin_line, size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
