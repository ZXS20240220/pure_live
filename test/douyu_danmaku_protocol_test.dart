import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/core/danmaku/douyu_danmaku.dart';

void main() {
  group('Douyu danmaku protocol', () {
    test('decodes every packet coalesced in one websocket frame', () {
      final danmaku = DouyuDanmaku();
      danmaku.markConnected();
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final first = danmaku.serializeDouyu('type@=chatmsg/rid@=100/dms@=1/uid@=7/nn@=A/txt@=one/cid@=c1/col@=0/');
      final second = danmaku.serializeDouyu('type@=chatmsg/rid@=100/dms@=1/uid@=8/nn@=B/txt@=two/cid@=c2/col@=0/');

      // start() normally owns this value; set it directly to keep the parser
      // regression test independent from a network connection.
      danmaku.debugSetRoomId('100');
      danmaku.decodeMessage(<int>[...first, ...second]);

      expect(received.map((message) => message.message), ['one', 'two']);
      expect(received.map((message) => message.messageId), ['douyu:c1', 'douyu:c2']);
    });

    test('drops a packet explicitly tagged for a different room', () {
      final danmaku = DouyuDanmaku()..debugSetRoomId('100');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;

      danmaku.decodeMessage(danmaku.serializeDouyu('type@=chatmsg/rid@=200/dms@=1/uid@=7/nn@=A/txt@=wrong/cid@=c1/'));

      expect(received, isEmpty);
    });

    test('filters suspected automated chat by default', () {
      final danmaku = DouyuDanmaku()..debugSetRoomId('71415');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;

      danmaku.decodeMessage(
        danmaku.serializeDouyu('type@=chatmsg/rid@=71415/uid@=7/nn@=A/txt@=ordinary/cid@=c1/col@=0/'),
      );

      expect(received, isEmpty);
    });

    test('can expose raw room chat when the platform filter is disabled', () {
      final danmaku = DouyuDanmaku(filterSuspectedAutomatedMessages: () => false)..debugSetRoomId('71415');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;

      danmaku.decodeMessage(
        danmaku.serializeDouyu('type@=chatmsg/rid@=71415/uid@=7/nn@=A/txt@=ordinary/cid@=c1/col@=0/'),
      );

      expect(received, hasLength(1));
      expect(received.single.message, 'ordinary');
      expect(received.single.messageId, 'douyu:c1');
    });

    test('ignores empty chat payloads without affecting the next packet', () {
      final danmaku = DouyuDanmaku(filterSuspectedAutomatedMessages: () => false)..debugSetRoomId('71415');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final empty = danmaku.serializeDouyu('type@=chatmsg/rid@=71415/uid@=7/nn@=A/txt@=/cid@=empty/');
      final valid = danmaku.serializeDouyu('type@=chatmsg/rid@=71415/uid@=8/nn@=B/txt@=next/cid@=next/');

      danmaku.decodeMessage(<int>[...empty, ...valid]);

      expect(received.map((message) => message.message), ['next']);
    });

    test('keeps ordinary chat and a super-chat coalesced in one frame', () {
      final danmaku = DouyuDanmaku()..debugSetRoomId('100');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final chat = danmaku.serializeDouyu('type@=chatmsg/rid@=100/dms@=1/uid@=7/nn@=A/txt@=hello/cid@=c1/');
      final superChat = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=500/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );

      danmaku.decodeMessage(<int>[...chat, ...superChat]);

      expect(received.map((message) => message.type), [LiveMessageType.chat, LiveMessageType.superChat]);
      final data = received.last.data as LiveSuperChatMessage;
      expect(data.userName, 'Supporter');
      expect(data.message, 'Great');
      expect(data.price, 5);
    });

    test('displays a price=0 super chat immediately', () async {
      final danmaku = DouyuDanmaku()
        ..debugSetRoomId('100')
        ..debugSetSuperChatDedupWindow(const Duration(milliseconds: 30));
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final free = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=0/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );

      danmaku.decodeMessage(free);
      expect(received, hasLength(1));
      expect((received.single.data as LiveSuperChatMessage).price, 0);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(received, hasLength(1));
    });

    test('suppresses the identical price>0 companion that follows a shown price=0 SC', () async {
      final danmaku = DouyuDanmaku()
        ..debugSetRoomId('100')
        ..debugSetSuperChatDedupWindow(const Duration(milliseconds: 30));
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final free = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=0/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );
      final companion = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=500/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );

      danmaku.decodeMessage(free);
      expect(received, hasLength(1));
      expect((received.single.data as LiveSuperChatMessage).price, 0);

      danmaku.decodeMessage(companion);
      expect(received, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(received, hasLength(1));
    });

    test('a price>0 SC with different content is displayed as a normal paid SC', () async {
      final danmaku = DouyuDanmaku()
        ..debugSetRoomId('100')
        ..debugSetSuperChatDedupWindow(const Duration(milliseconds: 30));
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final free = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=0/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );
      final paid = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=500/'
        'chatmsg@=nn@A=Other@Stxt@A=Different@Sic@A=avatar/',
      );

      danmaku.decodeMessage(free);
      danmaku.decodeMessage(paid);
      expect(received, hasLength(2));
      expect((received.last.data as LiveSuperChatMessage).price, 5);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(received, hasLength(2));
    });

    test('only one price>0 companion is suppressed per shown price=0 SC', () {
      final danmaku = DouyuDanmaku()..debugSetRoomId('100');
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final free = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=0/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );
      List<int> companion() => danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=500/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );

      danmaku.decodeMessage(free);
      danmaku.decodeMessage(companion());
      expect(received, hasLength(1));

      // The twin was consumed, so a further identical packet is a genuine
      // paid SC and must be displayed.
      danmaku.decodeMessage(companion());
      expect(received, hasLength(2));
      expect((received.last.data as LiveSuperChatMessage).price, 5);
    });

    test('a price>0 packet arriving after the dedup window is displayed', () async {
      final danmaku = DouyuDanmaku()
        ..debugSetRoomId('100')
        ..debugSetSuperChatDedupWindow(const Duration(milliseconds: 30));
      final received = <LiveMessage>[];
      danmaku.onMessage = received.add;
      final free = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=0/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );
      final lateCompanion = danmaku.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=500/'
        'chatmsg@=nn@A=Supporter@Stxt@A=Great@Sic@A=avatar/',
      );

      danmaku.decodeMessage(free);
      expect(received, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 80));
      danmaku.decodeMessage(lateCompanion);
      expect(received, hasLength(2));
      expect((received.last.data as LiveSuperChatMessage).price, 5);
    });
  });
}
