import 'package:markdown_widget/config/configs.dart';
import 'package:markdown_widget/widget/all.dart';
import 'package:pure_live/common/index.dart';

import 'widgets/changes_summary_data.dart';

/// 修改总结页面：展示相对上游原始版本（liuchuancong/pure_live）的全部修改说明。
class ChangesSummaryPage extends StatelessWidget {
  const ChangesSummaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = (Get.isDarkMode ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig).copy(
      configs: [
        PConfig(
          textStyle:
              theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5) ??
              const TextStyle(),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: Text(i18n('changes_summary'))),
      body: SelectionArea(
        child: Scrollbar(
          child: SingleChildScrollView(
            physics: const PureLiveScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: MarkdownBlock(data: kChangesSummaryMarkdown, config: config),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
