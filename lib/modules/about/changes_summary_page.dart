import 'dart:convert';

import 'package:markdown_widget/config/configs.dart';
import 'package:markdown_widget/widget/all.dart';
import 'package:pure_live/common/index.dart';
import 'package:remixicon/remixicon.dart';

import 'widgets/changes_summary_data.dart';

/// 修改总结页面：正文 + 右侧可收放的章节目录导航。
///
/// 文档按 h2 章节切分为独立渲染段：目录点击用 GlobalKey 精确跳转，
/// 页面滚动时根据各段位置自动高亮当前章节。
class ChangesSummaryPage extends StatefulWidget {
  const ChangesSummaryPage({super.key});

  @override
  State<ChangesSummaryPage> createState() => _ChangesSummaryPageState();
}

class _ChangesSummaryPageState extends State<ChangesSummaryPage> {
  static const double _tocWidth = 240;
  static const Duration _animDuration = Duration(milliseconds: 240);

  late final List<_SummarySection> _sections;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<int> _currentSection = ValueNotifier(0);
  final ValueNotifier<bool> _tocExpanded = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _sections = _parseSections(kChangesSummaryMarkdown);
    _scrollController.addListener(_updateCurrentSection);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 宽窗口默认展开目录，窄窗口默认收起（右下角悬浮按钮可展开）。
      _tocExpanded.value = MediaQuery.of(context).size.width >= 1200;
      _updateCurrentSection();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateCurrentSection);
    _scrollController.dispose();
    _currentSection.dispose();
    _tocExpanded.dispose();
    super.dispose();
  }

  /// 将文档按 h2 标题切分：第一段为文档头（含主标题与引言），其后每个
  /// 「## 」开启一个章节段，段落内保留原始 markdown 交由 MarkdownBlock 渲染。
  List<_SummarySection> _parseSections(String source) {
    final sections = <_SummarySection>[];
    final buffer = StringBuffer();
    var level = 1;
    var title = '';

    void flush() {
      final text = buffer.toString().trim();
      if (text.isEmpty) return;
      sections.add(_SummarySection(level: level, title: title, markdown: text));
      buffer.clear();
    }

    for (final line in const LineSplitter().convert(source)) {
      if (line.startsWith('## ')) {
        flush();
        level = 2;
        title = line.substring(3).trim();
      }
      buffer.writeln(line);
    }
    flush();
    return sections;
  }

  /// 依据滚动位置计算当前章节：取视口 35% 高度处所在的最后一段。
  void _updateCurrentSection() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final pivot = position.pixels + position.viewportDimension * 0.35;
    var index = 0;
    for (var i = 0; i < _sections.length; i++) {
      final sectionContext = _sections[i].key.currentContext;
      if (sectionContext == null) continue;
      final box = sectionContext.findRenderObject();
      if (box is! RenderBox) continue;
      final top = box.localToGlobal(Offset.zero).dy + position.pixels;
      if (top <= pivot) index = i;
    }
    if (_currentSection.value != index) _currentSection.value = index;
  }

  void _jumpToSection(int index) {
    final sectionContext = _sections[index].key.currentContext;
    if (sectionContext == null) return;
    Scrollable.ensureVisible(
      sectionContext,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0.0,
    );
  }

  MarkdownConfig _buildConfig(ThemeData theme) {
    return (Get.isDarkMode ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig).copy(
      configs: [
        PConfig(
          textStyle:
              theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5) ??
              const TextStyle(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _buildConfig(theme);
    return Scaffold(
      appBar: AppBar(
        title: Text(i18n('changes_summary')),
        actions: [
          IconButton(
            tooltip: i18n('changes_summary_toc'),
            icon: const Icon(Remix.menu_2_line),
            onPressed: () => _tocExpanded.value = !_tocExpanded.value,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _tocExpanded,
            builder: (context, expanded, _) {
              // 收起时宽度动画到 0，内部面板保持固定宽并由 ClipRect 裁剪，
              // 避免目录项在动画过程中随宽度挤压换行。
              return AnimatedContainer(
                duration: _animDuration,
                curve: Curves.easeOutCubic,
                width: expanded ? _tocWidth : 0,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 0,
                    maxWidth: _tocWidth,
                    child: _buildTocPanel(theme),
                  ),
                ),
              );
            },
          ),
          Expanded(child: _buildContent(theme, config)),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, MarkdownConfig config) {
    return Stack(
      children: [
        SelectionArea(
          child: Scrollbar(
            controller: _scrollController,
            child: SingleChildScrollView(
              controller: _scrollController,
              physics: const PureLiveScrollPhysics(),
              padding: const EdgeInsets.only(left: 24, right: 24, top: 16, bottom: 80),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final section in _sections)
                        MarkdownBlock(key: section.key, data: section.markdown, config: config, selectable: false),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 目录收起时提供右下角悬浮展开入口。
        ValueListenableBuilder<bool>(
          valueListenable: _tocExpanded,
          builder: (context, expanded, _) => expanded
              ? const SizedBox.shrink()
              : Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    tooltip: i18n('changes_summary_toc'),
                    onPressed: () => _tocExpanded.value = true,
                    child: const Icon(Remix.menu_2_line),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTocPanel(ThemeData theme) {
    // 文档头（level 1）不进目录，仅列出 h2 章节。
    final tocIndices = <int>[
      for (var i = 0; i < _sections.length; i++)
        if (_sections[i].level >= 2) i,
    ];
    return SizedBox(
      width: _tocWidth,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(right: Divider.createBorderSide(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      i18n('changes_summary_toc'),
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: IconButton(
                      tooltip: i18n('changes_summary_toc'),
                      icon: const Icon(Remix.close_line, size: 18),
                      onPressed: () => _tocExpanded.value = false,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: _currentSection,
                builder: (context, current, _) => ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  itemCount: tocIndices.length,
                  itemBuilder: (context, position) {
                    final sectionIndex = tocIndices[position];
                    final section = _sections[sectionIndex];
                    final selected = sectionIndex == current;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Material(
                        color: selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () => _jumpToSection(sectionIndex),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: Row(
                              children: [
                                Container(
                                  width: 3,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(2),
                                    color: selected ? theme.colorScheme.primary : Colors.transparent,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    section.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      height: 1.35,
                                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                      color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
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
    );
  }
}

/// 单个文档段：h2 章节（或文档头）的原始 markdown 与定位 Key。
class _SummarySection {
  _SummarySection({required this.level, required this.title, required this.markdown});

  final int level;
  final String title;
  final String markdown;
  final GlobalKey key = GlobalKey();
}
