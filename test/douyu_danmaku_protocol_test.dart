import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/core/danmaku/douyu_danmaku.dart';
import 'package:pure_live/core/site/douyu/douyu_utils.dart';

void main() {
  group('Douyu danmaku protocol', () {
    late DouyuDanmaku danmaku;
    late List<LiveMessage> received;

    setUp(() {
      danmaku = DouyuDanmaku()..debugSetRoomId('100');
      received = <LiveMessage>[];
      danmaku.onMessage = received.add;
    });

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

    LiveSuperChatMessage buildVoiceSc({
      required String userName,
      required String message,
      required int price,
      int startMs = 1700000000000,
    }) {
      final startTime = DateTime.fromMillisecondsSinceEpoch(startMs);
      return LiveSuperChatMessage(
        messageId: DouyuUtils.superChatCoalesceId(
          roomId: '100',
          userName: userName,
          message: message,
          startTime: startTime,
        ),
        backgroundColor: '#ffffff',
        backgroundBottomColor: '#246488',
        endTime: startTime.add(const Duration(seconds: 60)),
        face: '',
        message: message,
        price: price,
        startTime: startTime,
        userName: userName,
      );
    }

    List<int> listPricePacket({required int cprice, String nn = 'Supporter', String txt = 'Great'}) {
      final builder = DouyuDanmaku()..debugSetRoomId('100');
      return builder.serializeDouyu(
        'type@=comm_chatmsg/now@=1700000000000/cet@=60/cprice@=$cprice/'
        'chatmsg@=nn@A=$nn@Stxt@A=$txt@Sic@A=avatar/',
      );
    }

    test('displays the list-price report immediately without waiting for a twin', () {
      danmaku.decodeMessage(listPricePacket(cprice: 10000));
      expect(received, hasLength(1));
      final sc = received.single.data as LiveSuperChatMessage;
      expect(sc.price, 100);
      // 仅一份报告时不显示重复标价。
      expect(sc.listPrice, 100);
    });

    test('updates the same card when the real-price report arrives after the list-price report', () {
      danmaku.decodeMessage(listPricePacket(cprice: 10000));
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Supporter', message: 'Great', price: 50),
        isRealPriceEvent: true,
      );

      expect(received, hasLength(2));
      expect(received.first.messageId, received.last.messageId);
      final updated = received.last.data as LiveSuperChatMessage;
      expect(updated.price, 50);
      expect(updated.listPrice, 100);
    });

    test('keeps price 0 and attaches list price when the free report arrives first', () {
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Supporter', message: 'Great', price: 0),
        isRealPriceEvent: true,
      );
      expect((received.single.data as LiveSuperChatMessage).price, 0);

      danmaku.decodeMessage(listPricePacket(cprice: 10000));
      expect(received, hasLength(2));
      final updated = received.last.data as LiveSuperChatMessage;
      expect(updated.price, 0);
      expect(updated.listPrice, 100);
    });

    test('treats a real-price SC with different content as a separate message', () {
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Supporter', message: 'Great', price: 0),
        isRealPriceEvent: true,
      );
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Other', message: 'Different', price: 5),
        isRealPriceEvent: true,
      );

      expect(received, hasLength(2));
      expect(received.first.messageId == received.last.messageId, isFalse);
    });

    test('a reconnect replay keeps updating the same card instead of creating a new identity', () {
      danmaku.decodeMessage(listPricePacket(cprice: 10000));
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Supporter', message: 'Great', price: 50),
        isRealPriceEvent: true,
      );
      danmaku.debugDispatchSuperChat(
        buildVoiceSc(userName: 'Supporter', message: 'Great', price: 50),
        isRealPriceEvent: true,
      );

      expect(received, hasLength(3));
      expect(received.map((m) => m.messageId).toSet(), hasLength(1));
      final replayed = received.last.data as LiveSuperChatMessage;
      expect(replayed.price, 50);
      expect(replayed.listPrice, 100);
    });
  });
}
