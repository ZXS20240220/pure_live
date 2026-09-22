import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pure_live/common/style/app_text_styles.dart';
import 'package:pure_live/common/utils/toast_util.dart';
import 'package:pure_live/plugins/locale_helper.dart';

/// 内嵌网页（网页搜索 / Cookie 抓取 / B 站网页登录）共用的地址栏。
///
/// 展示当前页面网址；点击后全选文本，可直接编辑并回车（或点击跳转按钮）
/// 加载新地址；右侧按钮一键复制当前网址。编辑中外部网址变化不回写，
/// 失焦未提交则还原为当前实际网址。
class WebViewAddressBar extends StatefulWidget {
  const WebViewAddressBar({super.key, required this.currentUrl, required this.onSubmit});

  /// 外部同步的当前网址（页面加载回调中更新）。
  final String currentUrl;

  /// 用户提交新网址；参数为规范化后的 http(s) 地址。
  final ValueChanged<String> onSubmit;

  @override
  State<WebViewAddressBar> createState() => _WebViewAddressBarState();
}

class _WebViewAddressBarState extends State<WebViewAddressBar> {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.currentUrl);
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant WebViewAddressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 编辑中不覆盖用户正在输入的内容。
    if (!_editing && widget.currentUrl != oldWidget.currentUrl && _textController.text != widget.currentUrl) {
      _textController.text = widget.currentUrl;
    }
  }

  void _handleFocusChanged() {
    final editing = _focusNode.hasFocus;
    if (editing == _editing) return;
    setState(() => _editing = editing);
    if (editing) {
      // 获得焦点时全选，便于直接输入新地址或 Ctrl+C 复制。
      final text = _textController.text;
      _textController.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    } else if (_textController.text != widget.currentUrl) {
      // 失焦未提交则还原为当前实际网址。
      _textController.text = widget.currentUrl;
    }
  }

  void _submit(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      _focusNode.unfocus();
      return;
    }
    final candidate = text.contains('://') ? text : 'https://$text';
    final uri = Uri.tryParse(candidate);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      ToastUtil.show(i18n('webview_address_invalid'));
      return;
    }
    _focusNode.unfocus();
    widget.onSubmit(uri.toString());
  }

  Future<void> _copyAddress() async {
    final text = widget.currentUrl.isNotEmpty ? widget.currentUrl : _textController.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    ToastUtil.show(i18n('copied_to_clipboard'));
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              style: AppTextStyles.t12,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: _submit,
              decoration: InputDecoration(
                isDense: true,
                hintText: i18n('webview_address_hint'),
                prefixIcon: const Icon(Icons.language_rounded, size: 16),
                prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                filled: true,
                fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: i18n('copy_link'),
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: _copyAddress,
          ),
        ],
      ),
    );
  }
}
