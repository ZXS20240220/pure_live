import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/favorite/favorite_page.dart';
import 'package:pure_live/modules/tags/live_tag.dart';
import 'package:pure_live/modules/tags/tag_management_controller.dart';

void main() {
  test('platform tab rebuild preserves the selected site by identity', () {
    expect(
      resolveFavoriteSiteIndex(
        siteIds: const ['all', 'huya', 'bilibili'],
        selectedSiteId: 'bilibili',
        fallback: 1,
      ),
      2,
    );
    expect(
      resolveFavoriteSiteIndex(
        siteIds: const ['all', 'huya'],
        selectedSiteId: 'bilibili',
        fallback: 8,
      ),
      1,
    );
  });

  testWidgets('favorite tag chips reactively switch from custom back to all', (tester) async {
    Get.testMode = true;
    addTearDown(Get.reset);
    final tags = <LiveTag>[LiveTag(id: 'sleep', name: '助眠')].obs;
    final selected = <String>{TagManagementController.allTagKey}.obs;
    final multiSelect = false.obs;
    final untaggedCount = 0.obs;

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: FavoriteTagStrip(
            tags: tags,
            selectedTagIds: selected,
            visibleUntaggedCount: untaggedCount,
            multiSelectMode: multiSelect,
            onMultiSelectChanged: (v) => multiSelect.value = v,
            allLabel: '全部',
            labelStyle: const TextStyle(fontSize: 12),
            onSelected: (tagId) {
              final isAll = tagId == TagManagementController.allTagKey;
              if (multiSelect.value) {
                if (isAll) {
                  selected.assignAll({tagId});
                } else {
                  final ids = <String>{...selected};
                  ids.remove(TagManagementController.allTagKey);
                  if (ids.contains(tagId)) {
                    ids.remove(tagId);
                  } else {
                    ids.add(tagId);
                  }
                  if (ids.isEmpty) {
                    ids.add(TagManagementController.allTagKey);
                  }
                  selected.assignAll(ids);
                }
              } else {
                if (selected.length == 1 && selected.first == tagId) return;
                selected.assignAll({tagId});
              }
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ChoiceChip chip(String id) =>
        tester.widget<ChoiceChip>(find.byKey(ValueKey('favorite_tag_$id')));

    expect(find.byType(ChoiceChip), findsNWidgets(2));
    expect(chip(TagManagementController.allTagKey).selected, isTrue);
    expect(chip('sleep').selected, isFalse);

    await tester.tap(find.byKey(const ValueKey('favorite_tag_sleep')));
    await tester.pump();
    expect(selected.value, {'sleep'});
    expect(chip(TagManagementController.allTagKey).selected, isFalse);
    expect(chip('sleep').selected, isTrue);

    await tester.tap(find.byKey(ValueKey('favorite_tag_${TagManagementController.allTagKey}')));
    await tester.pump();
    expect(selected.value, {TagManagementController.allTagKey});
    expect(chip(TagManagementController.allTagKey).selected, isTrue);
    expect(chip('sleep').selected, isFalse);
  });
}
