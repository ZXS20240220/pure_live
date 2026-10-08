class RemoteSyncProtocol {
  static const int defaultHttpPort = 39888;
  static const int discoveryPort = 39889;

  static const String discoveryType = 'pure_live_discovery';
  static const String syncType = 'pure_live_sync';

  static const String apiStatus = '/api/remote-sync/status';
  static const String apiSettings = '/api/remote-sync/settings';

  /// 本设备同步端点二维码：只含地址与端口。
  ///
  /// 历史上这里还携带一个 6 位配对码，现已有意移除（与官方 v3.1.18 对齐）：
  /// 数据的拥有方在自己设备上对每个请求做现场审批（见
  /// `RemoteSyncService.confirmRequest`），扫二维码与手输地址走同一道门，
  /// 也避免配对码显示在屏幕/二维码上后在服务运行期内被重复使用。
  static Uri createQrUri({required String ip, required int port}) {
    return Uri(scheme: 'purelive', host: ip, port: port, path: '/sync');
  }

  static Map<String, dynamic> discoveryPacket({
    required String id,
    required String name,
    required String ip,
    required int port,
    required String platform,
    required String version,
  }) {
    return {
      'type': discoveryType,
      'id': id,
      'name': name,
      'ip': ip,
      'port': port,
      'platform': platform,
      'version': version,
    };
  }

  static Map<String, dynamic> settingsPacket({required Map<String, dynamic> settings}) {
    return {'type': syncType, 'version': 1, 'settings': settings};
  }

  /// 解析手动输入的地址。裸 "host" / "host:port" 会补 http:// 前缀，
  /// 仅接受 IPv4 地址或主机名，端口缺省时回落到同步服务默认端口而不是 80。
  static ({String ip, int port})? parseHttpAddress(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      final prefixed = 'http://$text';
      return _parseUriAddress(prefixed);
    }
    return _parseUriAddress(text);
  }

  static ({String ip, int port})? _parseUriAddress(String text) {
    try {
      final uri = Uri.parse(text);
      final host = uri.host.trim();
      // 仅允许 IPv4 地址与主机名，避免把任意文本当成地址。
      if (!RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$').hasMatch(host)) return null;
      final port = uri.hasPort ? uri.port : defaultHttpPort;
      if (port < 1 || port > 65535) return null;
      return (ip: host, port: port);
    } catch (_) {
      return null;
    }
  }

  /// 解析同步二维码。旧版本二维码会多带一个 `code` 查询参数，这里直接忽略，
  /// 因此新旧两种二维码都解析为同一个端点；授权改由接收端现场审批完成。
  static ({String ip, int port})? parseQr(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('purelive:')) {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
      return (ip: uri.host, port: uri.port);
    }
    final address = parseHttpAddress(text);
    return address == null ? null : (ip: address.ip, port: address.port);
  }
}
