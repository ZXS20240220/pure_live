import 'package:flutter/gestures.dart';

import 'popular_grid_view.dart';

import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/widgets/common_appbar_actions.dart';

class PopularPage extends GetView<PopularController> {
  const PopularPage({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraint) {
        return Obx(() {
          bool showAction = Get.width <= 680;

          final sites = controller.sites;

          if (sites.isEmpty) {
            return const Scaffold();
          }

          return Scaffold(
            appBar: AppBar(
              centerTitle: true,
              leading: showAction ? const MenuButton() : null,
              actions: showAction ? [CommonAppBarActions()] : null,
              title: Listener(
                onPointerSignal: (event) {
                  if (event is! PointerScrollEvent) return;
                  final ctrl = controller.tabController;
                  if (ctrl.length == 0) return;
                  final dir = event.scrollDelta.dy > 0 ? 1 : -1;
                  final next = (ctrl.index + dir) % ctrl.length;
                  ctrl.animateTo(next);
                },
                child: TabBar(
                  key: const ValueKey('popular-platform-tabs'),
                  controller: controller.tabController,
                  isScrollable: true,
                  physics: const PureLiveBoundedScrollPhysics(),
                  tabs: sites.map((e) => Tab(text: e.name)).toList(),
                ),
              ),
            ),
            body: TabBarView(
              controller: controller.tabController,
              physics: const PureLiveBoundedScrollPhysics(),
              children: sites.map((e) => PopularGridView(e.id)).toList(),
            ),
          );
        });
      },
    );
  }
}
