import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_room.dart';
import 'package:pure_live/core/site/huya/huya_site.dart';
import 'package:pure_live/core/site/huya/huya_transport_policy.dart';

/// 构造一个与真实视频页同构（但精简）的播放页片段。
String _pageWith(String definitionsJson) =>
    '''
<html><head><script>
var TT_META_DATA = {"time":1791897890};
var videoDefinitions = $definitionsJson;
var videoData = {"_classname":"HUYAVIDEO.VideoData"};
</script></head><body>player</body></html>
''';

const _fixtureJson = r'''
{"_bValue":0,"value":[
  {"sSize":"20","sWidth":"1920","sHeight":"1080","sDefinition":"yuanhua",
   "sUrl":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/27f407e6.m3u8?scene=vodreplay&ratio=4000",
   "sM3u8":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/27f407e6.m3u8?scene=vodreplay&ratio=4000",
   "sDefName":"1080P","sDuration":"17105","iLine":1,"iBitrate":0,"sFormat":"m3u8",
   "streams":{"value":[]}},
  {"sSize":"20","sWidth":"1280","sHeight":"720","sDefinition":"1300",
   "sUrl":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/50860ee9.m3u8?scene=vodreplay&ratio=1300",
   "sM3u8":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/50860ee9.m3u8?scene=vodreplay&ratio=1300",
   "sDefName":"720P","iLine":2,"iBitrate":0,"sFormat":"m3u8",
   "streams":{"value":[
     {"sUrl":"http://al-vod2.cdn.huya.com/vhuya/danmu/liverecord/111/50860ee9.m3u8?scene=vodreplay&ratio=1300&line=2",
      "sM3u8":"http://al-vod2.cdn.huya.com/vhuya/danmu/liverecord/111/50860ee9.m3u8?scene=vodreplay&ratio=1300&line=2"}
   ]}},
  {"sSize":"20","sWidth":"640","sHeight":"360","sDefinition":"350",
   "sUrl":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/6a458a15.m3u8?scene=vodreplay",
   "sM3u8":"http://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/111/6a458a15.m3u8?scene=vodreplay",
   "sDefName":"360P","iLine":1,"iBitrate":0,"sFormat":"m3u8"}
]}
''';

/// 任何签名动作都会抛错，用于证明录播直链完全绕过 WUP/antiCode。
class _NoNetworkHuyaSite extends HuyaSite {
  int nativeCalls = 0;

  @override
  Future<HuyaCdnTokenLease> getNativeCdnTokenInfoEx(HuyaLineModel line) async {
    nativeCalls++;
    throw StateError('录播直链不允许触发 native token 签名');
  }
}

void main() {
  group('parseReplayVideoDefinitions', () {
    test('解析 1080P/720P/360P 三档并按码率降序、升级 https', () {
      final sources = HuyaSite.parseReplayVideoDefinitions(_pageWith(_fixtureJson));
      expect(sources, hasLength(3));
      expect(sources.map((s) => s.bitRate), [10000, 1300, 350]);
      expect(sources.map((s) => s.definition), ['yuanhua', '1300', '350']);
      expect(sources.map((s) => s.name), ['1080P', '720P', '360P']);
      for (final source in sources) {
        for (final url in source.urls) {
          expect(url.startsWith('https://'), isTrue, reason: 'VOD 直链应升级为 HTTPS');
          expect(url.contains('.m3u8'), isTrue);
        }
      }
      // 720P 档 streams.value 提供了一条额外 CDN 线路。
      expect(sources[1].urls, hasLength(2));
      expect(sources[1].urls.any((u) => u.contains('videotx-platform')), isTrue);
      expect(sources[1].urls.any((u) => u.contains('al-vod2')), isTrue);
    });

    test('缺少 sDefName 时 yuanhua 回退为“原画”，数字档回退为标识本身', () {
      const json = r'''
      {"value":[
        {"sDefinition":"yuanhua","sUrl":"http://h.cdn.huya.com/a/a.m3u8?scene=vodreplay"},
        {"sDefinition":"1300","sUrl":"http://h.cdn.huya.com/b/b.m3u8?scene=vodreplay"}
      ]}''';
      final sources = HuyaSite.parseReplayVideoDefinitions(_pageWith(json));
      expect(sources.map((s) => s.name), ['原画', '1300']);
    });

    test('页面无 videoDefinitions 或 JSON 损坏时返回空列表（交由上层降级 360P）', () {
      expect(HuyaSite.parseReplayVideoDefinitions('<html>nothing</html>'), isEmpty);
      final broken = _pageWith('{"value": [ { broken json');
      expect(HuyaSite.parseReplayVideoDefinitions(broken), isEmpty);
    });

    test('非 m3u8 地址与重复地址被忽略', () {
      const json = r'''
      {"value":[
        {"sDefinition":"350","sDefName":"360P",
         "sUrl":"http://h.cdn.huya.com/a/a.flv?scene=vodreplay",
         "sM3u8":"http://h.cdn.huya.com/a/a.m3u8?scene=vodreplay",
         "streams":{"value":[
           {"sM3u8":"http://h.cdn.huya.com/a/a.m3u8?scene=vodreplay"}
         ]}}
      ]}''';
      final sources = HuyaSite.parseReplayVideoDefinitions(_pageWith(json));
      expect(sources, hasLength(1));
      expect(sources.single.urls, hasLength(1), reason: '重复 m3u8 应去重，flv 应被忽略');
    });
  });

  group('录播清晰度组装与播放', () {
    HuyaLineModel replayLine(String uuid, int bitRate, {String host = 'videotx-platform'}) {
      final url =
          'https://$host.cdn.huya.com/vhuya/danmu/liverecord/111/$uuid.m3u8'
          '?scene=vodreplay&ratio=$bitRate&vid=1128725230';
      return HuyaLineModel(
        line: url,
        lineType: HuyaLineType.hls,
        flvAntiCode: '',
        hlsAntiCode: '',
        streamName: '$uuid.m3u8',
        cdnType: host,
        presenterUid: 111,
        bitRate: bitRate,
        directUrl: url,
      );
    }

    late HuyaUrlDataModel replayData;
    setUp(() {
      replayData = HuyaUrlDataModel(
        url: '',
        lines: const <HuyaLineModel>[],
        bitRates: [
          HuyaBitRateModel(bitRate: 0, name: '1080P'),
          HuyaBitRateModel(bitRate: 1300, name: '720P'),
          HuyaBitRateModel(bitRate: 350, name: '360P'),
        ],
        uid: '',
        isXingxiu: false,
        qualityLines: {
          0: [replayLine('27f407e6', 4000)],
          1300: [replayLine('50860ee9', 1300)],
          350: [replayLine('6a458a15', 350)],
        },
      );
    });

    test('每个清晰度携带各自的录播直连线路，排序为 1080P > 720P > 360P', () {
      final qualities = HuyaSite.parsePlayQualities(replayData);
      expect(qualities.map((q) => q.id), [0, 1300, 350]);
      final q720 = qualities.firstWhere((q) => q.id == 1300);
      final lines = (q720.data as Map)['urls'] as List;
      expect(lines, hasLength(1));
      expect((lines.single as HuyaLineModel).directUrl, contains('50860ee9'));
      // 档位之间不串线：1080P 不应拿到 720P 的 UUID。
      final q1080 = qualities.firstWhere((q) => q.id == 0);
      final line1080 = ((q1080.data as Map)['urls'] as List).single as HuyaLineModel;
      expect(line1080.directUrl, contains('27f407e6'));
    });

    test('getPlayUrls 原样返回录播直链且不触发任何签名请求', () async {
      final site = _NoNetworkHuyaSite();
      final qualities = HuyaSite.parsePlayQualities(replayData);
      for (final quality in qualities) {
        final urls = await site.getPlayUrls(
          detail: LiveRoom(roomId: 'r'),
          quality: quality,
        );
        expect(urls, hasLength(1));
        expect(urls.single, contains('.m3u8'));
        expect(urls.single, ((quality.data as Map)['urls'] as List).single.directUrl);
      }
      expect(site.nativeCalls, 0, reason: '录播 VOD 直链不得走 WUP 签名');
    });

    test('无 qualityLines 的直播数据仍共用全部线路（回归保护）', () {
      final liveLine = HuyaLineModel(
        line: 'https://al.flv.huya.com/src',
        lineType: HuyaLineType.flv,
        flvAntiCode: 'wsSecret=x&wsTime=y',
        hlsAntiCode: 'wsSecret=x&wsTime=y',
        streamName: 's',
        cdnType: 'AL',
        presenterUid: 1,
      );
      final data = HuyaUrlDataModel(
        url: '',
        lines: [liveLine],
        bitRates: [
          HuyaBitRateModel(bitRate: 0, name: '原画'),
          HuyaBitRateModel(bitRate: 8000, name: '8M'),
        ],
        uid: '',
        isXingxiu: false,
      );
      final qualities = HuyaSite.parsePlayQualities(data);
      expect(qualities, hasLength(2));
      for (final q in qualities) {
        expect(((q.data as Map)['urls'] as List), hasLength(1));
        expect((((q.data as Map)['urls'] as List).single as HuyaLineModel).directUrl, isNull);
      }
    });
  });

  group('HuyaTransportPolicy 录播豁免', () {
    const replayBase = 'https://videotx-platform.cdn.huya.com/vhuya/danmu/liverecord/1/a.m3u8';
    test('vodreplay 与 livereplay 均不视为短租约，避免 40s 主动刷新误杀 VOD', () {
      expect(HuyaTransportPolicy.hasShortTransportLease('$replayBase?scene=vodreplay'), isFalse);
      expect(HuyaTransportPolicy.hasShortTransportLease('$replayBase?scene=livereplay'), isFalse);
      expect(HuyaTransportPolicy.isReplayVod('$replayBase?scene=vodreplay'), isTrue);
    });

    test('普通直播 HLS 仍按短租约处理；native FLV 长租约不受影响', () {
      expect(HuyaTransportPolicy.hasShortTransportLease('https://hla.huya.com/src/s.m3u8?wsTime=x'), isTrue);
      expect(
        HuyaTransportPolicy.hasShortTransportLease('https://tx.flv.huya.com/src/s.flv?ctype=huya_pc_exe&t=100'),
        isFalse,
      );
    });
  });
}
