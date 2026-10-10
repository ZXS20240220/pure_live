import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_models.dart';

class ColorWallpaperPickerDialog extends StatefulWidget {
  final ColorWallpaperData? initial;

  const ColorWallpaperPickerDialog({super.key, this.initial});

  @override
  State<ColorWallpaperPickerDialog> createState() => _ColorWallpaperPickerDialogState();
}

class _ColorWallpaperPickerDialogState extends State<ColorWallpaperPickerDialog> {
  late bool _isGradient;
  late Color _color1;
  late Color _color2;
  late GradientDirection _direction;

  static const List<Color> _presetColors = [
    Color(0xFF1A1A2E),
    Color(0xFF16213E),
    Color(0xFF0F3460),
    Color(0xFF2C3E50),
    Color(0xFF34495E),
    Color(0xFF1E3A5F),
    Color(0xFF2D4059),
    Color(0xFF222831),
    Color(0xFF393E46),
    Color(0xFF1B1B2F),
    Color(0xFF162447),
    Color(0xFF1F4068),
  ];

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _isGradient = init != null && init.colors.length > 1;
    _color1 = init?.colors.first ?? const Color(0xFF1A1A2E);
    _color2 = init?.colors.elementAtOrNull(1) ?? const Color(0xFF16213E);
    _direction = init?.direction ?? GradientDirection.topToBottom;
  }

  ColorWallpaperData _buildData() {
    return ColorWallpaperData(colors: _isGradient ? [_color1, _color2] : [_color1], direction: _direction);
  }

  Future<void> _pickColor(bool isFirst) async {
    final initial = isFirst ? _color1 : _color2;
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFirst ? '选择颜色 1' : '选择颜色 2'),
        content: SingleChildScrollView(
          child: ColorPicker(
            color: initial,
            onColorChanged: (c) => setState(() {
              if (isFirst) {
                _color1 = c;
              } else {
                _color2 = c;
              }
            }),
            pickersEnabled: const {
              ColorPickerType.both: true,
              ColorPickerType.primary: true,
              ColorPickerType.accent: true,
              ColorPickerType.wheel: true,
              ColorPickerType.custom: true,
            },
            customColorSwatchesAndNames: {
              ColorSwatch<int>(0xFF1A1A2E, const {0: Color(0xFF1A1A2E)}): '深色1',
            },
            showColorCode: true,
            colorCodeHasColor: true,
            enableShadesSelection: false,
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('完成'))],
      ),
    );
    if (picked != null) {
      setState(() {
        if (isFirst) {
          _color1 = picked;
        } else {
          _color2 = picked;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _buildData();
    final previewGradient = data.toGradient();

    return AlertDialog(
      title: const Text('纯色 / 渐变壁纸'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 预览
            Container(
              height: 100,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: previewGradient,
                color: previewGradient == null ? data.colors.first : null,
              ),
            ),
            const SizedBox(height: 16),
            // 模式切换
            Row(
              children: [
                const Text('模式：'),
                ChoiceChip(
                  label: const Text('纯色'),
                  selected: !_isGradient,
                  onSelected: (_) => setState(() => _isGradient = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('渐变'),
                  selected: _isGradient,
                  onSelected: (_) => setState(() => _isGradient = true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 颜色 1
            Row(
              children: [
                GestureDetector(
                  onTap: () => _pickColor(true),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _color1,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.dividerColor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _color1.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase(),
                    style: AppTextStyles.t14,
                  ),
                ),
                TextButton(onPressed: () => _pickColor(true), child: const Text('选择')),
              ],
            ),
            if (_isGradient) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => _pickColor(false),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _color2,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.dividerColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _color2.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase(),
                      style: AppTextStyles.t14,
                    ),
                  ),
                  TextButton(onPressed: () => _pickColor(false), child: const Text('选择')),
                ],
              ),
              const SizedBox(height: 12),
              // 渐变方向
              Text('渐变方向', style: AppTextStyles.t14),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: GradientDirection.values.map((d) {
                  final selected = _direction == d;
                  return ChoiceChip(
                    label: Text(_directionLabel(d)),
                    selected: selected,
                    onSelected: (_) => setState(() => _direction = d),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 8),
            // 预设快速选择
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _presetColors.map((c) {
                final selected = !_isGradient && _color1.toARGB32() == c.toARGB32();
                return GestureDetector(
                  onTap: () => setState(() {
                    _isGradient = false;
                    _color1 = c;
                  }),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: selected ? theme.colorScheme.primary : theme.dividerColor,
                        width: selected ? 2 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_buildData()), child: const Text('应用')),
      ],
    );
  }

  String _directionLabel(GradientDirection d) {
    switch (d) {
      case GradientDirection.leftToRight:
        return '左→右';
      case GradientDirection.rightToLeft:
        return '右→左';
      case GradientDirection.topToBottom:
        return '上→下';
      case GradientDirection.bottomToTop:
        return '下→上';
      case GradientDirection.topLeftToBottomRight:
        return '左上→右下';
      case GradientDirection.topRightToBottomLeft:
        return '右上→左下';
      case GradientDirection.bottomLeftToTopRight:
        return '左下→右上';
      case GradientDirection.bottomRightToTopLeft:
        return '右下→左上';
      case GradientDirection.radial:
        return '径向';
    }
  }
}
