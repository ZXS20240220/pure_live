import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_room.dart';
import 'package:pure_live/core/site/douyin/douyin_site.dart';

void main() {
  test('extracts escaped categoryData from the Douyin page payload', () {
    const source =
        r'prefix {\"pathname\":\"/\",\"categoryData\":[{\"partition\":{\"id_str\":\"1\",\"title\":\"热门\"},\"sub_partition\":[]}]} suffix';

    final extracted = DouyinSite().extractCategoryDataJson(source);
    final decoded = jsonDecode(extracted) as Map<String, dynamic>;

    expect(decoded['pathname'], '/');
    expect(decoded['categoryData'], isA<List<dynamic>>());
  });

  group('Douyin recommendation feed', () {
    test('parses the current envelope list response', () {
      final rooms = DouyinSite.parseRecommendRooms({
        'status_code': 0,
        'data': [
          {
            'web_rid': '123456',
            'data': {
              'id_str': '7654321',
              'title': '当前推荐直播',
              'owner': {
                'nickname': '主播',
                'web_rid': '123456',
                'avatar_thumb': {
                  'url_list': ['https://example.com/avatar.webp'],
                },
              },
              'cover': {
                'url_list': ['https://example.com/cover.webp'],
              },
              'room_view_stats': {'display_value': '1.2万', 'user_count': 321},
            },
          },
        ],
      });

      expect(rooms, hasLength(1));
      expect(rooms.single.roomId, '123456');
      expect(rooms.single.title, '当前推荐直播');
      expect(rooms.single.nick, '主播');
      expect(rooms.single.cover, 'https://example.com/cover.webp');
      expect(rooms.single.avatar, 'https://example.com/avatar.webp');
      expect(rooms.single.totalViewers, '1.2万');
      expect(rooms.single.onlineViewers, '321');
      expect(rooms.single.status, isTrue);
    });

    test('keeps compatibility with legacy data.data rooms and JSON envelopes', () {
      final rooms = DouyinSite.parseRecommendRooms({
        'status_code': 0,
        'data': {
          'data': [
            {
              'title': '旧结构',
              'owner': {'nickname': '旧主播', 'web_rid': 'legacy'},
              'cover': {
                'url_list': ['https://example.com/legacy.webp'],
              },
            },
            {
              'web_rid': 'encoded',
              'data': jsonEncode({
                'title': '字符串结构',
                'owner': {'nickname': '新主播'},
              }),
            },
          ],
        },
      });

      expect(rooms.map((room) => room.roomId), ['legacy', 'encoded']);
      expect(rooms.map((room) => room.title), ['旧结构', '字符串结构']);
    });

    test('uses top-level user_count as online instead of cumulative total', () {
      final rooms = DouyinSite.parseRecommendRooms({
        'status_code': 0,
        'data': [
          {
            'web_rid': 'online-room',
            'data': {
              'title': '在线口径',
              'user_count': 1757,
              'stats': {'total_user': 0, 'user_count_str': '1757'},
              'owner': {'nickname': '主播'},
            },
          },
        ],
      });

      expect(rooms.single.watching, '1757');
      expect(rooms.single.onlineViewers, '1757');
      expect(rooms.single.totalViewers, isEmpty);
      expect(rooms.single.audienceMetricType, AudienceMetricType.onlineViewers);
    });

    test('surfaces a platform rejection without a dynamic index exception', () {
      expect(
        () => DouyinSite.parseRecommendRooms({'status_code': 10001, 'data': []}),
        throwsStateError,
      );
    });
  });

  group('Douyin last-session start time and anchor location', () {
    test('parses reflow start_time and normalizes absent values to null', () {
      expect(DouyinSite.parseDouyinStartTime(1758012345), 1758012345);
      expect(DouyinSite.parseDouyinStartTime('1758012345'), 1758012345);
      expect(DouyinSite.parseDouyinStartTime(0), isNull);
      expect(DouyinSite.parseDouyinStartTime(''), isNull);
      expect(DouyinSite.parseDouyinStartTime('not-a-number'), isNull);
      expect(DouyinSite.parseDouyinStartTime(null), isNull);
    });

    test('prefers owner.location_city and falls back to the legacy city twin', () {
      expect(
        DouyinSite.parseDouyinAnchorLocation({
          'location_city': '上海',
          'city': '上海',
        }),
        '上海',
      );
      expect(
        DouyinSite.parseDouyinAnchorLocation({'city': '广州'}),
        '广州',
      );
    });

    test('treats hidden or malformed anchor locations as empty', () {
      expect(DouyinSite.parseDouyinAnchorLocation({'location_city': ''}), isEmpty);
      expect(DouyinSite.parseDouyinAnchorLocation({'location_city': 'null'}), isEmpty);
      expect(DouyinSite.parseDouyinAnchorLocation(const {}), isEmpty);
      expect(DouyinSite.parseDouyinAnchorLocation(null), isEmpty);
      expect(DouyinSite.parseDouyinAnchorLocation('上海'), isEmpty);
    });

    test('extracts both fields from the reflow extras payload shape', () {
      // Shape returned by webcast/room/reflow/info under data.room, consumed
      // by the favourite refresh path for offline web-rid rooms.
      final extrasRoom = {
        'start_time': 1647575906,
        'owner': {'location_city': '凉山', 'nickname': '主播'},
      };

      expect(DouyinSite.parseDouyinStartTime(extrasRoom['start_time']), 1647575906);
      expect(
        DouyinSite.parseDouyinAnchorLocation(extrasRoom['owner']),
        '凉山',
      );
    });
  });
}
