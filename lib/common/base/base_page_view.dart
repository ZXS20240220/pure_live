import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/base/base_controller.dart';
import 'package:pure_live/common/global/platform_utils.dart';

class BasePageView<C extends BasePageScrollAndStateBone<T>, T> extends StatefulWidget {
  final C controller;
  final Widget Function(BuildContext context, List<T> list, ScrollController scrollController)
  contentBuilder;
  final bool enableRefresh;
  final bool enableLoadMore;

  final bool wrapMobileRefresh;

  final bool preserveContentWhenEmpty;
  final bool? showScrollToTopBtn;
  final bool showPageSizeSelector;
  final List<int> pageSizeOptions;
  final double? customMobileBottomPadding;
  final double? customDesktopBottomPadding;

  final Widget Function(BuildContext context)? notLoginBuilder;
  final Widget Function(BuildContext context, String errorMsg)? errorBuilder;
  final Widget Function(BuildContext context)? emptyBuilder;

  final bool keyboardPagingEnabled;

  const BasePageView({
    super.key,
    required this.controller,
    required this.contentBuilder,
    this.enableRefresh = true,
    this.enableLoadMore = true,
    this.wrapMobileRefresh = true,
    this.preserveContentWhenEmpty = false,
    this.showScrollToTopBtn,
    this.showPageSizeSelector = false,
    this.pageSizeOptions = const [],
    this.customMobileBottomPadding,
    this.customDesktopBottomPadding,
    this.notLoginBuilder,
    this.errorBuilder,
    this.emptyBuilder,
    this.keyboardPagingEnabled = true,
  });

  @override
  State<BasePageView<C, T>> createState() => _BasePageViewState<C, T>();
}

class _BasePageViewState<C extends BasePageScrollAndStateBone<T>, T>
    extends State<BasePageView<C, T>> {
  bool _isDesktop = false;

  KeyEventResult _onContentKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.keyboardPagingEnabled) return KeyEventResult.ignored;
    if (!_isDesktop) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isEditingFocused()) return KeyEventResult.ignored;

    final controller = widget.controller;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (controller.currentPage > 1 && !controller.loadding.value) {
          controller.goToPage(controller.currentPage - 1);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        if (controller.canLoadMore.value && !controller.loadding.value && widget.enableLoadMore) {
          controller.goToPage(controller.currentPage + 1);
        }
        return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool showBtn = widget.showScrollToTopBtn ?? true;
    final double currentWidth = context.width;
    final bool isDesktop = currentWidth > 680 && !PlatformUtils.isMobile;
    _isDesktop = isDesktop;

    double bottomPadding = isDesktop
        ? (widget.customDesktopBottomPadding ?? 70)
        : (widget.customMobileBottomPadding ?? 20);

    return Stack(
      children: [
        Column(
          children: [
            Obx(() {
              if (widget.controller.showCellularBanner.value && widget.controller.list.isNotEmpty) {
                return Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                      width: 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.signal_cellular_alt_rounded,
                              color: Theme.of(context).colorScheme.primary,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              i18n('cellular_warning_msg'),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(context).colorScheme.primary,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              BaseController.neverShowCellularBanner = true;
                              widget.controller.showCellularBanner.value = false;
                            },
                            child: Text(
                              i18n('never_show'),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraint) {
                  widget.controller.checkAndNotifyLayoutChange(isDesktop);
                  return Obx(() {
                    if (widget.controller.list.isEmpty) {
                      if (widget.controller.notLogin.value) {
                        final view = widget.notLoginBuilder != null
                            ? widget.notLoginBuilder!(context)
                            : AppStatusView(
                                type: AppStatusType.error,
                                icon: Icons.account_circle_outlined,
                                title: i18n('login_required_title'),
                                subtitle: i18n('login_required_subtitle'),
                                buttonText: i18n('go_to_login'),
                                onButtonPressed: () => Get.toNamed(RoutePath.kSettingsAccount),
                              );
                        return _buildScrollableStatus(
                          isDesktop,
                          constraint,
                          widget.controller,
                          view,
                        );
                      }
                      if (widget.controller.pageError.value) {
                        final view = widget.errorBuilder != null
                            ? widget.errorBuilder!(context, widget.controller.errorMsg.value)
                            : AppStatusView(
                                type: AppStatusType.error,
                                icon: Icons.wifi_off_rounded,
                                title: i18n('network_error_title'),
                                subtitle: widget.controller.errorMsg.value,
                                buttonText: i18n('retry'),
                                onButtonPressed: widget.controller.refreshData,
                              );
                        return _buildScrollableStatus(
                          isDesktop,
                          constraint,
                          widget.controller,
                          view,
                        );
                      }
                      if (widget.controller.pageEmpty.value && !widget.preserveContentWhenEmpty) {
                        final view = widget.emptyBuilder != null
                            ? widget.emptyBuilder!(context)
                            : AppStatusView(
                                type: AppStatusType.empty,
                                title: i18n('no_data'),
                                subtitle: '',
                              );
                        return _buildScrollableStatus(
                          isDesktop,
                          constraint,
                          widget.controller,
                          view,
                        );
                      }
                      if (widget.preserveContentWhenEmpty &&
                          widget.controller.totalCount.value != null) {
                        return buildActualContent(context, isDesktop);
                      }
                      return AppStatusView(
                        type: AppStatusType.loading,
                        title: i18n('refresh_loading'),
                        subtitle: '',
                      );
                    }
                    return buildActualContent(context, isDesktop);
                  });
                },
              ),
            ),
          ],
        ),
        if (showBtn)
          Positioned(right: 16, bottom: bottomPadding, child: buildFloatingButtons(context)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Obx(() {
            if (widget.controller.list.isNotEmpty && widget.controller.loadding.value) {
              return SizedBox(
                height: 2.5,
                child: LinearProgressIndicator(
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
        ),
      ],
    );
  }

  Widget _buildScrollableStatus(
    bool isDesktop,
    BoxConstraints constraint,
    C controller,
    Widget statusView,
  ) {
    if (isDesktop || !widget.enableRefresh) {
      return Center(child: statusView);
    }
    return EasyRefresh(
      controller: controller.easyRefreshController,
      onRefresh: () => controller.refreshData(),
      child: ListView(
        physics: const PureLiveScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        children: [SizedBox(height: constraint.maxHeight * 0.8, child: statusView)],
      ),
    );
  }

  Widget buildActualContent(BuildContext context, bool isDesktop) {
    if (isDesktop) {
      return Focus(
        autofocus: true,
        onKeyEvent: _onContentKeyEvent,
        child: Column(
          children: [
            Expanded(
              child: widget.contentBuilder(
                context,
                widget.controller.list,
                widget.controller.scrollController,
              ),
            ),
            if (widget.enableLoadMore)
              DesktopPaginationBar(
                controller: widget.controller,
                showSelector: widget.showPageSizeSelector,
                options: widget.pageSizeOptions,
              ),
          ],
        ),
      );
    } else if (widget.wrapMobileRefresh) {
      return EasyRefresh(
        controller: widget.controller.easyRefreshController,
        onRefresh: widget.enableRefresh ? widget.controller.refreshData : null,
        onLoad: (widget.enableLoadMore && widget.controller.canLoadMore.value)
            ? () async {
                await widget.controller.loadMoreData();
              }
            : null,
        child: widget.contentBuilder(
          context,
          widget.controller.list,
          widget.controller.scrollController,
        ),
      );
    }
    return widget.contentBuilder(
      context,
      widget.controller.list,
      widget.controller.scrollController,
    );
  }

  Widget buildFloatingButtons(BuildContext context) {
    return Obx(() {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: widget.controller.showBackToTop.value ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: FloatingActionButton(
                heroTag: 'base_page_view_to_top_${widget.controller.hashCode}',
                mini: true,
                elevation: 3,
                backgroundColor: Theme.of(context).cardColor,
                onPressed: widget.controller.scrollToTopOrRefresh,
                child: const Icon(Icons.arrow_upward_rounded),
              ),
            ),
          ),
          AnimatedScale(
            scale: widget.controller.showBackToBottom.value ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: FloatingActionButton(
              heroTag: 'base_page_view_to_bottom_${widget.controller.hashCode}',
              mini: true,
              elevation: 3,
              backgroundColor: Theme.of(context).cardColor,
              onPressed: widget.controller.scrollToBottom,
              child: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
        ],
      );
    });
  }
}
